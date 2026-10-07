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

- Externe Tools laufen über `Process()` (`ProcessTermination.swift`).
- ffmpeg-Aufrufe **immer mit `-nostdin`** — sonst hängt der Prozess im
  Hintergrund.
- Binär-Auflösung: Zentraler Helper `FFmpegWrapper.getBinaryURL(name:)` sucht erst im `Bundle.module`, dann in allen Pfaden der Umgebungsvariablen `$PATH` und schließlich in typischen macOS Standardordnern (`/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`).
- **Swift-6-Isolation:** `ConversionSession` gehört vollständig zum Main Actor;
  nur dort wird `@Published`-State gelesen oder geändert. Der blockierende
  ffmpeg-Worker erhält dafür einen unveränderlichen `ConversionJob`-Snapshot und
  meldet Logs, Fortschritt, Abbruch und Abschluss über einen einzigen
  `AsyncStream` zurück. Ein Main-Actor-Task verarbeitet dessen Ereignisse
  seriell und verwirft sie, wenn ihre Lauf-ID nicht mehr aktuell ist. Der
  `ConversionContext` hält den Abschluss bis zum Ende einer bereits laufenden
  Abbruchbereinigung zurück, damit deren Warnungen nicht hinter dem Abschluss
  verloren gehen.
- **Asynchrone Audioanalyse:** Dauer, Metadaten und Tag-Werte werden über
  `AVAsset.load(...)` beziehungsweise `AVMetadataItem.load(...)` geladen. Cover
  kommen unverändert über eine auf 32 MiB begrenzte ffmpeg-Pipe; ein ImageIO-
  Thumbnail begrenzt die Vorschau auf 2.000 Pixel pro Achse. GUI
  und CLI erwarten denselben asynchronen Import-Lebenszyklus; die frühere
  `metadataGroup: DispatchGroup`-Sonderbehandlung der CLI entfällt. Kapitel-
  Prozesse, Pipe-Lesen, Parsing und Kapitelaufbau laufen auf einer eigenen
  parallelen Utility-Queue. Die Import-Workergrenze bleibt erhalten; ein
  gesperrter Abbruchzustand übergibt Task-Cancellation an diese Queue. Ein
  Import-Batch bleibt bis zum Ende aller Provider-Ladevorgänge und Analysen im
  Staging. Liefert ein GUI-Provider keine Datei-URL, fehlt bei einer Quelle Dauer
  oder Audio-Stream oder läuft ihre Kapitelanalyse ins Zeitlimit, verwerfen GUI
  und CLI den ganzen Batch statt ein unvollständiges Hörbuch zu erzeugen. Ein
  verworfener Zusatz-Drop lässt die bestehende CLI-Ordnerbindung unverändert.
  Eine zuvor laufende Artwork-Suche für den sichtbaren Bestand läuft nach dem
  Drop wieder an — auch dann, wenn er erfolgreich verbucht wurde, aber selbst
  weder ein Cover mitbrachte noch eine eigene Suche startete (übersprungene
  Nicht-Audiodatei, Ordner ohne verwertbares Cover).
- **Quellpfad und Lese-URL:** `FoundFile.source` ist der sichtbare Pfad, der
  Anzeige, Sortierung und Fallback-Kapiteltitel bestimmt. `FoundFile.resolved`
  ist das aufgelöste reguläre Ziel, das AVFoundation, ffmpeg, mediainfo und die
  Größenermittlung öffnen. `AudioFile.sourceURL` und `AudioFile.url` bewahren
  diese Trennung. Gewöhnliche Dateien tragen zweimal denselben Pfad;
  Dateisymlinks behalten ihren Linknamen, Verzeichnissymlinks werden nicht
  verfolgt. Ordner- und Einzeldatei-Import benutzen dieselbe `FoundFile`-Logik.
- Der Ordnerscan dedupliziert nach der aufgelösten Lese-URL. Liegen ein Symlink
  und sein Ziel nebeneinander, gewinnt der bewusst benannte Symlink; der Scan
  protokolliert das verworfene Duplikat. Die Sortierung vergleicht danach den
  gesamten sichtbaren Pfad komponentenweise, bevor Kapitel derselben Datei über
  ihre Startzeit geordnet werden.
- Laufbezogene Abbrüche bleiben synchron erreichbar: kleine, sperrengeschützte
  Koordinatoren besitzen den Swift-Vorbereitungstask sowie die Vorbereitungs-
  und Konvertierungsprozesse. Dadurch kann SIGINT abbrechen, ohne die
  Main-Actor-Isolation zu umgehen. Externe Werkzeuge laufen in einer besessenen
  Prozessgruppe; Abbruch und begrenzter Pipe-Join beenden auch Nachkommen zuerst
  mit SIGTERM und nach 0,5 Sekunden mit SIGKILL. Auch ein Exit 0 des direkten
  Wrappers gilt nicht als Erfolg, solange in seiner besessenen Prozessgruppe ein
  Hintergrundprozess weiterläuft. Der Konvertierungs-Context entfernt temporäre
  und unvollständige Dateien erst danach.
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
| `ConversionPlan.swift` | Gemeinsamer Split-/Zielplan und Quell-/Ziel-Snapshot-Validierung | `ConversionPlan` · `makeConversionPlan` · `validateConversionPlan` · `splitAudioFilesIfNeeded` |
| `FFmpegWrapper.swift` | Kodierpipeline und Laufsteuerung: Ausgabeplan, laufbezogener Besitz von Prozessen und Zwischendateien, Segment- und Muxing-Schritte | `ConversionContext` · `ConversionJob` · `convert(session:plan:)` · `performSequentialConversion` · `performParallelConversion` · `runFinalProcess` |
| `ProcessTermination.swift` | Prozess-Lebenszyklus: Werkzeugprozesse starten, ihre Ausgabe lesen, zweistufig (TERM→KILL) samt Prozessgruppe beenden, Tool-Auflösung | `ProcessTerminator` · `wait(upTo:while:)` · `terminateAndWait` · `ToolProcessContext` · `ProcessPipeReader` · `getBinaryURL` · `runCapturedProcess` |
| `OutputStaging.swift` | Dateisystem-Sicherheitsgrenze: Eintrag über Gerät und Inode wiedererkennen, exklusiv anlegen, prozessübergreifend sperren, atomar ins Ziel tauschen, nur nachweislich Eigenes bereinigen | `FileSystemIdentity` · `StagingOwnership` · `OutputLeaseSet` · `acquireOutputLeases` · `createProtectedStagingOutput` · `commitStagedOutput` · `removeOrphanedStagedOutputs` · `removeOwnedTempDirectory` |
| `CLIInvocation.swift` | Vollständiger, POSIX-shell-sicherer GUI→CLI-Handoff | `CLIInvocation.arguments` · `shellCommand` |
| `ConversionSession.swift` | Main-Actor-isolierter Lebenszyklus und `@Published`-State, gemeinsame Pfad-/Symlink-Auflösung, atomarer und abbrechbarer asynchroner Import, Worker→UI-Nachrichten | `FoundFile` · `AudioLoadResult` · `beginImport` · `finishImport` · `foundFile(at:)` · `deduplicateFoundFiles` · `loadAudioFiles` · `processIncomingFiles` · `scanFolder` · `prepareFolder` · `addFolder` · `addLog` |
| `CoverArtwork.swift` | ImageIO-Validierung und Thumbnail-Vorschau ohne vorherigen NSImage-Voll-Decode | `thumbnail` · `preview` |
| `AudioSettings.swift` | Einstellungs-Struct (`Codable`) | Felder → [settings.md](settings.md) |
| `SettingsManager.swift` | Laden/Speichern `~/.Hoerbuchkloeppler/settings.json` | `shared` · `loadSettings` · `saveSettings` |
| `AudioFile+Extensions.swift` | Begrenzte ffmpeg-Artwork-Extraktion; Kapitel-Extraktion via **gebündeltem ffmpeg** (`-f ffmetadata`) auf eigener Utility-Queue mit Task-/Importabbruch | `extractEmbeddedArtwork` · `extractChapters` · `parseFFMetadataChapters` |
| `KloepplerCLI.swift` | AsyncParsableCommand-CLI: erwarteter Import, TTY-abhängige ANSI-Animation, Klartextstatus in Pipes, SIGINT-Phasen, ASCII-Cover — Optionen siehe [build-and-test.md](build-and-test.md) | `KloepplerCLI` (`@main`) · `execute(_:)` · `validate()` · `resolveOutputFile` · `sanitizeFilename` · `buildPacmanBar` · `generateAsciiArt` |
| `TerminalRenderer.swift` | Physische Statuszeilen, Unicode-Anzeigebreite und sichere Neuzeichnung bei Terminal-Größenwechseln | `TerminalRenderer` · `TerminalGeometry` |

App-Views (`Hörbuchklöppler/`): `ContentView`, `ConversionOverlayView`
(mit `LogTranscriptView`), `MetadataSelectionView`, `SettingsView`,
`ErrorAlert.swift` (gemeinsamer `View.errorAlert`-Modifier),
`Hörbuchklöppler.swift` (App-Entry).

Belegte, noch nicht beauftragte Produkt- und Performance-Ansätze stehen getrennt
in [opportunities.md](opportunities.md).

## Projekt- und Laufzustand

- `AudiobookProject.swift`: versioniertes Transportmodell, Quellreferenzen und
  SHA-256-Fingerprints; enthält keine Audiodaten.
- `ConversionSession+Project.swift`: Projektübernahme, Quellenprüfung und
  Kapitelhistorie mit Umordnen, Nummerieren, Teilen und Zusammenführen.
- `ConversionRunState.swift`: flüchtiger Konvertierungszustand, unabhängig vom
  gespeicherten Projekt; vorhandene Session-Eigenschaften bleiben Adapter.
- `RunReport.swift`: versionierte Inspect- und JSON-Laufberichte für die CLI.
- `ChapterPreviewPlayer.swift`: Besitz und Abspielposition des Vorschauplayers.
- `ImportCoordinator.swift`: GUI-Providerkoordination über Core-Importtokens;
  abbrechbare Adressensammlung mit 60-Sekunden-Frist, einmaligem Abschluss
  und entwerteten späten Callbacks vor der eigentlichen Audioanalyse.
- `DocumentOpenCoordinator.swift`: AppKit-Delegate übernimmt vollständige
  System-Dateilisten; der Koordinator bündelt Audioimport und Projektöffnung
  mit Bestätigung und serialisiert spätere Ereignisse während eines eigenen
  Imports. Das aktive Projektfenster hat Vorrang. Vor der ersten Registrierung
  bleiben URLs erhalten; geschlossene Fenster werden sofort abgemeldet.
- `ChapterUndoRouter.swift`: fensterbezogenes Text-/Projekt-Undo;
  `ProjectWindowReader` registriert das AppKit-Fenster auch für Systemöffnungen.
- `OutputPreviewView.swift`: konkrete Zielpfade und geschätzter Volume-Bedarf.

Details zum Speicherformat und zu Bearbeitungsgrenzen: [Projekte](projects.md).

`AudioImportService.swift` besitzt die gebündelte AVFoundation-Analyse,
Dateiidentität, Metadaten-/Artwork-Snapshots, begrenzte Tasks und Analysezähler.
`FFmpegArguments.swift` baut Slice-/Encoding-Argumente.
`LoudnessMeasurement.swift` wertet die buchweite Lautheit und den gemeinsamen
linearen Pegel aus.

`OutputCoordinator.swift` besitzt Ausgabeauswahl, Vorschau, Überschreibbestätigung
und Laufstart; `ContentView` bindet dessen Zustand.
