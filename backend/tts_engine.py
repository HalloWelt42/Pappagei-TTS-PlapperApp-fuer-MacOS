"""pappagei TTS engine: a thin wrapper around mlx-audio Qwen3-TTS.

Verified mlx-audio generate() signature (Qwen3-TTS):
    generate(text, voice=None, instruct=None, temperature=0.9, speed=1.0,
             lang_code='auto', ref_audio=None, ref_text=None, split_pattern='\\n',
             max_tokens=4096, stream=False, streaming_interval=2.0, ...)

Learned from the POC:
  - `voice` (a base speaker name) is ALWAYS required, including for the
    CustomVoice cloning model. Cloning = a speaker plus ref_audio/ref_text.
  - Language is controlled via `lang_code` ('auto' detects from the text).
  - `stream=True` yields partial audio during generation (lower latency).
  - Output is a 24 kHz mono float waveform in result.audio.
"""
from __future__ import annotations

import re
import threading
import time
from dataclasses import dataclass, field
from typing import Iterator, List, Optional

import numpy as np

from mlx_audio.tts.utils import load_model

MODELS = {
    # Base models: built-in preset voices (e.g. "Chelsie").
    "0.6b": "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16",
    "1.7b": "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit",
    # CustomVoice models: zero-shot cloning from a reference clip.
    "0.6b-clone": "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit",   # lighter, faster fallback
    "1.7b-clone": "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",   # primary solution
}
# 1.7B CustomVoice (8-bit) is the chosen model solution; 0.6B stays as a fast fallback.
DEFAULT_MODEL = "1.7b-clone"

# Each model family accepts a DIFFERENT set of base speaker names (confirmed in POC).
BASE_SPEAKERS = ["Chelsie", "Ethan", "Vivian"]
CLONE_SPEAKERS = [
    "serena", "vivian", "uncle_fu", "ryan", "aiden",
    "ono_anna", "sohee", "eric", "dylan",
]
DEFAULT_VOICE = "Chelsie"            # default base-model preset
DEFAULT_CLONE_SPEAKER = "vivian"     # default base speaker for the clone model
DEFAULT_LANG_CODE = "auto"           # detect language from text; or force e.g. "de"
DEFAULT_SAMPLE_RATE = 24000          # confirmed: 24 kHz mono

# Sentence splitter on terminator characters only (a character class, no
# alternation, hence no pipe characters).
_SENTENCE_RE = re.compile(r"[.!?…\n]+")


def split_sentences(text: str) -> List[str]:
    return [part.strip() for part in _SENTENCE_RE.split(text) if part.strip()]


def _to_waveform(audio_obj) -> np.ndarray:
    """Convert an mlx/ndarray/list audio object to a flat float32 numpy array."""
    if isinstance(audio_obj, np.ndarray):
        return audio_obj.astype(np.float32).reshape(-1)
    try:
        return np.array(audio_obj, dtype=np.float32).reshape(-1)
    except Exception:
        return np.array(audio_obj.tolist(), dtype=np.float32).reshape(-1)


@dataclass
class Voice:
    """A Qwen3-TTS voice: a required base speaker, optionally cloned via reference.

    For the CustomVoice model, `speaker` is always required; `ref_audio` (plus an
    optional transcript) adapts the timbre toward the reference recording.
    """
    name: str
    speaker: str = DEFAULT_VOICE
    ref_audio: Optional[str] = None
    ref_text: Optional[str] = None


@dataclass
class Engine:
    model_key: str = DEFAULT_MODEL
    lang_code: str = DEFAULT_LANG_CODE
    sample_rate: int = DEFAULT_SAMPLE_RATE
    streaming_interval: float = 0.5
    temperature: float = 0.7          # lower than the 0.9 default to curb rambling
    top_p: float = 0.9
    repetition_penalty: float = 1.1   # discourages repeated/looped tokens
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

    @property
    def is_clone_model(self) -> bool:
        return self.model_key.endswith("-clone")

    def supported_speakers(self) -> List[str]:
        return CLONE_SPEAKERS if self.is_clone_model else BASE_SPEAKERS

    def _resolve_speaker(self, voice: Voice) -> str:
        """Pick a base speaker valid for the current model (families differ)."""
        if voice.speaker in self.supported_speakers():
            return voice.speaker
        return DEFAULT_CLONE_SPEAKER if self.is_clone_model else DEFAULT_VOICE

    def warmup(self, voice: Optional[Voice] = None) -> float:
        """Run one tiny synthesis so the first real request is fast."""
        self.ensure_loaded()
        v = voice or Voice("warmup")
        t0 = time.perf_counter()
        for _ in self._generate("Aufwaermen.", v):
            pass
        return time.perf_counter() - t0

    def _generate(self, text: str, voice: Voice, speed: float = 1.0,
                  temperature: Optional[float] = None,
                  repetition_penalty: Optional[float] = None) -> Iterator[np.ndarray]:
        kwargs = dict(
            text=text,
            voice=self._resolve_speaker(voice),   # always required, model-specific
            lang_code=self.lang_code,
            speed=speed,
            temperature=self.temperature if temperature is None else temperature,
            top_p=self.top_p,
            repetition_penalty=self.repetition_penalty if repetition_penalty is None else repetition_penalty,
            stream=True,
            streaming_interval=self.streaming_interval,
        )
        if voice.ref_audio:
            kwargs["ref_audio"] = voice.ref_audio
            if voice.ref_text:
                kwargs["ref_text"] = voice.ref_text
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
            for wave in self._generate(text, voice, speed,
                                       temperature=temperature,
                                       repetition_penalty=repetition_penalty):
                if wave.size == 0:
                    continue
                clipped = np.clip(wave, -1.0, 1.0)
                yield (clipped * 32767.0).astype("<i2").tobytes()
