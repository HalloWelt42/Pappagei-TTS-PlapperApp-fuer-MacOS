"""Prove zero-shot voice cloning works and measure streaming latency.

We synthesize a short reference clip with one preset voice (a stand-in for the
user's own MP3/WAV), then ask the CustomVoice model to clone it. This validates
the full code path without needing the user's recording yet. Listen to
clone_out.wav versus ref_synth.wav to judge that cloning tracks the reference.
"""
from __future__ import annotations

import gc
import time
import wave
from pathlib import Path

from tts_engine import Engine, Voice

REF_TEXT = "Dies ist meine Referenzstimme fuer den Klontest mit pappagei."
SAY = "Hallo! Ich bin eine geklonte Stimme und lese jetzt deinen markierten Text vor."


def write_wav(path: Path, pcm16: bytes, rate: int) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm16)


def collect(engine: Engine, text: str, voice: Voice):
    t0 = time.perf_counter()
    first = None
    chunks = 0
    out = bytearray()
    for chunk in engine.synthesize_pcm16(text, voice):
        if first is None:
            first = time.perf_counter() - t0
        chunks += 1
        out += chunk
    total = time.perf_counter() - t0
    secs = len(out) / 2 / engine.sample_rate
    return bytes(out), first, total, secs, chunks


def main() -> None:
    here = Path(__file__).parent

    # 1) Reference clip from a distinct preset voice (stand-in for the user's clip).
    base = Engine(model_key="0.6b")
    base.load()
    ref_pcm, _, _, ref_secs, _ = collect(base, REF_TEXT, Voice("ref", speaker="Vivian"))
    ref = here / "ref_synth.wav"
    write_wav(ref, ref_pcm, base.sample_rate)
    print(f"reference clip: {ref.name} ({ref_secs:.2f}s, speaker Vivian)")
    del base
    gc.collect()

    # 2) Clone it with the CustomVoice model.
    cv = Engine(model_key="0.6b-clone")
    t0 = time.perf_counter()
    cv.load()
    print(f"CustomVoice loaded in {time.perf_counter() - t0:.1f}s -> {cv.model_key}")

    voice = Voice("meine_stimme", speaker="serena", ref_audio=str(ref), ref_text=REF_TEXT)
    pcm, first, total, secs, chunks = collect(cv, SAY, voice)
    write_wav(here / "clone_out.wav", pcm, cv.sample_rate)
    print(
        f"CLONE OK: {chunks} stream chunks, TTFA {first:.2f}s, total {total:.2f}s "
        f"for {secs:.2f}s audio, RTF {total / max(secs, 1e-6):.2f}"
    )
    print("wrote clone_out.wav (compare against ref_synth.wav)")


if __name__ == "__main__":
    main()
