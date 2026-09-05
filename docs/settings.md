# Einstellungen & Defaults

## Felder — `AudioSettings`

| Feld | Typ | Default |
|---|---|---|
| `isMono` | Bool | `true` (Mono) |
| `bitrate` | String | `"48k"` |
| `sampleRate` | Int | `32000` |
| `maxDurationHours` | Int? | `nil` (unbegrenzt) |
| `useParallelEncoding` | Bool | `true` |
| `isVerbose` | Bool | `false` |
| `workerLimit` | Int? | `nil` (höchstens 4, begrenzt auf verfügbare Kerne) |

Der bewusst niedrige Default **mono / 48k / 32 kHz** ist für Sprach-Hörbücher
gewählt (kleine Dateien, praktisch unhörbar vs. hohe Qualität) — Begründung in
[encoding.md](encoding.md) + README. Der Fallback in `SettingsManager.loadSettings`
(fehlende/korrupte `settings.json`) muss denselben Wert liefern.

## Persistenz — `SettingsManager`

- Datei: `~/.Hoerbuchkloeppler/settings.json` (JSON, **nicht** `UserDefaults` —
  umgeht Binding-Bugs).
- `SettingsManager.shared.loadSettings()` / `saveSettings(_:)`; der Einstellungs-
  Ordner wird bei Bedarf angelegt.
- Beim Laden und Speichern werden ungültige Bitrate, Abtastrate und maximale
  Dauer feldweise auf ihre Defaults zurückgesetzt.
- Gültig sind Bitraten von `8k`/`8000` bis `320k`/`320000` bit/s und
  Abtastraten von 8.000 bis 48.000 Hz. Werte außerhalb dieser Grenzen erreichen
  `aac_at` nicht, sondern fallen vor dem ffmpeg-Aufruf auf den jeweiligen
  Default zurück.
- Fehlende oder falsch typisierte JSON-Felder werden ebenfalls einzeln ersetzt;
  gültige Nachbarfelder bleiben erhalten.
- `saveSettings(_:)` meldet Schreibfehler an die GUI; sie zeigt den Fehler an,
  statt einen nicht gespeicherten Wert still zu akzeptieren.

## Parallel-Mode-Regel

Parallel-Encoding ist beim App-Start **immer AN**. Lässt sich nur temporär in
einer Session abschalten und fällt beim Neustart auf AN zurück.

`workerLimit` erlaubt 1–32; ungültige gespeicherte Werte fallen auf Auto zurück.
CLI: `--workers N`. Beide Modi begrenzen auch die Zahl wartender Segmentaufträge.

## Qualitätsprofile und manuelle Werte

Sprache kompakt setzt Mono/48k/32000, Sprache detailreich Mono/96k/44100,
Musik und Hörspiel Stereo/192k/48000. Profile verändern nur diese drei Werte.
Beim anschließenden Kanalwechsel bleibt die Bitrate erhalten, auch wenn sie
nicht in der kurzen Vorschlagsliste des anderen Kanals steht.

`ConversionPreview` berechnet die Schätzung aus dem tatsächlichen Split-Plan:
WAV-Bedarf der größten gleichzeitig bearbeiteten Gruppe im Standardmodus;
AAC-Segmente im Performance-Modus. Die Zielschätzung enthält 25 Prozent
CVBR-/Containerreserve und 32 MiB Coverreserve je Ausgabe. Temp- und Zielbedarf
sind bei gemeinsamem Volume zu addieren. Freier Platz ist eine Momentaufnahme,
die Schätzung keine Garantie.

`analyzeLoudness` und `normalizeLoudness` sind Bool-Werte mit Default `false`.
Die Angleichung impliziert den zusätzlichen Analysepass. Details, Zielpegel und
WAV-Speicherbedarf stehen in [encoding.md](encoding.md#optionale-buchlautheit-2026-09-05).

`importWorkerLimit` begrenzt Quellanalysen auf 1–8 (Default 4),
GUI „Quellanalysen beim Import“, CLI `--import-workers`. Der Wert reist im Projekt
und im kopierten CLI-Befehl mit.
