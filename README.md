# pappagei

Natives macOS-Vorlese-Tool: kopierten oder markierten Text lokal auf Apple
Silicon vorlesen — mit eigener, geklonter Stimme. Engine: Qwen3-TTS via mlx-audio.

## Voraussetzungen

- Apple Silicon (M1/M2/M3/...), macOS 14 oder neuer.
- Command Line Tools (liefern Swift):  `xcode-select --install`
- Python 3.10+  (z.B. `brew install python`)
- Optional: `ffmpeg` für mp3-Stimmproben (`brew install ffmpeg`); WAV geht ohne.

## Installation (ein Befehl)

```bash
git clone git@github.com:HalloWelt42/Pappagei-TTS-PlapperApp-fuer-MacOS.git
cd Pappagei-TTS-PlapperApp-fuer-MacOS
./install.sh
```

`install.sh` prüft die Voraussetzungen, legt `backend/.venv` an, installiert die
Abhängigkeiten, lädt das Standardmodell (1.7B-CustomVoice-8bit, ~1.8 GB) vor und
baut `pappagei.app`. Mit `./install.sh --no-model` wird das Modell erst beim
ersten Start geladen.

Starten:

```bash
open pappagei.app
```

## Benutzung

- **Empfohlen — überall, ohne Sonderrechte:** im Menü (Vogel-Symbol oben rechts)
  „Aus Zwischenablage vorlesen" einschalten, dann irgendwo Text kopieren
  (Cmd+C oder Rechtsklick → Kopieren) — pappagei liest ihn vor. Der Knopf
  „Zwischenablage jetzt vorlesen" liest den aktuellen Inhalt sofort.
- **Alternativ — markierten Text direkt:** in Systemeinstellungen → Datenschutz &
  Sicherheit → Bedienungshilfen pappagei erlauben (Menü-Knopf „Berechtigung
  erteilen" führt hin), dann Text markieren und **Ctrl+Shift+R**. Manche Browser
  geben die Markierung nicht frei — dort den Zwischenablage-Modus nutzen.
- Im Menü: Stimme, Modell (1.7B oder 0.6B), Tempo (live, Tonhöhe bleibt), und
  unter „Erweitert" Temperatur/Wiederholung. Eigene Stimme über „Stimme
  verwalten" → WAV/mp3 (~5-7s, klar gesprochen) importieren.

## Aufbau

- `backend/` — Python-TTS-Sidecar (FastAPI + mlx-audio, Qwen3-TTS CustomVoice):
  `tts_engine.py`, `voices.py`, `server.py`, `requirements.txt`, `selftest.py`.
- `Sources/pappagei/` — native Swift-Menüleisten-App (SwiftPM-Paket).
- `scripts/` — `make_app.sh` (App-Bundle bauen), `run_backend.sh`, `make_icon.swift`.
- `install.sh` — Einrichtung in einem Schritt.

## Technik & Status

- Modelle: Qwen3-TTS **Base** — 0.6B (Standard) und 1.7B (höhere Qualität),
  im Menü umschaltbar, 24 kHz Streaming. **Voice-Cloning** aus Referenz-Audio
  über den Sprecher-Encoder des Base-Modells — **kein Transkript, kein Whisper**.
- Tempo über `AVAudioUnitTimePitch` (Tonhöhe bleibt; der Modell-Parameter `speed`
  wirkt praktisch nicht).
- Referenz-Audio: WAV und mp3 (mp3 via ffmpeg/miniaudio).
- Selbsttest:  `(cd backend && .venv/bin/python selftest.py)` → schreibt `selftest.wav`.

## Hinweise

- Der Dev-Build ist ad-hoc signiert: nach einem Neubau muss eine
  Bedienungshilfen-Freigabe ggf. neu gesetzt werden — für den Zwischenablage-Modus
  ist keine Freigabe nötig.
- Modelle, `.venv`, Build-Artefakte und erzeugte Audiodateien liegen nicht im Repo
  (siehe `.gitignore`); sie werden lokal von `install.sh` erzeugt.
