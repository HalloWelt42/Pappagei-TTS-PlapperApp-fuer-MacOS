"""Steady-state benchmark for pappagei on this machine.

Measures (model already cached):
  - cached load time
  - time-to-first-audio (TTFA) with sentence streaming  <- key UX metric
  - overall real-time factor (RTF) over a realistic paragraph
Also lists available mlx-community Qwen3-TTS variants (to find a faster quant).
"""
from __future__ import annotations

import time

from tts_engine import DEFAULT_VOICE, Engine, Voice, split_sentences

PARA = (
    "Guten Morgen! pappagei liest markierten Text laut vor. "
    "Die Sprachausgabe laeuft vollstaendig lokal auf dem Mac. "
    "Du kannst jederzeit pausieren, fortsetzen oder stoppen. "
    "Lange Texte werden Satz fuer Satz erzeugt, damit der erste Ton frueh kommt."
)


def list_variants() -> None:
    try:
        from huggingface_hub import HfApi

        ids = [m.id for m in HfApi().list_models(search="Qwen3-TTS", author="mlx-community")]
        print("mlx-community Qwen3-TTS variants:")
        for i in sorted(ids):
            print("  -", i)
    except Exception as exc:  # noqa: BLE001
        print("variant listing failed:", exc)


def main() -> None:
    eng = Engine(model_key="0.6b")
    t0 = time.perf_counter()
    eng.load()
    print(f"cached load: {time.perf_counter() - t0:.1f}s; sample_rate={eng.sample_rate}")

    voice = Voice(DEFAULT_VOICE, speaker=DEFAULT_VOICE)
    wt = eng.warmup(voice)
    print(f"warmup: {wt:.2f}s")
    print(f"paragraph has {len(split_sentences(PARA))} sentences\n")

    for it in range(3):
        t0 = time.perf_counter()
        first = None
        nbytes = 0
        for chunk in eng.synthesize_pcm16(PARA, voice):
            if first is None:
                first = time.perf_counter() - t0
            nbytes += len(chunk)
        total = time.perf_counter() - t0
        secs = nbytes / 2 / eng.sample_rate
        print(
            f"iter {it}: TTFA {first:.2f}s -- total {total:.2f}s synth "
            f"for {secs:.2f}s audio -- RTF {total / max(secs, 1e-6):.2f}"
        )

    print()
    list_variants()


if __name__ == "__main__":
    main()
