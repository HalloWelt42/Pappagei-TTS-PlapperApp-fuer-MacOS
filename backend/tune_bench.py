"""Tune sampling to curb over-generation (audio much longer than the text).

For a representative German paragraph, synthesize at several
(temperature, repetition_penalty) settings and report the audio duration versus
a rough expected duration (German ~2.5 words/s). A ratio near 1.0-1.4 is healthy;
much larger means the model is rambling/repeating.
"""
from __future__ import annotations

import re
from pathlib import Path

from tts_engine import Engine, Voice

HERE = Path(__file__).parent
REF = HERE / "ref_synth.wav"
REF_TXT = "Dies ist meine Referenzstimme fuer den Klontest mit pappagei."

TEXT = (
    "pappagei liest markierten Text laut vor. "
    "Die Sprachausgabe laeuft vollstaendig lokal auf dem Mac. "
    "Du kannst jederzeit pausieren oder stoppen."
)

COMBOS = [(0.9, 1.05), (0.7, 1.10), (0.6, 1.15), (0.5, 1.20)]


def audio_seconds(engine: Engine, voice: Voice) -> float:
    n = 0
    for chunk in engine.synthesize_pcm16(TEXT, voice):
        n += len(chunk)
    return n / 2 / engine.sample_rate


def main() -> None:
    words = len(re.findall(r"\w+", TEXT))
    expected = words / 2.5
    print(f"text: {words} words, expected ~{expected:.1f}s of speech\n")

    engine = Engine(model_key="0.6b-clone")
    engine.load()

    voices = [("no-ref", Voice("x", speaker="serena"))]
    if REF.exists():
        voices.append(("synth-ref", Voice("x", speaker="serena", ref_audio=str(REF), ref_text=REF_TXT)))

    for label, voice in voices:
        print(f"--- {label} ---")
        for temp, rep in COMBOS:
            engine.temperature = temp
            engine.repetition_penalty = rep
            secs = audio_seconds(engine, voice)
            print(f"  temp {temp:.2f}  rep {rep:.2f}  ->  {secs:5.1f}s  ratio {secs / expected:.2f}")
        print()


if __name__ == "__main__":
    main()
