#!/usr/bin/env bash
# Start the pappagei TTS sidecar on 127.0.0.1:8765
set -euo pipefail
here="$(cd "$(dirname "$0")/../backend" && pwd)"
cd "$here"
exec .venv/bin/python -m uvicorn server:app --host 127.0.0.1 --port 8765
