"""Deeper checks requested as "weiter prüfen":
  1) Does an mp3 reference clip work for cloning (via ffmpeg/miniaudio decode)?
  2) Is the 1.7B clone model usable on this 8 GB M2 (load time, TTFA, RTF)?
"""
from __future__ import annotations

import gc
import subprocess
import time
from pathlib import Path

from tts_engine import Engine, Voice

HERE = Path(__file__).parent
REF_WAV = HERE / "ref_synth.wav"
REF_MP3 = HERE / "ref_synth.mp3"
REF_TXT = "Dies ist meine Referenzstimme fuer den Klontest mit pappagei."
SAY = "Dies ist ein tiefergehender Test der Sprachausgabe von pappagei."


def collect(engine: Engine, text: str, voice: Voice):
    t0 = time.perf_counter()
    first = None
    n = 0
    for chunk in engine.synthesize_pcm16(text, voice):
        if first is None:
            first = time.perf_counter() - t0
        n += len(chunk)
    total = time.perf_counter() - t0
    secs = n / 2 / engine.sample_rate
    return first or 0.0, total, secs


def test_mp3() -> None:
    print("=== mp3 reference test ===")
    if not REF_WAV.exists():
        print("skipped: ref_synth.wav missing (run clone_test.py first)")
        return
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(REF_WAV), str(REF_MP3)], check=True)
    print(f"mp3 created: {REF_MP3.name} ({REF_MP3.stat().st_size} bytes)")
    eng = Engine(model_key="0.6b-clone")
    eng.load()
    voice = Voice("mp3test", speaker="serena", ref_audio=str(REF_MP3), ref_text=REF_TXT)
    try:
        first, total, secs = collect(eng, SAY, voice)
        print(f"MP3 REF OK: TTFA {first:.2f}s, {secs:.2f}s audio, RTF {total / max(secs, 1e-6):.2f}")
    except Exception as exc:  # noqa: BLE001
        print("MP3 REF FAILED:", repr(exc))
    del eng
    gc.collect()


def test_17b() -> None:
    print("=== 1.7B clone test (downloads ~1.1 GB on first run) ===")
    eng = Engine(model_key="1.7b-clone")
    t0 = time.perf_counter()
    try:
        eng.load()
    except Exception as exc:  # noqa: BLE001
        print("1.7B load FAILED:", repr(exc))
        return
    print(f"1.7b-clone loaded in {time.perf_counter() - t0:.1f}s")
    eng.warmup(Voice("w", speaker="serena"))
    first, total, secs = collect(
        eng, "Hallo, dies ist das groessere Modell mit eins Komma sieben Milliarden Parametern.",
        Voice("x", speaker="serena"),
    )
    print(f"1.7b-clone: TTFA {first:.2f}s, {secs:.2f}s audio, RTF {total / max(secs, 1e-6):.2f}")
    del eng
    gc.collect()


if __name__ == "__main__":
    test_mp3()
    test_17b()
