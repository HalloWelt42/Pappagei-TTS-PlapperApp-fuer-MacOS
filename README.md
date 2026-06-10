# pappagei

Natives macOS-Vorlese-Tool: kopierten oder markierten Text lokal auf Apple
Silicon vorlesen - mit eigener, geklonter Stimme. Engine: Qwen3-TTS via mlx-audio.

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
Abhängigkeiten, lädt das Standardmodell (Base 0.6B, ~1.2 GB) vor und
baut `pappagei.app` und installiert sie nach `/Applications`. Mit `./install.sh --no-model` wird das Modell erst beim
ersten Start geladen.

Eine defekte Python-Umgebung (etwa nach Rechnerwechsel oder Python-Update)
erkennt `install.sh` selbst und erneuert sie - bei Problemen einfach erneut
ausführen; die App zeigt in dem Fall einen entsprechenden Hinweis im Menü.

Starten:

```bash
open /Applications/pappagei.app
```

## Benutzung

- **Empfohlen - überall, ohne Sonderrechte:** im Menü (Vogel-Symbol oben rechts)
  "Aus Zwischenablage vorlesen" einschalten, dann irgendwo Text kopieren
  (Cmd+C oder Rechtsklick -> Kopieren) - pappagei liest ihn vor. Vertrauliche
  Kopien (z. B. aus Passwortmanagern) werden automatisch übersprungen. Der
  Knopf "Zwischenablage jetzt vorlesen" liest den aktuellen Inhalt sofort.
- **Hotkeys, systemweit:** **Ctrl+Shift+R** liest vor oder stoppt eine laufende
  Wiedergabe. Ohne Bedienungshilfen-Freigabe wird dabei die Zwischenablage
  gelesen, mit Freigabe der markierte Text (Systemeinstellungen -> Datenschutz
  & Sicherheit -> Bedienungshilfen; der Menü-Knopf "Berechtigung erteilen"
  führt hin). **Ctrl+Shift+P** pausiert und setzt fort. Manche Browser geben
  die Markierung nicht frei - dort den Zwischenablage-Weg nutzen.
- Im Menü: Stimme, Modell (1.7B oder 0.6B), Tempo (live, Tonhöhe bleibt), und
  unter "Erweitert" Temperatur/Wiederholung. Eigene Stimme über "Stimme
  verwalten" -> WAV/mp3 (~5-7s, klar gesprochen) importieren; dort gibt es je
  Stimme eine Hörprobe.

## Aufbau

- `backend/` - Python-TTS-Sidecar (FastAPI + mlx-audio, Qwen3-TTS Base, Cloning per Sprecher-Encoder):
  `tts_engine.py`, `voices.py`, `server.py`, `requirements.txt`, `selftest.py`.
- `Sources/pappagei/` - native Swift-Menüleisten-App (SwiftPM-Paket).
- `scripts/` - `make_app.sh` (App bauen + nach /Applications installieren), `run_backend.sh`, `make_icon.swift`.
- `install.sh` - Einrichtung in einem Schritt.

## Technik & Status

- Modelle: Qwen3-TTS **Base** - 0.6B (Standard) und 1.7B (höhere Qualität),
  im Menü umschaltbar, 24 kHz Streaming. **Voice-Cloning** aus Referenz-Audio
  über den Sprecher-Encoder des Base-Modells - **kein Transkript, kein Whisper**.
- Lange Texte werden satzweise synthetisiert und nahtlos gestreamt; das Menü
  zeigt den Fortschritt (Satz x von n). Pause und Stopp greifen während der
  gesamten Wiedergabe, ein Wechsel des Ausgabegeräts (z. B. Kopfhörer) wird
  überlebt und am Satzanfang fortgesetzt.
- Das Python-Backend wird überwacht: stirbt es, startet die App es automatisch
  neu; stirbt die App, beendet sich das Backend selbst. Beim ersten
  Modell-Download zeigt der Status die bereits geladene Datenmenge.
- Tempo über `AVAudioUnitTimePitch` (Tonhöhe bleibt; der Modell-Parameter `speed`
  wirkt praktisch nicht).
- Referenz-Audio: WAV und mp3 (mp3 via ffmpeg/miniaudio).
- Selbsttest:  `(cd backend && .venv/bin/python selftest.py)` -> schreibt `selftest.wav`.

## Hinweise

- Der Dev-Build ist ad-hoc signiert: nach einem Neubau muss eine
  Bedienungshilfen-Freigabe ggf. neu gesetzt werden - für den Zwischenablage-Modus
  ist keine Freigabe nötig.
- Modelle, `.venv`, Build-Artefakte und erzeugte Audiodateien liegen nicht im Repo
  (siehe `.gitignore`); sie werden lokal von `install.sh` erzeugt.
