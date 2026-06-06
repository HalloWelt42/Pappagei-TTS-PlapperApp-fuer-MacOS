"""Check whether the model's `speed` parameter actually changes the duration."""
from __future__ import annotations

from tts_engine import Engine, Voice

eng = Engine(model_key="0.6b-clone")
eng.temperature = 0.4   # reduce run-to-run variance so speed effect is visible
eng.load()
voice = Voice("x", speaker="serena")
text = "Dies ist ein Test der Vorlese-Geschwindigkeit mit pappagei, ein etwas laengerer Satz."

for sp in [0.7, 1.0, 1.5]:
    n = sum(len(c) for c in eng.synthesize_pcm16(text, voice, speed=sp))
    secs = n / 2 / eng.sample_rate
    print(f"speed {sp:.2f} -> {secs:.2f}s audio")
