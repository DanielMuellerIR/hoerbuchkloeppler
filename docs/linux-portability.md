# Linux-Portierbarkeit: geprüfter Stand 2026-10-07

Die vollständige CLI und der gemeinsame Core unterstützen derzeit macOS.
Ein unveränderter Core-Build unter Linux scheitert bereits an
`AudioFile+Extensions.swift: import AVFoundation`. Das Austauschen der
gebündelten Werkzeuge reicht für einen Linux-Port nicht aus.

Geprüfter Quellstand: `bccce6c1251737e0a2bf2ab6de81139aa8fface0` (1.4.22).
Gegenprobe unter Linux x86_64 mit Swift 6.0.3, Ubuntu-24.04-Container auf einem
Linux-Mint-22.2-Host, begrenzt auf zwei CPUs und zwei GiB RAM. Die Quellen waren
im Container nur lesbar eingebunden; Build- und Audiodaten blieben im
Wegwerf-Container. Auf dem Host wurden keine Werkzeuge installiert.

## Ausgeführte Gegenproben

- `swift build -j 2 -Xswiftc -warnings-as-errors` für das vollständige Package:
  Exit 1 wegen fehlendem `AVFoundation`. `swift-argument-parser` 1.7.1 wurde
  aufgelöst; der Befund ist kein bloß fehlender Paketdownload.
- Die unveränderten Dateien `AudioSettings.swift`, `SettingsManager.swift` und
  `LoudnessMeasurement.swift` bauen separat mit Swift-Sprachmodus 6 und
  Warnungen als Fehler. Geprüft wurden Bitratengrenzen, tolerante Dekodierung,
  Normalisierung, Workergrenze, Einstellungs-Roundtrip und Pegelberechnung.
- Linux-ffmpeg 6.1.1 erzeugt eine zweisekündige AAC-M4B mit zwei Kapiteln.
  ffprobe bestätigt Codec, Mono, 32 kHz, Dauer sowie Titel und Grenzen beider
  Kapitel. Vollständige Dekodierung mit Fehlerabbruch besteht.

Reproduktion der beiden positiven Teilproben auf Linux mit vorhandenen
Werkzeugen `swiftc`, `ffmpeg` und `ffprobe`:

```bash
bash tests/experiments/linux_core_probe.sh
```

Das Skript übersetzt die drei wirklichen Core-Dateien, keine Kopien ihrer
Implementierung. Sein kleiner Harness und alle erzeugten Daten liegen in einem
eigenen temporären Ordner, der beim Ende entfernt wird. Die Audio-Probe nutzt
den nativen Linux-AAC-Encoder `aac`. Sie prüft den Werkzeugweg, keine akustische
Gleichwertigkeit zum macOS-Encoder `aac_at/cvbr` und keine fertige CLI-Portierung.

## Plattformgrenzen im aktuellen Code

| Bereich | Aktuelle Bindung | Erforderliche Trennung |
| --- | --- | --- |
| Medienanalyse | `AudioImportService`, `AudioFile+Extensions`, AVFoundation/CoreMedia | Dauer, Audio-Streams, Tags, Sprache, Kapitel und Artwork über einen gemeinsamen Analysevertrag liefern; Linux-Backend gesondert prüfen |
| Daten und Frontend | `AudioFile`/`FoundFile` und weitere Modelle in `ConversionSession`; `Combine`, AppKit, Main-Actor-Zustand | Transport- und Planungsmodelle vom beobachtbaren App-Zustand trennen; die CLI benötigt dieselben geprüften Daten ohne AppKit |
| CLI-Coverausgabe | `KloepplerCLI` importiert AppKit und erzeugt ASCII aus `NSImage` | Bildausgabe hinter einen Plattformadapter legen; JSON und Konvertierung davon unabhängig halten |
| Bilder | ImageIO, AppKit-Coverbilder | Größen-/Decode-Grenzen, gespeicherte Coverbytes und Vorschau getrennt behandeln |
| Projekt-Fingerprints | CryptoKit in `AudiobookProject` | SHA-256-Implementierung mit plattformneutralem Vertrag und identischem Projektformat wählen |
| Dateien und Ausgabe | Darwin, `renameatx_np`, `fcntl`, xattrs, unterschiedliche `stat`-Felder | Linux-Implementierung des bestehenden Besitz-, Sperr-, Austausch- und Rollbackvertrags; ein bloßer Importwechsel zu Glibc genügt nicht |
| Prozesse und Terminal | Darwin-Signale/Polling, Annahmen über Prozessgruppen und Locale-Funktionen | Prozessgruppen samt Nachkommen, begrenztes Pipe-Lesen, Signal-Exit-Codes und Terminalbreiten auf Linux tatsächlich prüfen |
| Werkzeuge und Encoder | macOS-Mach-O-Ressourcen, `aac_at`, vorhandene MediaInfo-Auswertung | Linux-Werkzeuge und Encoder ausdrücklich auflösen; keine macOS-Binaries laden; Abweichungen als Plattformverhalten dokumentieren |

Der bestehende Ausgabeschutz ist eine wesentliche Grenze: Bereits geplante
Quellen und Zielverzeichnisse werden erneut auf Identität geprüft; temporäre
Dateien bleiben an Deskriptoren und Besitzer gebunden; Austausch und Rückzug
dürfen fremde Einträge nicht löschen. Diese Eigenschaften müssen unter Linux
erhalten und gegen dortige Dateisystem-Rennen geprüft werden.

Eine spätere GUI kann erst auf einer funktionierenden Linux-CLI aufbauen.
Web-, GTK- oder Qt-Oberflächen sind damit noch nicht ausgewählt oder umgesetzt.
