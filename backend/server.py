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
import io
import json
import os
import queue
import shutil
import signal
import subprocess
import threading
import time
import urllib.request
import wave
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Optional

import uvicorn
from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel, Field
from starlette.responses import Response, StreamingResponse

from tts_engine import MODELS, Engine, Voice
from voices import VoiceStore

engine = Engine()
store = VoiceStore()
infer_pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="tts-infer")

# Encoding to MP3 needs ffmpeg; without it export falls back to WAV (always
# available via the standard library). Resolved once at startup.
FFMPEG = shutil.which("ffmpeg")

# Optional title generation talks to a local, OpenAI-compatible LLM service.
# Both the endpoint and (optionally) the fixed model are configurable; when no
# model is loaded there, title generation simply yields an empty title.
LLM_BASE_URL = os.environ.get("PAPPAGEI_LLM_BASE_URL", "http://127.0.0.1:1234/v1").rstrip("/")
LLM_MODEL = os.environ.get("PAPPAGEI_LLM_MODEL")  # None -> use the first loaded model

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
API_VERSION = "0.4.0"

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
    {"name": "Export", "description": "Text als fertige Audiodatei erzeugen "
                                      "(WAV oder MP3) und optional einen Titel dazu."},
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


class ExportRequest(BaseModel):
    text: str = Field(description="Der Gesamttext, der als Audiodatei erzeugt werden soll.",
                      json_schema_extra={"example": "Ein längerer Text, der als Datei gesichert wird."})
    voice: Optional[str] = Field(default=None,
                                 description="Id oder Name einer eigenen Stimme, oder ein "
                                             "eingebauter Sprecher (siehe GET /voices). "
                                             "Ohne Angabe spricht der Standard-Sprecher.")
    model: Optional[str] = Field(default=None,
                                 description="Modell-Schlüssel '0.6b' oder '1.7b'; ohne Angabe "
                                             "bleibt das aktuell geladene Modell aktiv.")
    format: Optional[str] = Field(default=None,
                                  description="'mp3' oder 'wav'. Ohne Angabe MP3, wenn ffmpeg "
                                              "vorhanden ist, sonst WAV. Fehlt ffmpeg, wird "
                                              "MP3 automatisch auf WAV zurückgestuft; das "
                                              "tatsächliche Format steht im Header X-Audio-Format.")
    temperature: Optional[float] = Field(default=None,
                                         description="Sampling-Temperatur (etwa 0.3 bis 1.0).")
    repetition_penalty: Optional[float] = Field(default=None,
                                                description="Wiederholungs-Strafe (etwa 1.0 bis 1.3).")


class TitleRequest(BaseModel):
    text: str = Field(description="Text, für den ein kurzer Titel erzeugt werden soll.",
                      json_schema_extra={"example": "Ein Text über Katzen und ihre Gewohnheiten."})


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


class TitleResponse(BaseModel):
    title: Optional[str] = Field(description="Der erzeugte Titel, oder null, wenn kein LLM "
                                             "verfügbar ist.")
    model: Optional[str] = Field(default=None,
                                 description="Das LLM, das den Titel erzeugt hat, oder null.")


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


def _resolve_voice_key(key: Optional[str]) -> Voice:
    voice = store.resolve(key)
    if voice is None and key and key in engine.supported_speakers():
        voice = Voice(name=key, speaker=key)
    return voice or Voice("default")


def _resolve_voice(req: SynthRequest) -> Voice:
    return _resolve_voice_key(req.voice)


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


# --- export: text to a finished audio file -----------------------------------
# Unlike /synthesize (a headerless PCM stream), /export renders the whole text
# and returns a ready-to-save file: WAV via the standard library, or MP3 when
# ffmpeg is present. The exported audio is at natural speed; the app's tempo is
# a playback-only time-stretch and intentionally not baked into the file.

def _render_pcm(req: ExportRequest, voice: Voice) -> bytes:
    """Synthesize the full text on the inference thread and return all PCM."""
    if req.model and req.model != engine.model_key:
        engine.load(req.model)
    chunks = engine.synthesize_pcm16(req.text, voice, 1.0,
                                     temperature=req.temperature,
                                     repetition_penalty=req.repetition_penalty)
    return b"".join(chunks)


def _pcm_to_wav(pcm: bytes, rate: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)         # 16-bit
        w.setframerate(rate)
        w.writeframes(pcm)
    return buf.getvalue()


def _pcm_to_mp3(pcm: bytes, rate: int) -> bytes:
    """Encode 16-bit mono PCM to MP3 via ffmpeg (stdin -> stdout)."""
    proc = subprocess.run(
        [FFMPEG, "-loglevel", "error", "-f", "s16le", "-ar", str(rate), "-ac", "1",
         "-i", "pipe:0", "-codec:a", "libmp3lame", "-b:a", "128k", "-f", "mp3", "pipe:1"],
        input=pcm, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
    )
    return proc.stdout


@app.post("/export", tags=["Export"],
          summary="Gesamttext als Audiodatei erzeugen (WAV oder MP3)",
          responses={
              200: {
                  "description": "Fertige Audiodatei. Der Header X-Audio-Format nennt das "
                                 "tatsächliche Format ('mp3' oder 'wav'), X-Audio-Duration-Seconds "
                                 "die Länge in Sekunden, X-Audio-Sample-Rate die Abtastrate.",
                  "content": {"audio/mpeg": {}, "audio/wav": {}},
              },
              400: {"description": "Leerer Text, unbekanntes Format oder unbekannter Modell-Schlüssel."},
              413: {"description": "Text länger als das Limit (50000 Zeichen)."},
          })
async def export(req: ExportRequest) -> Response:
    """Synthetisiert den kompletten Text und gibt ihn als fertige Datei zurück.

    MP3 entsteht, wenn ffmpeg vorhanden ist; sonst (oder bei `format=wav`) WAV.
    Fehlt ffmpeg trotz `format=mp3`, wird still auf WAV zurückgestuft - das
    tatsächliche Format steht im Header `X-Audio-Format`.
    """
    text = req.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="empty text")
    if len(text) > _SPEAK_TEXT_MAX:
        raise HTTPException(status_code=413, detail=f"text too long (max {_SPEAK_TEXT_MAX})")
    if req.model is not None and req.model not in MODELS:
        raise HTTPException(status_code=400,
                            detail=f"unknown model {req.model!r}; choose {list(MODELS)}")
    fmt = (req.format or ("mp3" if FFMPEG else "wav")).lower()
    if fmt not in ("mp3", "wav"):
        raise HTTPException(status_code=400, detail="format must be 'mp3' or 'wav'")

    voice = _resolve_voice_key(req.voice)
    pcm = await _run_infer(_render_pcm, req, voice)
    if not pcm:
        raise HTTPException(status_code=500, detail="no audio produced")
    rate = engine.sample_rate

    data = None
    if fmt == "mp3" and FFMPEG:
        try:
            data = await asyncio.to_thread(_pcm_to_mp3, pcm, rate)
        except Exception:  # noqa: BLE001 -- fall back to WAV if the encoder fails
            data = None
    if data is None:
        fmt = "wav"
        data = _pcm_to_wav(pcm, rate)

    duration = len(pcm) / 2 / rate       # 16-bit mono -> 2 bytes per sample
    headers = {
        "Content-Disposition": f'attachment; filename="pappagei.{fmt}"',
        "X-Audio-Format": fmt,
        "X-Audio-Duration-Seconds": f"{duration:.3f}",
        "X-Audio-Sample-Rate": str(rate),
    }
    media = "audio/mpeg" if fmt == "mp3" else "audio/wav"
    return Response(content=data, media_type=media, headers=headers)


# --- title: optional short title via a local LLM ------------------------------
# Best-effort and fully optional: if no OpenAI-compatible model is reachable at
# LLM_BASE_URL, every path returns an empty title instead of raising.

def _http_json(url: str, payload: Optional[dict] = None, timeout: float = 5.0) -> dict:
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(
        url, data=body,
        headers={"Content-Type": "application/json"},
        method="POST" if body is not None else "GET",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _llm_model() -> Optional[str]:
    """The model to use: a fixed override, else the first one loaded remotely."""
    if LLM_MODEL:
        return LLM_MODEL
    try:
        info = _http_json(LLM_BASE_URL + "/models", timeout=2.0)
        models = info.get("data") or []
        return models[0]["id"] if models else None
    except Exception:  # noqa: BLE001 -- LLM is optional; treat any error as "none"
        return None


def _clean_title(raw: str) -> str:
    lines = [ln.strip() for ln in (raw or "").splitlines() if ln.strip()]
    t = lines[-1] if lines else ""          # skip any leading "reasoning" lines
    # Peel wrapping quotes and trailing punctuation until nothing changes, so
    # interleaved cases like  "Titel".  come out clean.
    prev = None
    while t != prev:
        prev = t
        t = t.strip().strip("\"'«»„“”‚‘’").strip()
        while t and t[-1] in ".!?:;,":
            t = t[:-1].strip()
    return t[:80]


def _generate_title(text: str, model: str) -> Optional[str]:
    payload = {
        "model": model,
        "messages": [
            {"role": "system",
             "content": "Du erzeugst einen kurzen, treffenden Titel auf Deutsch für einen Text. "
                        "Fasse den Inhalt in 2 bis 6 Wörtern zusammen. Antworte NUR mit dem Titel, "
                        "ohne Anführungszeichen und ohne Satzzeichen am Ende."},
            {"role": "user", "content": text[:4000]},
        ],
        "temperature": 0.3,
        "max_tokens": 32,
        "stream": False,
    }
    try:
        resp = _http_json(LLM_BASE_URL + "/chat/completions", payload, timeout=30.0)
        content = resp["choices"][0]["message"]["content"]
        return _clean_title(content) or None
    except Exception:  # noqa: BLE001 -- title stays empty if the LLM cannot answer
        return None


@app.post("/title", response_model=TitleResponse, tags=["Export"],
          summary="Kurzen Titel für den Text erzeugen (optional, per lokalem LLM)")
async def title(req: TitleRequest) -> dict:
    """Erzeugt einen kurzen Titel, wenn ein lokales LLM erreichbar ist.

    Ist keins geladen (oder antwortet es nicht), kommt `title: null` zurück -
    die App lässt den Titel dann einfach leer.
    """
    text = req.text.strip()
    if not text:
        return {"title": None, "model": None}
    model = await asyncio.to_thread(_llm_model)
    if not model:
        return {"title": None, "model": None}
    generated = await asyncio.to_thread(_generate_title, text, model)
    return {"title": generated, "model": model if generated else None}


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8765)
