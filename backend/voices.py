"""Custom voice profiles: stored as JSON plus a copy of the reference clip.

Location:  ~/Library/Application Support/pappagei/voices/
"""
from __future__ import annotations

import json
import shutil
import uuid
from pathlib import Path
from typing import Dict, List, Optional

from tts_engine import DEFAULT_VOICE, Voice

APP_SUPPORT = Path.home() / "Library" / "Application Support" / "pappagei"
VOICES_DIR = APP_SUPPORT / "voices"
INDEX = VOICES_DIR / "index.json"

# Built-in Qwen3-TTS presets (confirmed available: Chelsie, Ethan, Vivian).
BUILTIN = ["Chelsie", "Ethan", "Vivian"]


class VoiceStore:
    def __init__(self) -> None:
        VOICES_DIR.mkdir(parents=True, exist_ok=True)
        self._index: Dict[str, dict] = self._load()

    def _load(self) -> Dict[str, dict]:
        if INDEX.exists():
            return json.loads(INDEX.read_text(encoding="utf-8"))
        return {}

    def _save(self) -> None:
        INDEX.write_text(
            json.dumps(self._index, indent=2, ensure_ascii=False), encoding="utf-8"
        )

    def list(self) -> List[dict]:
        return [{"id": vid, **meta} for vid, meta in self._index.items()]

    def import_voice(
        self,
        name: str,
        audio_path: str,
        transcript: Optional[str] = None,
        speaker: str = DEFAULT_VOICE,
    ) -> dict:
        vid = uuid.uuid4().hex[:8]
        dest = VOICES_DIR / f"{vid}{Path(audio_path).suffix.lower()}"
        shutil.copyfile(audio_path, dest)
        meta = {
            "name": name,
            "ref_audio": str(dest),
            "ref_text": transcript,
            "speaker": speaker,
        }
        self._index[vid] = meta
        self._save()
        return {"id": vid, **meta}

    def delete(self, vid: str) -> bool:
        meta = self._index.pop(vid, None)
        if not meta:
            return False
        try:
            Path(meta["ref_audio"]).unlink(missing_ok=True)
        except OSError:
            pass
        self._save()
        return True

    def resolve(self, key: Optional[str]) -> Optional[Voice]:
        """Resolve a custom voice id, a custom voice name, or a built-in preset."""
        if not key:
            return None
        if key in self._index:
            return self._to_voice(self._index[key])
        for meta in self._index.values():
            if meta["name"] == key:
                return self._to_voice(meta)
        if key in BUILTIN:
            return Voice(name=key, speaker=key)
        return None

    @staticmethod
    def _to_voice(meta: dict) -> Voice:
        return Voice(
            name=meta["name"],
            speaker=meta.get("speaker", DEFAULT_VOICE),
            ref_audio=meta["ref_audio"],
            ref_text=meta.get("ref_text"),
        )
