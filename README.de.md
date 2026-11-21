[English](README.md) · [Deutsch](README.de.md)

# Hörbuchklöppler

Hörbuchklöppler baut aus Audiodateien ein `.m4b`-Hörbuch mit Kapiteln, Cover
und Metadaten. Die macOS-App und das Kommandozeilenprogramm `kloeppler`
nutzen denselben Code für Import und Kodierung. Beide lesen MP3, M4A, WAV,
FLAC und bestehende M4B-Dateien.

## Audioqualität und Dateigröße

Die Voreinstellung für Sprache ist Mono-AAC mit 48 kbit/s und 32 kHz.
Die 49 Sekunden lange Hörprobe im Release belegt damit 299 KB und mit
128 kbit/s 772 KB. Mit der Voreinstellung ist die Datei rund 61 % kleiner.
Die Aufnahme *Wunder über Wunder* stammt aus LibriVox'
[Sammlung deutscher Gedichte 018](https://archive.org/details/sammlung_deutscher_gedichte_018_1506_librivox).

Für Musik oder Hörspiele kannst du Bitrate und Abtastrate erhöhen und
Stereo wählen.

## Kapitel bearbeiten und Projekt speichern

Importiere einen Ordner oder zieh Audiodateien ins App-Fenster. Aus jeder
Datei entsteht zunächst ein Kapitel. Bei M4B-Dateien übernimmt die App
vorhandene Kapitelmarken als bearbeitbare Kapitel. Titel lassen sich ändern,
Kapitel verschieben und eine Auswahl mit gemeinsamem Präfix nummerieren.

Zum Teilen spielst du das Kapitel in der Liste ab und klickst an der
gewünschten Stelle auf **Teilen**. **Zusammenführen** verbindet das
ausgewählte Kapitel mit dem folgenden, wenn die Abschnitte in derselben
Quelle direkt aneinandergrenzen. Cmd+S speichert die Arbeit als
`.hkproject`. Das Projekt verweist auf die Audiodateien und speichert
Kapiteländerungen, Metadaten, Cover und Konvertierungseinstellungen.
Du kannst es erneut öffnen oder an die CLI übergeben.
[Projekte und Kapitelbearbeitung](docs/projects.md)

Die App liest Cover und Tags aus den Quellen. Du kannst ein eigenes Cover
auswählen und die Buchmetadaten bearbeiten. Die Ausgabevorschau zeigt die
geplanten Dateien vor der Kodierung. In den Audioeinstellungen kannst du
die Lautheit analysieren und das ganze Buch mit einem gemeinsamen Pegel
auf −18 LUFS angleichen, soweit die Spitzengrenze es zulässt. Eine
Maximaldauer teilt lange Bücher in Dateien mit den Endungen `-01`,
`-02` und so weiter auf.
[Kodierung und Lautheit](docs/encoding.md)

## Installieren oder bauen

Der App-Build benötigt macOS (Apple Silicon oder Intel) und Xcode. Für die
CLI genügt die Swift-Toolchain aus den Xcode-Kommandozeilenwerkzeugen.
Das Repository verteilt den Quellcode.
Beim lokalen Build lädt `build.sh` die Programme `ffmpeg` und
`mediainfo` von deren Projekten. Das fertige Bundle enthält
GPL-lizenziertes `ffmpeg`.
[Abhängigkeiten und Lizenzen](docs/dependencies.md)

```bash
git clone https://github.com/DanielMuellerIR/hoerbuchkloeppler.git
cd hoerbuchkloeppler
./build.sh              # Ad-hoc-signierte App im Projektordner und CLI
./build.sh --cli-only   # nur das Kommandozeilenprogramm bauen
./build.sh --help
```

### Notarisierten Build installieren

`install.sh` benötigt ein Developer-ID-Application-Zertifikat und ein
`notarytool`-Profil im Schlüsselbund. Den Profilnamen legst du mit
`NOTARY_PROFILE` oder der lokalen Git-Einstellung
`hoerbuchkloeppler.notaryProfile` fest. Für Ad-hoc-Signierung genügt
`build.sh`.

```bash
./install.sh                 # bauen, notarisieren, Ticket anheften, prüfen und nach /Applications installieren
./install.sh --no-notarize   # Developer-ID-signierter Test-Build im Projekt
./install.sh --no-install    # notarisierte App im Projekt
./install.sh --help
```

### DMG für einen weiteren eigenen Mac bauen

`release.sh` verwendet dasselbe Zertifikat und Profil. Es legt die
notarisierte App in ein separat notarisiertes DMG für die eigenen Macs.

```bash
./release.sh                     # dist/Hörbuchklöppler-<version>.dmg
./release.sh --no-finder-layout  # Finder-Fensterlayout überspringen
```

## Kommandozeile

Diese Befehle machen die lokal gebaute CLI vom Projektordner aus in der
Shell verfügbar.

```bash
export PATH="$PWD/HoerbuchkloepplerCore/.build/release:$PATH"
kloeppler --help
```

Wähle genau eine Eingabeform, einen Ordner, ein gespeichertes Projekt oder
eine geordnete Liste von Audiodateien.

```bash
kloeppler "/pfad/zu/kapiteln" --title "Mein Buch" --output "Mein Buch.m4b"
kloeppler --project "Mein Buch.hkproject" --inspect --format json
kloeppler --file 02.wav --file 01.wav --normalize-loudness --output "Mein Buch.m4b"
```

- Öffne ein Projekt mit `--project` oder gib mit wiederholtem `--file` die
  gewünschte Reihenfolge an. `--inspect` analysiert die Quellen und zeigt
  die geplanten Ziele, ohne Dateien anzulegen. `--format json` liefert den
  Analysebericht als JSON und Konvertierungsereignisse als JSON Lines.
- Wähle Audioeinstellungen mit `--mode`, `--bitrate`, `--samplerate`,
  `--mono` oder `--stereo`. `--workers` begrenzt die Kodierprozesse,
  `--import-workers` die gleichzeitigen Quellanalysen.
- `--analyze-loudness` misst die Buchlautheit. `--normalize-loudness`
  misst sie und passt den Pegel für das gesamte Buch an.
- Überschreibe Tags mit `--title`, `--author`, `--genre`, `--narrator`,
  `--series`, `--volume-number` und `--language`. `--cover` wählt ein
  Cover, `--no-cover` lässt es weg.
- `--max-duration` teilt nach Dauer, `--output` setzt einen Zielordner
  oder einen vollständigen `.m4b`-Pfad. Die Ausgabe landet standardmäßig
  im Elternordner der Quelle. `--verbose` gibt mehr Diagnosedetails aus.
  `--force` erlaubt in Skripten das Überschreiben vorhandener Ausgaben.

Der Exit-Code ist `0` bei Erfolg, `64` bei ungültigen Argumenten, `130`
nach einem angenommenen Abbruch mit Ctrl-C und `143` nach einem
angenommenen SIGTERM.
[CLI-Referenz und Prüfungen](docs/build-and-test.md#cli-kloeppler)

## Kodiermodi

- **Performance (Voreinstellung)** kodiert die Kapitel parallel und
  verbindet die AAC-Segmente ohne erneute Kodierung. Das braucht weniger
  temporären Speicher. Die vom Encoder hinzugefügten Samples an den
  Segmenträndern können die Übergänge gegenüber den Kapitelmarken verschieben.
- **Standard** bereitet WAV-Dateien vor und kodiert das Buch in einem
  durchgehenden AAC-Lauf. Das eignet sich für Musik, die über Kapitelgrenzen
  hinweg läuft. Bei langen Büchern können mehrere GB an WAV-Dateien anfallen.

Beide Modi nutzen Apples AAC-Encoder AudioToolbox mit begrenzter variabler
Bitrate. Die optionale Lautheitsanalyse braucht in beiden Modi temporäre
WAV-Dateien. [Details zur Kodierung](docs/encoding.md)

## Entwicklung und Lizenzen

[Architektur](docs/architecture.md) · [Bauen und testen](docs/build-and-test.md) · [Abhängigkeiten](docs/dependencies.md)

App und CLI stehen unter der [MIT-Lizenz](LICENSE).
SwiftPM lädt Swift Argument Parser. Die Programme `ffmpeg` und `mediainfo`
behalten ihre Lizenzen GPL-3.0 und BSD-2-Clause.
[Drittlizenzen](THIRD-PARTY-NOTICES.md)
