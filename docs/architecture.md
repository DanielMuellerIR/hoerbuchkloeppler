# Architektur

## Modul-Aufbau

- **`HoerbuchkloepplerCore/`** — Swift Package, gesamte Kernlogik; speist beide
  Frontends. Library-Target `HoerbuchkloepplerCore` + Executable-Target
  `kloeppler` (`Package.swift`).
- **`Hörbuchklöppler/`** — SwiftUI-macOS-App (dünne UI über dem Core).
- **`Hörbuchklöppler.xcodeproj`** — Xcode-Projekt der App.

Die Frontends enthalten **keine** Konvertierungslogik — die steckt komplett im
Core.

## Execution-Engine

- Externe Tools laufen über `Process()` (`FFmpegWrapper.swift`).
- ffmpeg-Aufrufe **immer mit `-nostdin`** — sonst hängt der Prozess im
  Hintergrund.
- Binär-Auflösung: Zentraler Helper `FFmpegWrapper.getBinaryURL(name:)` sucht erst im `Bundle.module`, dann in allen Pfaden der Umgebungsvariablen `$PATH` und schließlich in typischen macOS Standardordnern (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`).
- Asynchrone Synchronisation: Metadaten-Importe und Analysen sind über ein `metadataGroup: DispatchGroup` in `ConversionSession` synchronisiert, um Race Conditions in Nicht-GUI Umgebungen (wie CLI) zu verhindern.
- **App-Sandbox: AUS** — nötig, um externe Binaries auszuführen.

## UI-Pattern (App)

„Pro-Terminal"-Overlay (`ConversionOverlayView.swift`): Live-Log mit
Zeitstempeln, Copy-All, Pacman-Fortschritt (`ᗧ••••`, Variante C) über volle
Terminalbreite, Text als ein Block selektierbar. CLI-Pendant: ANSI-Cursor-
Steuerung + Pacman in `KloepplerCLI.swift`.

## Source-Map (Core)

Symbolnamen als Anker (bewusst **ohne** Zeilennummern — die driften bei jeder
Änderung; per `grep` im jeweiligen File finden).

| Datei | Zuständigkeit | Schlüssel-Symbole |
|---|---|---|
| `FFmpegWrapper.swift` | Kommando-Bau, Prozessausführung, Concat/Muxing, Cover-/Temp-Auflösung, Cancellation, Prozess-/Temp-Registry | `convert(session:outputURL:)` · `writeConcatAndChapters` · `performSequentialConversion` · `performParallelConversion` · `runFinalProcess` · `escapeFFMetadata` · `resolveCoverInputPath` · `splitAudioFilesIfNeeded` · die `getArgsFor…`-Builder |
| `ConversionSession.swift` | Konvertierungs-Lebenszyklus, `@Published`-State, Thread-sicheres Logging, Metadaten-Fetch | `addLog` · `fetchRawMediaInfo` · `processIncomingFiles` · `importGlobalMetadata` · `addFolder` · `selectCover` |
| `AudioSettings.swift` | Einstellungs-Struct (`Codable`) | Felder → [settings.md](settings.md) |
| `SettingsManager.swift` | Laden/Speichern `~/.Hoerbuchkloeppler/settings.json` | `shared` · `loadSettings` · `saveSettings` |
| `AudioFile+Extensions.swift` | Artwork-Extraktion, Kapitel-Extraktion via **gebündeltem ffmpeg** (`-f ffmetadata`) | `extractEmbeddedArtwork` · `extractChapters` · `parseFFMetadataChapters` |
| `KloepplerCLI.swift` | CLI: ArgumentParser (diverse `@Option`/`@Flag`, `validate()`), ANSI-Animation, ASCII-Cover — Optionen siehe [build-and-test.md](build-and-test.md) | `KloepplerCLI` (`@main`) · `validate()` · `sanitizeFilename` · `buildPacmanBar` · `generateAsciiArt` |

App-Views (`Hörbuchklöppler/`): `ContentView`, `ConversionOverlayView`,
`MetadataSelectionView`, `SettingsView`, `Hörbuchklöppler.swift` (App-Entry).
