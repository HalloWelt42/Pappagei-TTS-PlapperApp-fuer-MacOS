"""Schreibt die OpenAPI-Spezifikation der API als YAML nach docs/api.yaml.

Aufruf:  (cd backend && .venv/bin/python export_openapi.py)
Nach Schnittstellen-Änderungen in server.py erneut ausführen, damit die
eingecheckte Spezifikation aktuell bleibt.
"""
from __future__ import annotations

from pathlib import Path

import yaml

from server import app


def main() -> None:
    spec = app.openapi()
    out = Path(__file__).resolve().parent.parent / "docs" / "api.yaml"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        yaml.safe_dump(spec, allow_unicode=True, sort_keys=False, width=100),
        encoding="utf-8",
    )
    print(f"geschrieben: {out} ({out.stat().st_size} Bytes)")


if __name__ == "__main__":
    main()
