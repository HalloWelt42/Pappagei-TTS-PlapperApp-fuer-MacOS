# pappagei TTS API

Lokale HTTP-Schnittstelle des pappagei-Backends. Sie wird von der App selbst
und von der Browser-Erweiterung genutzt und steht jedem lokalen Werkzeug
offen - etwa für Skripte, Editor-Integrationen oder Automatisierung.

- **Basis-URL:** `http://127.0.0.1:8765`
- **Erreichbarkeit:** nur auf diesem Rechner (das Backend bindet ausschließlich
  an die Loopback-Adresse). Es gibt keine Anmeldung; jede lokale Anwendung
  darf die Schnittstelle nutzen.
- **Formate:** Anfragen und Antworten als JSON (`Content-Type: application/json`),
  außer `/synthesize`, das einen Audio-Rohdaten-Stream liefert.
- **Interaktiv:** unter [`/docs`](http://127.0.0.1:8765/docs) liegt die
  eingebaute Oberfläche zum Ausprobieren, unter
  [`/openapi.json`](http://127.0.0.1:8765/openapi.json) die maschinenlesbare
  Spezifikation. Dieselbe Spezifikation liegt versioniert als
  [`docs/api.yaml`](api.yaml) im Repo; nach Schnittstellen-Änderungen mit
  `(cd backend && .venv/bin/python export_openapi.py)` neu erzeugen.

Das Backend läuft, sobald die App gestartet ist; eigenständig startet es
`scripts/run_backend.sh`.

## Überblick

| Methode | Pfad | Zweck |
|---|---|---|
| GET | `/health` | Zustand von Dienst und Modell |
| POST | `/warmup` | Modell laden und aufwärmen |
| GET | `/voices` | Sprecher und eigene Stimmen auflisten |
| POST | `/voices/import` | Eigene Stimme aus Aufnahme anlegen |
| DELETE | `/voices/{vid}` | Eigene Stimme löschen |
| POST | `/model/switch` | TTS-Modell wechseln |
| POST | `/synthesize` | Text in Audio umwandeln (Stream) |
| POST | `/speak` | Text von der App vorlesen lassen |
| POST | `/speak/stop` | Wiedergabe der App stoppen |
| GET | `/speak/next` | Kommando abholen (intern, Long-Poll) |

## Status

### GET /health

Antwortet sofort, auch während Synthese oder Modell-Download.

```bash
curl -s http://127.0.0.1:8765/health
```

```json
{
  "status": "ok",
  "model": "0.6b",
  "loaded": true,
  "loading": false,
  "download_bytes": null,
  "sample_rate": 24000
}
```

- `loaded`: das Modell ist sprechbereit.
- `loading`: ein Modell lädt gerade (oder lädt herunter). Solange es true ist,
  zeigt `download_bytes` die im Cache liegende Datenmenge; wächst der Wert
  zwischen zwei Abfragen, läuft ein Download.

### POST /warmup

Lädt das aktive Modell (falls nötig) und spricht einen kurzen Probelauf.
Blockiert, bis das Modell bereit ist - beim allerersten Aufruf inklusive
Download. Antwort: `{"warmup_seconds": 1.93, "sample_rate": 24000}`.

## Stimmen

### GET /voices

```bash
curl -s http://127.0.0.1:8765/voices
```

```json
{
  "model": "0.6b",
  "speakers": ["Chelsie", "Ethan", "Vivian"],
  "custom": [
    {
      "id": "9f7305e1",
      "name": "Meine Stimme",
      "ref_audio": "/Users/.../pappagei/voices/9f7305e1.wav",
      "ref_text": null,
      "speaker": "Chelsie"
    }
  ]
}
```

Eingebaute Sprecher werden in `/synthesize` über ihren Namen angesprochen,
eigene Stimmen über `id` oder `name`.

### POST /voices/import

Klont eine Stimme aus einer Referenz-Aufnahme (WAV oder mp3, etwa 5 bis 10
Sekunden, ein Sprecher, wenig Störgeräusch). Ein Transkript ist nicht nötig.
Die Aufnahme wird kopiert und dauerhaft hinterlegt.

```bash
curl -s -X POST http://127.0.0.1:8765/voices/import \
  -H 'Content-Type: application/json' \
  -d '{"name": "Meine Stimme", "audio_path": "/Users/ich/aufnahme.wav"}'
```

Antwort: das angelegte Stimmen-Objekt (siehe oben), inklusive vergebener `id`.

### DELETE /voices/{vid}

Entfernt die Stimme samt hinterlegter Aufnahme. `404`, wenn es die Id nicht
gibt. Antwort: `{"deleted": "9f7305e1"}`.

## Modelle

### POST /model/switch

Wechselt zwischen `0.6b` (schnell, Standard) und `1.7b` (höhere Qualität).
Der Modell-Schlüssel kommt als Query-Parameter. Blockiert, bis das Modell
bereit ist; beim ersten Wechsel auf ein noch nicht heruntergeladenes Modell
entsprechend lange (Fortschritt über `GET /health` beobachtbar).

```bash
curl -s -X POST 'http://127.0.0.1:8765/model/switch?model=1.7b'
```

Antwort: `{"model": "1.7b"}` - `400` bei unbekanntem Schlüssel.

## Synthese

### POST /synthesize

Wandelt Text in Audio um und **streamt** die Rohdaten, noch während das
Modell erzeugt: erste Bytes kommen nach unter einer Sekunde, nicht erst am
Ende.

Body (nur `text` ist Pflicht):

| Feld | Typ | Bedeutung |
|---|---|---|
| `text` | string | Der zu sprechende Text. |
| `voice` | string | Sprecher-Name oder Id/Name einer eigenen Stimme. |
| `model` | string | `0.6b` oder `1.7b`; lädt bei Bedarf um. |
| `speed` | number | Modellseitiger Tempo-Faktor; wirkt praktisch kaum. |
| `temperature` | number | Sampling-Temperatur (etwa 0.3 bis 1.0). |
| `repetition_penalty` | number | Wiederholungs-Strafe (etwa 1.0 bis 1.3). |

**Audio-Format der Antwort:** PCM, 16 Bit signed little-endian, mono,
Abtastrate laut `/health` (Standard 24000 Hz); `Content-Type:
audio/L16; rate=24000; channels=1`. Es gibt keinen Datei-Kopf - zum
Weiterverarbeiten Abtastrate und Format selbst angeben:

```bash
curl -s -X POST http://127.0.0.1:8765/synthesize \
  -H 'Content-Type: application/json' \
  -d '{"text": "Hallo, das ist ein Test.", "voice": "Chelsie"}' \
  | ffmpeg -loglevel error -f s16le -ar 24000 -ac 1 -i - hallo.wav
```

Fehler: `400` bei leerem Text oder unbekanntem Modell-Schlüssel (kommt vor
dem Stream, nie mittendrin). Bricht der Client die Verbindung ab, stoppt
die Erzeugung serverseitig kurz darauf.

Hinweis: Es läuft genau eine Synthese gleichzeitig (das Modell ist an einen
Thread gebunden); parallele Aufrufe werden nacheinander bedient.

## Vorlese-Brücke

Über die Brücke lassen lokale Werkzeuge (etwa die Browser-Erweiterung) die
**App** sprechen - mit der dort gewählten Stimme, dem eingestellten Tempo,
satzweise gestreamt und über Menü wie Hotkeys steuerbar. Wer rohes Audio
selbst verarbeiten will, nutzt stattdessen `/synthesize`.

### POST /speak

```bash
curl -s -X POST http://127.0.0.1:8765/speak \
  -H 'Content-Type: application/json' \
  -d '{"text": "Diesen Absatz bitte vorlesen."}'
```

Antwort: `{"queued": true}`. Der neueste Auftrag gewinnt: ein weiterer
Aufruf ersetzt einen noch nicht abgeholten Auftrag, und sobald die App ihn
übernimmt, unterbricht er eine laufende Wiedergabe. `400` bei leerem Text,
`413` ab 50000 Zeichen.

Läuft die App nicht (nur das Backend), wird der Auftrag nicht gesprochen -
er wartet, bis eine App ihn abholt, oder wird vom nächsten ersetzt.

### POST /speak/stop

Verwirft wartende Aufträge und stoppt die laufende Wiedergabe der App.
Antwort: `{"queued": true}`.

### GET /speak/next

Long-Poll-Gegenstück für die App; eigene Werkzeuge brauchen es nicht. Hängt
bis zu `timeout` Sekunden (Standard 25, Maximum 60) und liefert dann das
nächste Kommando oder `{"action": "none"}`:

```json
{"action": "speak", "text": "Diesen Absatz bitte vorlesen."}
{"action": "stop", "text": null}
{"action": "none", "text": null}
```

Da genau eine App-Instanz abholt, ist die Warteschlange bewusst flach
gehalten (neuester Auftrag gewinnt).

## Fehlerformat

Fehler kommen als JSON im FastAPI-Format:

```json
{"detail": "unknown model 'xl'; choose ['0.6b', '1.7b']"}
```

Validierungsfehler (falscher Body-Aufbau) liefern `422` mit einer
Detail-Liste je Feld.
