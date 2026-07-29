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
- Fehlende oder falsch typisierte JSON-Felder werden ebenfalls einzeln ersetzt;
  gültige Nachbarfelder bleiben erhalten.
- `saveSettings(_:)` meldet Schreibfehler an die GUI; sie zeigt den Fehler an,
  statt einen nicht gespeicherten Wert still zu akzeptieren.

## Parallel-Mode-Regel

Parallel-Encoding ist beim App-Start **immer AN**. Lässt sich nur temporär in
einer Session abschalten und fällt beim Neustart auf AN zurück.
