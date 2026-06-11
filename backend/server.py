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
from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel, Field
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


# Keep in sync with VERSION in scripts/make_app.sh.
API_VERSION = "0.3.1"

API_DESCRIPTION = """\
Lokale Schnittstelle der pappagei-App: Text-zu-Sprache mit Qwen3-TTS auf
Apple Silicon, inklusive Voice-Cloning aus Referenz-Audio.

- Erreichbar nur auf diesem Rechner (`127.0.0.1:8765`), keine Anmeldung.
- `/synthesize` liefert Audio als Rohdaten-Stream (PCM, siehe dort).
- Die Vorlese-Brücke (`/speak`) nimmt Text von lokalen Werkzeugen wie der
  Browser-Erweiterung an; gesprochen wird in der App selbst.

Interaktive Oberfläche: [/docs](/docs) - maschinenlesbar: [/openapi.json](/openapi.json),
im Repo als `docs/api.yaml`.
"""

OPENAPI_TAGS = [
    {"name": "Status", "description": "Zustand des Dienstes und des geladenen Modells."},
    {"name": "Stimmen", "description": "Eingebaute Sprecher und eigene, geklonte Stimmen."},
    {"name": "Modelle", "description": "Zwischen den TTS-Modellen wechseln."},
    {"name": "Synthese", "description": "Text in Audio umwandeln (Streaming)."},
    {"name": "Vorlese-Brücke", "description": "Text zum Vorlesen an die App übergeben "
                                              "(genutzt von der Browser-Erweiterung)."},
]

app = FastAPI(
    title="pappagei TTS API",
    version=API_VERSION,
    description=API_DESCRIPTION,
    openapi_tags=OPENAPI_TAGS,
    lifespan=lifespan,
)


class SynthRequest(BaseModel):
    text: str = Field(description="Der zu sprechende Text.",
                      json_schema_extra={"example": "Hallo, das ist ein Test."})
    voice: Optional[str] = Field(default=None,
                                 description="Id oder Name einer eigenen Stimme, oder ein "
                                             "eingebauter Sprecher (siehe GET /voices). "
                                             "Ohne Angabe spricht der Standard-Sprecher.")
    model: Optional[str] = Field(default=None,
                                 description="Modell-Schlüssel '0.6b' oder '1.7b'; ohne Angabe "
                                             "bleibt das aktuell geladene Modell aktiv.")
    speed: float = Field(default=1.0,
                         description="Modellseitiger Tempo-Faktor; wirkt praktisch kaum. Die App "
                                     "regelt das Tempo über die Audio-Wiedergabe.")
    temperature: Optional[float] = Field(default=None,
                                         description="Sampling-Temperatur (etwa 0.3 bis 1.0).")
    repetition_penalty: Optional[float] = Field(default=None,
                                                description="Wiederholungs-Strafe (etwa 1.0 bis 1.3).")


class SpeakRequest(BaseModel):
    text: str = Field(description="Der Text, den die App vorlesen soll.",
                      json_schema_extra={"example": "Diesen Absatz bitte vorlesen."})


class ImportRequest(BaseModel):
    name: str = Field(description="Anzeigename der neuen Stimme.")
    audio_path: str = Field(description="Absoluter Pfad zur Referenz-Aufnahme (WAV oder mp3, "
                                        "etwa 5 bis 10 Sekunden, ein Sprecher).")
    transcript: Optional[str] = Field(default=None,
                                      description="Optionales Transkript der Aufnahme; für das "
                                                  "Cloning nicht erforderlich.")
    speaker: Optional[str] = Field(default=None,
                                   description="Eingebauter Basis-Sprecher als Rückfallebene.")


# --- response models ---------------------------------------------------------

class HealthResponse(BaseModel):
    status: str = Field(description="'ok', sobald der Dienst antwortet.")
    model: str = Field(description="Aktiver Modell-Schlüssel ('0.6b' oder '1.7b').")
    loaded: bool = Field(description="True, wenn das Modell geladen und sprechbereit ist.")
    loading: bool = Field(description="True, während ein Modell lädt oder herunterlädt.")
    download_bytes: Optional[int] = Field(description="Größe des Modell-Caches in Bytes, "
                                                      "nur während des Ladens; wächst bei "
                                                      "laufendem Download.")
    sample_rate: int = Field(description="Abtastrate des Audio-Streams in Hz.")


class WarmupResponse(BaseModel):
    warmup_seconds: float = Field(description="Dauer des Aufwärm-Laufs in Sekunden.")
    sample_rate: int = Field(description="Abtastrate des Audio-Streams in Hz.")


class VoiceInfo(BaseModel):
    id: str = Field(description="Kurze Id der Stimme (für 'voice' in /synthesize).")
    name: str = Field(description="Anzeigename.")
    ref_audio: str = Field(description="Lokaler Pfad der hinterlegten Referenz-Aufnahme.")
    ref_text: Optional[str] = Field(default=None, description="Hinterlegtes Transkript, falls vorhanden.")
    speaker: Optional[str] = Field(default=None, description="Basis-Sprecher als Rückfallebene.")


class VoicesListResponse(BaseModel):
    model: str = Field(description="Aktiver Modell-Schlüssel.")
    speakers: list[str] = Field(description="Eingebaute Sprecher.")
    custom: list[VoiceInfo] = Field(description="Eigene, geklonte Stimmen.")


class DeleteVoiceResponse(BaseModel):
    deleted: str = Field(description="Id der entfernten Stimme.")


class ModelSwitchResponse(BaseModel):
    model: str = Field(description="Nach dem Wechsel aktiver Modell-Schlüssel.")


class QueuedResponse(BaseModel):
    queued: bool = Field(description="True: das Kommando liegt für die App bereit.")


class SpeakCommandResponse(BaseModel):
    action: str = Field(description="'speak' (Text vorlesen), 'stop' (Wiedergabe stoppen) "
                                    "oder 'none' (Zeitfenster ohne Kommando abgelaufen).")
    text: Optional[str] = Field(default=None, description="Der Text bei action='speak'.")


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


@app.get("/health", response_model=HealthResponse, tags=["Status"],
         summary="Zustand des Dienstes")
def health() -> dict:
    """Antwortet sofort, auch während Synthese oder Modell-Download.

    Während eines Modell-Ladevorgangs ist `loading` true und `download_bytes`
    zeigt die bereits im Cache liegende Datenmenge (wächst bei laufendem
    Download zwischen zwei Abfragen).
    """
    loading = engine.loading
    return {
        "status": "ok",
        "model": engine.model_key,
        "loaded": engine.loaded,
        "loading": loading,
        "download_bytes": _model_cache_bytes(engine.loading_model_key) if loading else None,
        "sample_rate": engine.sample_rate,
    }


@app.post("/warmup", response_model=WarmupResponse, tags=["Status"],
          summary="Modell laden und aufwärmen")
async def warmup() -> dict:
    """Lädt das aktive Modell (falls nötig) und spricht einen kurzen Probelauf.

    Blockiert, bis das Modell bereit ist - beim allerersten Aufruf inklusive
    Download. Danach starten Synthesen ohne Anlaufzeit.
    """
    secs = await _run_infer(engine.warmup)
    return {"warmup_seconds": secs, "sample_rate": engine.sample_rate}


@app.get("/voices", response_model=VoicesListResponse, tags=["Stimmen"],
         summary="Sprecher und eigene Stimmen auflisten")
def list_voices() -> dict:
    """Eingebaute Sprecher plus alle importierten (geklonten) Stimmen.

    Beide Arten lassen sich in `/synthesize` als `voice` verwenden:
    Sprecher über ihren Namen, eigene Stimmen über `id` oder `name`.
    """
    return {
        "model": engine.model_key,
        "speakers": engine.supported_speakers(),
        "custom": store.list(),
    }


@app.post("/voices/import", response_model=VoiceInfo, tags=["Stimmen"],
          summary="Eigene Stimme aus einer Aufnahme anlegen")
def import_voice(req: ImportRequest) -> dict:
    """Klont eine Stimme aus einer Referenz-Aufnahme (WAV oder mp3).

    Die Aufnahme wird kopiert und dauerhaft hinterlegt; ein Transkript ist
    nicht nötig (das Base-Modell klont über den Sprecher-Encoder direkt aus
    dem Audio). Empfohlen: 5 bis 10 Sekunden, klar gesprochen, ein Sprecher.
    """
    return store.import_voice(req.name, req.audio_path, req.transcript, req.speaker or "Chelsie")


@app.delete("/voices/{vid}", response_model=DeleteVoiceResponse, tags=["Stimmen"],
            summary="Eigene Stimme löschen",
            responses={404: {"description": "Keine Stimme mit dieser Id."}})
def delete_voice(vid: str) -> dict:
    """Entfernt die Stimme samt hinterlegter Referenz-Aufnahme."""
    if not store.delete(vid):
        raise HTTPException(status_code=404, detail="voice not found")
    return {"deleted": vid}


@app.post("/model/switch", response_model=ModelSwitchResponse, tags=["Modelle"],
          summary="TTS-Modell wechseln",
          responses={400: {"description": "Unbekannter Modell-Schlüssel."}})
async def switch_model(
    model: str = Query(description="Ziel-Modell: '0.6b' (schnell) oder '1.7b' (höhere Qualität).")
) -> dict:
    """Lädt das angegebene Modell und macht es zum aktiven Modell.

    Blockiert, bis das Modell bereit ist; beim ersten Wechsel auf ein noch
    nicht heruntergeladenes Modell entsprechend lange (Fortschritt über
    `GET /health` beobachtbar).
    """
    if model not in MODELS:
        raise HTTPException(status_code=400, detail=f"unknown model; choose {list(MODELS)}")
    await _run_infer(engine.load, model)
    return {"model": engine.model_key}


# --- speak bridge ------------------------------------------------------------
# Local tools (the browser extension) hand text in via POST /speak; the app
# long-polls /speak/next and reads it through its normal pipeline, so voice,
# tempo, pause/stop and the menu status all behave exactly like everywhere else.

_SPEAK_TEXT_MAX = 50_000
_speak_queue: "asyncio.Queue[dict]" = asyncio.Queue(maxsize=4)


def _drain_speak_queue() -> None:
    try:
        while True:
            _speak_queue.get_nowait()
    except asyncio.QueueEmpty:
        pass


@app.post("/speak", response_model=QueuedResponse, tags=["Vorlese-Brücke"],
          summary="Text zum Vorlesen übergeben",
          responses={400: {"description": "Leerer Text."},
                     413: {"description": "Text länger als das Limit (50000 Zeichen)."}})
async def speak(req: SpeakRequest) -> dict:
    """Reicht Text an die App weiter, die ihn vorliest.

    Gesprochen wird mit der in der App gewählten Stimme und deren Tempo,
    satzweise gestreamt. Der neueste Auftrag gewinnt: ein weiterer Aufruf
    ersetzt einen noch nicht abgeholten und unterbricht laufende Wiedergabe.
    """
    text = req.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="empty text")
    if len(text) > _SPEAK_TEXT_MAX:
        raise HTTPException(status_code=413, detail=f"text too long (max {_SPEAK_TEXT_MAX})")
    _drain_speak_queue()          # newest request wins, like the clipboard mode
    await _speak_queue.put({"action": "speak", "text": text})
    return {"queued": True}


@app.post("/speak/stop", response_model=QueuedResponse, tags=["Vorlese-Brücke"],
          summary="Wiedergabe stoppen")
async def speak_stop() -> dict:
    """Verwirft wartende Aufträge und stoppt die laufende Wiedergabe der App."""
    _drain_speak_queue()
    await _speak_queue.put({"action": "stop"})
    return {"queued": True}


@app.get("/speak/next", response_model=SpeakCommandResponse, tags=["Vorlese-Brücke"],
         summary="Nächstes Kommando abholen (Long-Poll, intern)")
async def speak_next(
    timeout: float = Query(default=25.0, ge=0.0, le=60.0,
                           description="Wartezeit in Sekunden, bevor 'none' zurückkommt.")
) -> dict:
    """Long-Poll-Gegenstück für die App; Werkzeuge brauchen es nicht.

    Hängt, bis ein Kommando eintrifft oder das Zeitfenster abläuft
    (`action: none`). Die App ruft den Endpunkt in einer Endlosschleife.
    """
    try:
        return await asyncio.wait_for(_speak_queue.get(),
                                      timeout=timeout)
    except asyncio.TimeoutError:
        return {"action": "none"}


def _resolve_voice(req: SynthRequest) -> Voice:
    voice = store.resolve(req.voice)
    if voice is None and req.voice and req.voice in engine.supported_speakers():
        voice = Voice(name=req.voice, speaker=req.voice)
    return voice or Voice("default")


@app.post("/synthesize", tags=["Synthese"],
          summary="Text in Audio umwandeln (PCM-Stream)",
          responses={
              200: {
                  "description": "Roh-Audio als Stream: PCM, 16 Bit signed little-endian, "
                                 "mono, Abtastrate laut `GET /health` (Standard 24000 Hz). "
                                 "Die Daten beginnen, sobald das Modell erste Stücke liefert.",
                  "content": {"audio/L16; rate=24000; channels=1": {}},
              },
              400: {"description": "Leerer Text oder unbekannter Modell-Schlüssel."},
          })
async def synthesize(req: SynthRequest) -> StreamingResponse:
    """Synthetisiert den Text und streamt das Audio noch während der Erzeugung.

    Wiedergabe-Beispiel (Stream nach WAV wandeln):
    `curl -s -X POST -H 'Content-Type: application/json' -d '{"text":"Hallo."}'
    http://127.0.0.1:8765/synthesize | ffmpeg -f s16le -ar 24000 -ac 1 -i - hallo.wav`
    """
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
