"""Diagnostic: does MLX run safely if pinned to ONE dedicated worker thread?

The FastAPI smoke test crashed because MLX inference ran in a pool thread (and
the model may load in one thread but be called from another). Here we load AND
generate (twice) inside a single-worker executor. If this succeeds, the server
can use the same pattern; if it crashes, MLX needs the main thread instead.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor

from tts_engine import Engine, Voice

pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="tts")
engine = Engine(model_key="0.6b-clone")
voice = Voice("x", speaker="serena")


def _load() -> str:
    engine.load()
    return f"loaded {engine.model_key}"


def _synth() -> int:
    return len(b"".join(engine.synthesize_pcm16("Hallo, dies ist ein Thread-Test.", voice)))


print(pool.submit(_load).result())
print("synth 1 bytes:", pool.submit(_synth).result())
print("synth 2 bytes:", pool.submit(_synth).result())
print("OK: MLX is stable when pinned to one worker thread")
pool.shutdown(wait=True)
