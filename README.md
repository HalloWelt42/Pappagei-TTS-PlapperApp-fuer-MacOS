# pappagei

Natives macOS-Vorlese-Tool: markierten Text aus beliebigen Apps vorlesen, lokal
auf Apple Silicon, mit eigener geklonter Stimme. Engine: Qwen3-TTS via mlx-audio.

## Aufbau

- `backend/` — lokaler TTS-Sidecar (Python, FastAPI). Lädt Qwen3-TTS über
  mlx-audio, hält das Modell resident, streamt PCM.
  - `tts_engine.py` — Modell-Wrapper (laden, aufwärmen, Cloning, Streaming)
  - `voices.py` — Verwaltung eigener Stimmen (Referenz-Clip plus Transkript)
  - `server.py` — FastAPI: /synthesize, /voices, /model/switch, /warmup, /health
  - `poc.py` — Machbarkeitstest plus Latenzmessung
- `Sources/pappagei/` — native Swift-App (Menüleiste): Textgriff, Hotkey, Audio, Stimmen-UI.
- `scripts/` — Hilfsskripte (Backend starten, App-Bundle bauen).

## Voraussetzungen

- Apple Silicon, macOS 14+, Swift 6.2 (getestet auf M2 / 8 GB / macOS 26).
  Funktioniert mit den Command Line Tools, volles Xcode ist optional.
- Daraus:
  - **Standardmodell: Qwen3-TTS 1.7B CustomVoice (8-bit)** zum Klonen;
    0.6B CustomVoice (4-bit) als schnelle Ausweichstufe. Umschaltbar im Menü.
  - Die App wird als **SwiftPM-Paket** gebaut (`swift build`); das `.app`-Bundle
    wird per Skript zusammengesetzt. Volles Xcode ist optional.

## Backend einrichten und testen

```bash
cd backend
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
# Machbarkeit plus Latenz (lädt das 0.6B-Modell beim ersten Lauf herunter):
.venv/bin/python poc.py
# Mit eigener Stimme (Referenz ~5-7s, klar gesprochen, ein Sprecher):
.venv/bin/python poc.py /pfad/zu/stimme.wav "Transkript des Clips"
```

Sidecar starten:

```bash
scripts/run_backend.sh
# Gesundheitscheck:
curl -s http://127.0.0.1:8765/health
```

## App bauen und benutzen

```bash
# .app-Bundle bauen (kein Xcode nötig):
scripts/make_app.sh debug
# Starten (Menüleisten-Symbol erscheint oben rechts):
open pappagei.app
```

Beim ersten Start:
1. Systemeinstellungen, Datenschutz & Sicherheit, Bedienungshilfen: pappagei
   aktivieren (nötig fürs Lesen der Markierung und den Cmd+C-Fallback). Im Menü
   gibt es dafür den Knopf "Berechtigung erteilen".
2. Text markieren und Ctrl+Shift+R drücken, oder im Menü "Auswahl vorlesen".

Hinweis: Der unsignierte Dev-Build erhält bei jedem Neubau eine neue Identität,
daher muss die Bedienungshilfen-Freigabe nach einem Rebuild ggf. erneut gesetzt
werden.

## Status (validiert)

- Backend: Cloning (CustomVoice), 24 kHz, Streaming. Auf M2/8 GB echtzeitfähig:
  1.7B-clone 8-bit (Standard) RTF ~0.87 (erster Ton ~0.6s), 0.6B-clone 4-bit
  RTF ~0.55. FastAPI-Endpunkte grün.
- Referenz-Audio: WAV und mp3 funktionieren (mp3 via ffmpeg/miniaudio).
- App: baut, startet als Menüleisten-Agent, fährt den Sidecar hoch, Modell lädt
  (~1-2s warm aus Cache; 1.7B 8-bit einmalig ~1.8 GB Download). Stimmen-Import-UI,
  reaktive Berechtigungsprüfung, klarere Fehlermeldungen.
- Beobachtung: mit schwacher/synthetischer Referenz und sehr kurzen Einzelsätzen
  teils zu lange Ausgabe (mögliche Wiederholung); mit sauberer 5-7s-Referenz und
  Absätzen normal. Bei Bedarf temperature/repetition_penalty justierbar.
- Tuning: Defaults temp 0.7 / rep 1.1 (validiert, ~20% kürzer als Modell-Standard);
  im Menü unter "Erweitert" sowie pro Anfrage (temperature, repetition_penalty) justierbar.
- Offen (Hands-on): Bedienungshilfen-Freigabe, Textgriff real, Audio hören.
- Später: Wort-Highlighting, echte Download-Fortschrittsanzeige, Notarisierung.
