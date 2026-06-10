"""pappagei local TTS sidecar (FastAPI).

Run:  scripts/run_backend.sh   (uvicorn on 127.0.0.1:8765)

IMPORTANT: MLX must run on ONE consistent thread. FastAPI would otherwise call
the model from arbitrary worker threads (and the model could load in one thread
but be invoked from another), which crashes the Metal backend. So every model
operation is funnelled through a single-worker executor (`infer_pool`), and
/synthesize streams PCM out of that thread via a bounded queue (which also gives
natural backpressure). Endpoints are async so the event loop stays responsive.
"""
from __future__ import annotations

import asyncio
import os
import queue
import signal
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Optional

import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from starlette.responses import StreamingResponse

from tts_engine import MODELS, Engine, Voice
from voices import VoiceStore

engine = Engine()
store = VoiceStore()
infer_pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="tts-infer")

_QUEUE_MAX = 32          # bounded -> backpressure when the client lags
_PUT_TIMEOUT = 0.5       # seconds; lets the producer notice cancellation
_DONE = object()         # stream sentinel

_PARENT_PID = os.getppid()


def _watch_parent() -> None:
    """Exit when the parent process (the app) dies.

    The app launches uvicorn directly, so our parent is the app; once it is
    gone we get reparented (ppid changes) and must not linger on port 8765.
    Started manually from a shell, the parent is that shell -- same deal.
    """
    while os.getppid() == _PARENT_PID:
        time.sleep(2.0)
    os.kill(os.getpid(), signal.SIGTERM)   # let uvicorn shut down cleanly
    time.sleep(5.0)
    os._exit(0)                            # emergency stop if a stream hangs


async def _run_infer(fn, *args):
    """Run a model operation on the single inference thread and await it."""
    loop = asyncio.get_running_loop()
    return await loop.run_in_executor(infer_pool, lambda: fn(*args))


def _load_and_warm() -> None:
    try:
        engine.ensure_loaded()
        engine.warmup()
    except Exception:  # noqa: BLE001 -- background warmup is best-effort
        pass


@asynccontextmanager
async def lifespan(_: FastAPI):
    threading.Thread(target=_watch_parent, daemon=True, name="parent-watchdog").start()
    infer_pool.submit(_load_and_warm)   # warm in the background; /health reports readiness
    yield
    infer_pool.shutdown(wait=False)


app = FastAPI(title="pappagei-tts", lifespan=lifespan)


class SynthRequest(BaseModel):
    text: str
    voice: Optional[str] = None     # custom voice id/name, or a base speaker
    model: Optional[str] = None     # "0.6b" or "1.7b"
    speed: float = 1.0
    temperature: Optional[float] = None
    repetition_penalty: Optional[float] = None


class ImportRequest(BaseModel):
    name: str
    audio_path: str
    transcript: Optional[str] = None
    speaker: Optional[str] = None


def _model_cache_bytes(model_key: Optional[str]) -> Optional[int]:
    """Bytes of the model's HF cache dir; grows while a download runs."""
    if not model_key or model_key not in MODELS:
        return None
    try:
        from huggingface_hub.constants import HF_HUB_CACHE
        repo_dir = Path(HF_HUB_CACHE) / ("models--" + MODELS[model_key].replace("/", "--"))
        if not repo_dir.exists():
            return 0
        # Skip symlinks: snapshot links would double-count the blobs.
        return sum(p.stat().st_size for p in repo_dir.rglob("*")
                   if p.is_file() and not p.is_symlink())
    except Exception:  # noqa: BLE001 -- progress display is best-effort
        return None


@app.get("/health")
def health() -> dict:
    loading = engine.loading
    return {
        "status": "ok",
        "model": engine.model_key,
        "loaded": engine.loaded,
        "loading": loading,
        "download_bytes": _model_cache_bytes(engine.loading_model_key) if loading else None,
        "sample_rate": engine.sample_rate,
    }


@app.post("/warmup")
async def warmup() -> dict:
    secs = await _run_infer(engine.warmup)
    return {"warmup_seconds": secs, "sample_rate": engine.sample_rate}


@app.get("/voices")
def list_voices() -> dict:
    return {
        "model": engine.model_key,
        "speakers": engine.supported_speakers(),
        "custom": store.list(),
    }


@app.post("/voices/import")
def import_voice(req: ImportRequest) -> dict:
    return store.import_voice(req.name, req.audio_path, req.transcript, req.speaker or "Chelsie")


@app.delete("/voices/{vid}")
def delete_voice(vid: str) -> dict:
    if not store.delete(vid):
        raise HTTPException(status_code=404, detail="voice not found")
    return {"deleted": vid}


@app.post("/model/switch")
async def switch_model(model: str) -> dict:
    if model not in MODELS:
        raise HTTPException(status_code=400, detail=f"unknown model; choose {list(MODELS)}")
    await _run_infer(engine.load, model)
    return {"model": engine.model_key}


def _resolve_voice(req: SynthRequest) -> Voice:
    voice = store.resolve(req.voice)
    if voice is None and req.voice and req.voice in engine.supported_speakers():
        voice = Voice(name=req.voice, speaker=req.voice)
    return voice or Voice("default")


@app.post("/synthesize")
async def synthesize(req: SynthRequest) -> StreamingResponse:
    if not req.text.strip():
        raise HTTPException(status_code=400, detail="empty text")
    model = req.model
    if model is not None and model not in MODELS:
        # Reject an unknown model up front instead of raising mid-stream, which
        # would otherwise reach the client as an empty 200 (no audio, no error).
        raise HTTPException(status_code=400,
                            detail=f"unknown model {model!r}; choose {list(MODELS)}")
    voice = _resolve_voice(req)
    pcm_queue: "queue.Queue" = queue.Queue(maxsize=_QUEUE_MAX)
    cancel = threading.Event()

    def produce() -> None:
        try:
            if model and model != engine.model_key:
                engine.load(model)
            for chunk in engine.synthesize_pcm16(req.text, voice, req.speed,
                                                 temperature=req.temperature,
                                                 repetition_penalty=req.repetition_penalty):
                while not cancel.is_set():
                    try:
                        pcm_queue.put(chunk, timeout=_PUT_TIMEOUT)
                        break
                    except queue.Full:
                        continue
                if cancel.is_set():
                    return
        except Exception as exc:  # noqa: BLE001 -- forward to the client stream
            _safe_put(pcm_queue, exc)
        finally:
            _safe_put(pcm_queue, _DONE)

    infer_pool.submit(produce)

    async def stream():
        loop = asyncio.get_running_loop()
        try:
            while True:
                item = await loop.run_in_executor(None, pcm_queue.get)
                if item is _DONE:
                    break
                if isinstance(item, Exception):
                    raise item
                yield item
        finally:
            cancel.set()

    media = f"audio/L16; rate={engine.sample_rate}; channels=1"
    return StreamingResponse(stream(), media_type=media)


def _safe_put(q: "queue.Queue", item) -> None:
    try:
        q.put_nowait(item)
    except queue.Full:
        pass


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8765)
