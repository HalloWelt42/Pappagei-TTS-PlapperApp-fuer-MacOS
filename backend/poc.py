"""POC: prove mlx-audio + Qwen3-TTS works on this Mac, and measure latency.

Usage:
    .venv/bin/python poc.py                         # built-in voice
    .venv/bin/python poc.py ref.wav "transcript"    # test zero-shot cloning

Writes poc_out.wav next to this file. Reports model load time, cold/warm
synthesis time, and the real-time factor (RTF = synth_time / audio_seconds).
"""
from __future__ import annotations

import sys
import time
import wave
from pathlib import Path

from tts_engine import DEFAULT_VOICE, MODELS, Engine, Voice


def write_wav(path: Path, pcm16: bytes, rate: int) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm16)


def synth(engine: Engine, text: str, voice: Voice):
    t0 = time.perf_counter()
    pcm = b"".join(engine.synthesize_pcm16(text, voice))
    return pcm, time.perf_counter() - t0


def main() -> None:
    text = "Hallo! Dies ist ein Test der deutschen Sprachausgabe mit pappagei."
    model_key = "0.6b"
    print(f"loading model {model_key} -> {MODELS[model_key]} ...")

    engine = Engine(model_key=model_key)
    t0 = time.perf_counter()
    engine.load()
    print(f"  loaded in {time.perf_counter() - t0:.1f}s; sample_rate={engine.sample_rate}")

    voice = Voice(DEFAULT_VOICE, speaker=DEFAULT_VOICE)
    if len(sys.argv) > 1:
        ref_audio = sys.argv[1]
        ref_text = sys.argv[2] if len(sys.argv) > 2 else None
        voice = Voice("custom", ref_audio=ref_audio, ref_text=ref_text)
        print(f"cloning from {ref_audio} (transcript provided: {bool(ref_text)})")

    pcm, t_cold = synth(engine, text, voice)
    seconds = len(pcm) / 2 / engine.sample_rate
    out = Path(__file__).with_name("poc_out.wav")
    write_wav(out, pcm, engine.sample_rate)
    rtf_cold = t_cold / max(seconds, 1e-6)
    print(f"cold: {t_cold:.2f}s synth for {seconds:.2f}s audio (RTF {rtf_cold:.2f}); wrote {out}")

    _, t_warm = synth(engine, text, voice)
    print(f"warm: {t_warm:.2f}s synth (RTF {t_warm / max(seconds, 1e-6):.2f})")

    verdict = "REALTIME-CAPABLE" if rtf_cold < 1.0 else "slower than realtime"
    print(f"verdict on {model_key}: {verdict}")


if __name__ == "__main__":
    main()
