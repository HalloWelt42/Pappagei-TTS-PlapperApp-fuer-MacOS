#!/usr/bin/env bash
# pappagei — One-shot installer for macOS (Apple Silicon).
#
#   ./install.sh             full setup including the ~1.2 GB model download
#   ./install.sh --no-model  skip the model download (loads on first start)
#
# Idempotent: safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
SKIP_MODEL="${1:-}"

step() { printf "\n==> %s\n" "$1"; }
fail() { printf "\nFEHLER: %s\n" "$1" >&2; exit 1; }

step "1/5  Voraussetzungen prüfen"
[ "$(uname -m)" = "arm64" ] || fail "Benötigt Apple Silicon (arm64)."
command -v swift >/dev/null 2>&1 || fail "Swift fehlt. Command Line Tools installieren:  xcode-select --install"
command -v python3 >/dev/null 2>&1 || fail "python3 fehlt. Z.B.:  brew install python"
python3 -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3, 10) else 1)' \
    || fail "python3 zu alt (brauche 3.10+). Z.B.:  brew install python@3.12"
SWIFTV="$(swift --version 2>&1)"; SWIFTV="${SWIFTV%%$'\n'*}"
echo "OK: $(uname -m), ${SWIFTV}, $(python3 --version 2>&1)"
if command -v ffmpeg >/dev/null 2>&1; then
    echo "ffmpeg: vorhanden (mp3-Stimmproben möglich)"
else
    echo "Hinweis: ffmpeg fehlt - für mp3-Referenzen optional 'brew install ffmpeg' (WAV geht immer)."
fi

step "2/5  Python-Umgebung anlegen (backend/.venv)"
# A venv breaks silently after a machine migration or a Homebrew Python
# update (dangling symlink, wrong arch, half-installed packages) -- detect
# that and rebuild instead of failing later with a confusing error.
venv_broken() {
    local py="backend/.venv/bin/python"
    [ -x "$py" ] || return 0
    "$py" -c 'import sys' >/dev/null 2>&1 || return 0
    "$py" -c 'import mlx_audio, fastapi, uvicorn' >/dev/null 2>&1 || return 0
    return 1
}
if [ -d backend/.venv ]; then
    echo "prüfe vorhandene Python-Umgebung (kann einige Sekunden dauern) ..."
    if venv_broken; then
        echo "Python-Umgebung defekt (z. B. nach Rechnerwechsel oder Python-Update) - wird neu erstellt."
        rm -rf backend/.venv
    else
        echo "Python-Umgebung in Ordnung."
    fi
fi
python3 -m venv backend/.venv
backend/.venv/bin/python -m pip install --quiet --upgrade pip
backend/.venv/bin/pip install -r backend/requirements.txt
backend/.venv/bin/python -c 'import mlx_audio, fastapi, uvicorn' >/dev/null 2>&1 \
    || fail "Python-Umgebung konnte nicht eingerichtet werden (siehe Meldungen oben)."

step "3/5  Sprachmodell vorbereiten (Base 0.6B, ~1.2 GB)"
if [ "$SKIP_MODEL" = "--no-model" ]; then
    echo "übersprungen (--no-model) - wird beim ersten Start automatisch geladen."
else
    ( cd backend && TOKENIZERS_PARALLELISM=false .venv/bin/python -c \
        "from tts_engine import Engine; e=Engine(); e.load(); print('Modell bereit:', e.model_key)" )
fi

step "4/5  App bauen und nach /Applications installieren"
./scripts/make_app.sh release

step "5/5  Fertig"
cat <<EOF

pappagei ist eingerichtet.

  Starten:   open /Applications/pappagei.app
  Benutzen:  Menüleisten-Symbol (Vogel) anklicken,
             "Aus Zwischenablage vorlesen" einschalten,
             dann irgendwo Text kopieren (Cmd+C) - wird vorgelesen.
             Hotkeys: Ctrl+Shift+R vorlesen/stoppen, Ctrl+Shift+P Pause.

  Selbsttest (optional):  (cd backend && .venv/bin/python selftest.py)

Stimme, Modell und Tempo im Menü. Eigene Stimme über "Stimme verwalten".
EOF
