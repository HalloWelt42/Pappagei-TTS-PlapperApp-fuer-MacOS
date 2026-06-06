"""In-process test of the voice import + clone-synthesis path the UI uses.

Imports the existing ref_synth.wav as a custom voice, synthesizes with it,
then deletes it again (cleanup).
"""
from __future__ import annotations

from pathlib import Path

from starlette.testclient import TestClient

import server

client = TestClient(server.app)

ref = Path("ref_synth.wav").resolve()
assert ref.exists(), "run clone_test.py first to create ref_synth.wav"

imported = client.post("/voices/import", json={
    "name": "TestStimme",
    "audio_path": str(ref),
    "transcript": "Dies ist meine Referenzstimme fuer den Klontest mit pappagei.",
    "speaker": "serena",
}).json()
print("import:", imported)

listing = client.get("/voices").json()
print("voices.custom:", listing["custom"])

vid = imported["id"]
resp = client.post("/synthesize", json={"text": "Mit meiner eigenen Stimme vorgelesen.", "voice": vid})
print("synthesize:", resp.status_code, len(resp.content), "bytes")

print("delete:", client.delete(f"/voices/{vid}").json())
