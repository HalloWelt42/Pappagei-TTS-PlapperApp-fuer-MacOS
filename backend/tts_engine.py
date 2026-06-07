"""pappagei TTS engine: Qwen3-TTS (Base model) via mlx-audio.

Voice cloning: the Base model has a speaker_encoder, so passing `ref_audio` alone
(NO transcript, no extra model) clones the speaker's voice. Built-in presets are
used when no ref_audio is given. CustomVoice/VoiceDesign variants do NOT clone
from a reference and are intentionally not used.
"""
from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field
from typing import Iterator, List, Optional

import numpy as np

from mlx_audio.tts.utils import load_model

MODELS = {
    "0.6b": "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16",   # default, cloning-capable
    "1.7b": "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit",   # higher quality
}
DEFAULT_MODEL = "0.6b"
BASE_SPEAKERS = ["Chelsie", "Ethan", "Vivian"]
DEFAULT_VOICE = "Chelsie"
DEFAULT_LANG_CODE = "auto"
DEFAULT_SAMPLE_RATE = 24000
CLONE_REPETITION_PENALTY = 1.3   # keeps cloned output from rambling


def _to_waveform(audio_obj) -> np.ndarray:
    if isinstance(audio_obj, np.ndarray):
        return audio_obj.astype(np.float32).reshape(-1)
    try:
        return np.array(audio_obj, dtype=np.float32).reshape(-1)
    except Exception:
        return np.array(audio_obj.tolist(), dtype=np.float32).reshape(-1)


@dataclass
class Voice:
    """A preset speaker, or a clone from a reference clip (audio only, no transcript)."""
    name: str
    speaker: str = DEFAULT_VOICE
    ref_audio: Optional[str] = None
    ref_text: Optional[str] = None   # optional; not needed for cloning


@dataclass
class Engine:
    model_key: str = DEFAULT_MODEL
    lang_code: str = DEFAULT_LANG_CODE
    sample_rate: int = DEFAULT_SAMPLE_RATE
    streaming_interval: float = 0.5
    temperature: float = 0.7
    top_p: float = 0.9
    repetition_penalty: float = 1.1
    _model: object = field(default=None, repr=False)
    _lock: threading.Lock = field(default_factory=threading.Lock, repr=False)

    @property
    def loaded(self) -> bool:
        return self._model is not None

    def load(self, model_key: Optional[str] = None) -> None:
        key = model_key or self.model_key
        if key not in MODELS:
            raise ValueError(f"unknown model {key!r}; choose from {list(MODELS)}")
        with self._lock:
            self._model = load_model(MODELS[key])
            self.model_key = key

    def ensure_loaded(self) -> None:
        if self._model is None:
            self.load()

    def supported_speakers(self) -> List[str]:
        return BASE_SPEAKERS

    def warmup(self, voice: Optional[Voice] = None) -> float:
        self.ensure_loaded()
        v = voice or Voice("warmup")
        t0 = time.perf_counter()
        for _ in self._generate("Aufwaermen.", v):
            pass
        return time.perf_counter() - t0

    def _generate(self, text: str, voice: Voice, speed: float = 1.0,
                  temperature: Optional[float] = None,
                  repetition_penalty: Optional[float] = None) -> Iterator[np.ndarray]:
        temp = self.temperature if temperature is None else temperature
        rep = self.repetition_penalty if repetition_penalty is None else repetition_penalty
        kwargs = dict(
            text=text,
            lang_code=self.lang_code,
            speed=speed,
            temperature=temp,
            top_p=self.top_p,
            stream=True,
            streaming_interval=self.streaming_interval,
        )
        if voice.ref_audio:
            # Audio-only voice cloning via the speaker encoder (no transcript needed).
            kwargs["ref_audio"] = voice.ref_audio
            kwargs["repetition_penalty"] = max(rep, CLONE_REPETITION_PENALTY)
            if voice.ref_text:
                kwargs["ref_text"] = voice.ref_text
        else:
            kwargs["voice"] = voice.speaker or DEFAULT_VOICE
            kwargs["repetition_penalty"] = rep
        for result in self._model.generate(**kwargs):
            rate = getattr(result, "sample_rate", None)
            if rate:
                self.sample_rate = int(rate)
            yield _to_waveform(result.audio)

    def synthesize_pcm16(self, text: str, voice: Voice, speed: float = 1.0,
                         temperature: Optional[float] = None,
                         repetition_penalty: Optional[float] = None) -> Iterator[bytes]:
        """Yield little-endian int16 mono PCM, streaming as the model generates."""
        self.ensure_loaded()
        with self._lock:
            for wave in self._generate(text, voice, speed, temperature, repetition_penalty):
                if wave.size == 0:
                    continue
                clipped = np.clip(wave, -1.0, 1.0)
                yield (clipped * 32767.0).astype("<i2").tobytes()
