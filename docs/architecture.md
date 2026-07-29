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
- **Swift-6-Isolation:** `ConversionSession` gehört vollständig zum Main Actor;
  nur dort wird `@Published`-State gelesen oder geändert. Der blockierende
  ffmpeg-Worker erhält dafür einen unveränderlichen `ConversionJob`-Snapshot und
  meldet Logs/Fortschritt über gezielte Main-Actor-Nachrichten zurück.
- **Asynchrone Audioanalyse:** Dauer, Metadaten, Tag-Werte und Artwork werden über
  `AVAsset.load(...)` beziehungsweise `AVMetadataItem.load(...)` geladen. GUI
  und CLI erwarten denselben asynchronen Import-Lebenszyklus; die frühere
  `metadataGroup: DispatchGroup`-Sonderbehandlung der CLI entfällt.
- Laufbezogene Abbrüche bleiben synchron erreichbar: kleine, sperrengeschützte
  Koordinatoren besitzen die Vorbereitungs- und Konvertierungsprozesse, damit
  SIGINT abbrechen kann, ohne die Main-Actor-Isolation zu umgehen.
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
| `FFmpegWrapper.swift` | Zentraler Ausgabeplan, unveränderlicher Worker-Snapshot, atomare Partial→Ziel-Übernahme, Prozessausführung, Concat/Muxing, laufbezogene Cancellation | `ConversionJob` · `makeConversionPlan` · `convert(session:plan:)` · `commitStagedOutput` · `performSequentialConversion` · `performParallelConversion` · `runFinalProcess` · `splitAudioFilesIfNeeded` |
| `CLIInvocation.swift` | Vollständiger, POSIX-shell-sicherer GUI→CLI-Handoff | `CLIInvocation.arguments` · `shellCommand` |
| `ConversionSession.swift` | Main-Actor-isolierter Lebenszyklus und `@Published`-State, asynchroner Import, Worker→UI-Nachrichten | `addLog` · `fetchRawMediaInfo` · `processIncomingFiles` · `importGlobalMetadata` · `scanFolder` · `addFolder` · `selectCover` |
| `AudioSettings.swift` | Einstellungs-Struct (`Codable`) | Felder → [settings.md](settings.md) |
| `SettingsManager.swift` | Laden/Speichern `~/.Hoerbuchkloeppler/settings.json` | `shared` · `loadSettings` · `saveSettings` |
| `AudioFile+Extensions.swift` | Asynchrone AVFoundation-Artwork-Analyse, Kapitel-Extraktion via **gebündeltem ffmpeg** (`-f ffmetadata`) | `extractEmbeddedArtwork` · `extractChapters` · `parseFFMetadataChapters` |
| `KloepplerCLI.swift` | AsyncParsableCommand-CLI: erwarteter Import, TTY-abhängige ANSI-Animation, Klartextstatus in Pipes, SIGINT-Phasen, ASCII-Cover — Optionen siehe [build-and-test.md](build-and-test.md) | `KloepplerCLI` (`@main`) · `execute(_:)` · `validate()` · `sanitizeFilename` · `buildPacmanBar` · `generateAsciiArt` |

App-Views (`Hörbuchklöppler/`): `ContentView`, `ConversionOverlayView`,
`MetadataSelectionView`, `SettingsView`, `Hörbuchklöppler.swift` (App-Entry).
