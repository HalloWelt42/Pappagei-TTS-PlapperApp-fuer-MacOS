"""In-process smoke test of the FastAPI sidecar (no socket/port needed).

Exercises /health, /voices, /warmup and /synthesize, then writes smoke_out.wav.
"""
from __future__ import annotations

import wave

from starlette.testclient import TestClient

import server

client = TestClient(server.app)

print("health:", client.get("/health").json())
print("voices:", client.get("/voices").json())
print("warmup:", client.post("/warmup").json())

resp = client.post(
    "/synthesize",
    json={"text": "Hallo Welt. Dies ist ein Servertest mit pappagei.", "voice": "serena",
          "temperature": 0.7, "repetition_penalty": 1.1},
)
print("synthesize:", resp.status_code, resp.headers.get("content-type"), len(resp.content), "bytes")

with wave.open("smoke_out.wav", "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(server.engine.sample_rate)
    w.writeframes(resp.content)
print(f"wrote smoke_out.wav ({len(resp.content) / 2 / server.engine.sample_rate:.2f}s)")
