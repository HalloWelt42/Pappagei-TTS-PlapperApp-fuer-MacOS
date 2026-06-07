"""Self-test: load the default model and synthesize a German sentence.

Run from the backend directory:
    .venv/bin/python selftest.py
Writes selftest.wav and prints load/synthesis timing.
"""
from __future__ import annotations

import time
import wave
from pathlib import Path

from tts_engine import Engine, Voice


def main() -> None:
    engine = Engine()
    t0 = time.perf_counter()
    engine.load()
    print(f"Modell geladen: {engine.model_key} in {time.perf_counter() - t0:.1f}s, {engine.sample_rate} Hz")

    voice = Voice("test", speaker="vivian")
    text = "Hallo! pappagei ist startklar und liest Text vor."
    t0 = time.perf_counter()
    pcm = b"".join(engine.synthesize_pcm16(text, voice))
    dt = time.perf_counter() - t0
    seconds = len(pcm) / 2 / engine.sample_rate

    out = Path(__file__).with_name("selftest.wav")
    with wave.open(str(out), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(engine.sample_rate)
        w.writeframes(pcm)
    print(f"Synthese {dt:.2f}s fuer {seconds:.2f}s Audio (RTF {dt / max(seconds, 1e-6):.2f}); geschrieben: {out.name}")


if __name__ == "__main__":
    main()
