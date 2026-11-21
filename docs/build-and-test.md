# Bauen, CLI & Testen

## Alles bauen (empfohlen)

```bash
./build.sh              # lädt ffmpeg/mediainfo und baut CLI und App
./build.sh --cli-only   # baut Core und CLI ohne Xcode-App-Build
./build.sh --help
```

Das Skript legt `Hörbuchklöppler.app` im Projektordner und die CLI unter
`HoerbuchkloepplerCore/.build/release/kloeppler` ab. Die Herkunft der
Laufzeitwerkzeuge ist unter [Abhängigkeiten](dependencies.md) dokumentiert.

## Nur Core/CLI von Hand

```bash
cd HoerbuchkloepplerCore
swift build -c release      # -> .build/release/kloeppler
```

App alternativ direkt über `Hörbuchklöppler.xcodeproj` in Xcode (oder
`xcodebuild`) — dann müssen `ffmpeg`/`mediainfo` vorab via `./build.sh --deps-only`
in `Resources/bin/` liegen (sonst greift zur Laufzeit der Homebrew-Fallback).

## Begrenzter Linux-Probeweg

Die vollständige CLI bleibt macOS-gebunden. Der ausgeführte Linux-Core-Build,
die separat portablen Modelldateien und eine kleine AAC-/Kapitel-Gegenprobe sind
in [linux-portability.md](linux-portability.md) dokumentiert.
`bash tests/experiments/linux_core_probe.sh` ist ein Linux-Experiment mit
vorhandenem Swift/ffmpeg/ffprobe, kein erfolgreicher Build der vollständigen CLI.

## CLI `kloeppler`

Nach dem Build liefert die CLI die vollständige Hilfe. Die folgenden
Befehle starten im Projektordner.

```bash
export PATH="$PWD/HoerbuchkloepplerCore/.build/release:$PATH"
kloeppler --help
```

Jeder Aufruf verarbeitet genau eine Eingabeform. Ein Ordner wird nach den
Importregeln der App sortiert, `--file` übernimmt die angegebene Reihenfolge
und `--project` öffnet ein bearbeitetes `.hkproject`. Explizite Optionen
überschreiben die im Projekt gespeicherten Werte.

```bash
kloeppler "/pfad/zum/ordner" --output Buch.m4b
kloeppler --file 02.wav --file 01.wav --inspect --format json
kloeppler --project Buch.hkproject --format json --output Buch.m4b
```

| Aufgabe | Optionen |
| --- | --- |
| Quellen und geplante Ausgabe ansehen | `--inspect` analysiert und plant, ohne Ausgabedateien oder -ordner anzulegen. |
| Strukturierte Ausgabe | `--format text\|json` liefert mit `json` einen einzelnen Inspect-Bericht oder JSON Lines während einer Konvertierung. |
| Kodierung | `--mode parallel\|standard`, `--bitrate` (8–320 kbit/s, z. B. `48k` oder `64000`), `--samplerate` (8000–48000 Hz), `--mono` oder `--stereo`. |
| Gleichzeitige Prozesse begrenzen | `--workers` für Kodierung (1–32, automatisch höchstens 4), `--import-workers` für Quellanalysen (1–8, standardmäßig 4). |
| Lautheit | `--analyze-loudness` misst das Buch. `--normalize-loudness` schließt die Messung ein und passt den Pegel für das ganze Buch an. |
| Buchmetadaten | `--title`, `--author`, `--genre`, `--narrator`, `--series`, `--volume-number` (1–65535) und `--language` (ISO-639-Code, z. B. `deu`). |
| Cover | `--cover` verlangt eine reguläre, lesbare Bilddatei mit höchstens 32 MiB. `--no-cover` schaltet die Cover-Übernahme aus. |
| Ausgabe und Protokoll | `--output` akzeptiert einen Zielordner oder einen vollständigen `.m4b`-Pfad. `--max-duration` teilt nach Dauer in Stunden (`0` für unbegrenzt). `--verbose` protokolliert Pfade und Arbeitsschritte. `--force` erlaubt Überschreiben ohne Nachfrage. |

`--title` bestimmt den Dateinamen, sofern `--output` keinen vollständigen
Dateipfad vorgibt. Standardmäßig landet die Datei im Elternordner der
Quelle. Ohne explizite Metadaten wählt die CLI aus mehrdeutigen Tags nach
fester Priorität (Album vor Title, Performer vor Album_Performer).
Bei bereits vorhandenem Ziel fragt sie ohne `--force` nur nach, wenn
stdin und stdout Terminals sind.

Die CLI meldet auf stderr, warum ein Lauf fehlschlägt. Exit `0` bedeutet
Erfolg, Exit `64` ungültige Argumente. Ein angenommener Abbruch durch
SIGINT ergibt `130`, durch SIGTERM `143`.
[Projektformat und JSON-CLI](projects.md#cli)

## Ausgabe mit einer kleinen Quelle prüfen

```bash
# Im Projektordner starten. Für die Probe genügen drei Kapitel und folder.jpg.
HoerbuchkloepplerCore/.build/release/kloeppler "/pfad/zum/ordner" --mode standard --mono \
    --bitrate 48k --samplerate 32000 --output out.m4b --verbose

# Output mit den gebündelten Binaries prüfen:
BIN=HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin
"$BIN/ffmpeg" -i "out.m4b" -hide_banner 2>&1 | grep -E 'Chapter|Stream|title'
"$BIN/mediainfo" "out.m4b"
```

Prüfe Kapitel, Cover, Metadaten und Abtastrate in der erzeugten Datei.

## Tests ausführen

```bash
./tests/run.sh                 # Swift, Integration und Lifecycle
./tests/run.sh --swift         # Swift-Suiten mit -warnings-as-errors
./tests/run.sh --integration   # echte CLI-Aufrufe und AppKit-Koordinatoren
./tests/run.sh --lifecycle     # Build, Signatur, Installation und Release
```

Die App und die Swift-Tests importieren dieselben Koordinatoren aus
`HoerbuchkloepplerAppSupport`. Die AppKit-Fälle laufen ohne Fokusübernahme.
Die vollständige Prüfung und `--integration` durchlaufen die echte
60-Sekunden-Frist des Datei-Providers.

Der Runner stellt die gebündelten Werkzeuge bereit und verwendet den Debug-Build
der CLI für die Integrationstests. Projekt-, Matrix- und Übergangstest entfernen
ihre Testdaten nach Erfolg. Bei Fehlern bleibt der Diagnosepfad erhalten.
Mit `--keep-temp` bleibt er auch nach einem erfolgreichen Einzelaufruf erhalten.

`tests/experiments/encoding_without_wav.py` ist bewusst **kein** Test: Es misst
und druckt, sichert aber nichts zu. Nicht in einen Gate-Lauf aufnehmen.

Deckt die reine Kernlogik ab: FFMETADATA-Escaping/Parsing, Kapitel-Arithmetik
(`FFMetadata`), Auto-Split, Ausgabe-Dateinamen, Zeit-Parsing,
NaN/Infinity-Härtung sowie Ausgabeplan/atomare Übernahme, Tool-Auflösung,
laufbezogenen Abbruch, Metadatenentscheidung, echte asynchrone
AVFoundation-Analyse einer WAV-Datei, Symlink-Deduplizierung, Unterordner-
Sortierung, atomaren Mehrdateien-Import, Video-only-Ablehnung,
Prozessgruppen-Abbruch, Wrapper-Exit mit weiterlaufendem Hintergrundprozess,
Staging-Namensgrenzen und shell-sicheren CLI-Handoff. Ein reales Encoding ist
dabei: `LoudnessTests` baut ein echtes Buch mit dem gebündelten ffmpeg, dekodiert
es wieder und prüft integrierte Lautheit, Cover, Sprecher, Reihe, Band und
Sprache — das setzt aber `Resources/bin/ffmpeg` voraus (`./build.sh --deps-only`);
ohne die Binaries meldet der Test das ausdrücklich als Fehlschlag.

Die CLI-Matrix prüft temporäre Audiodaten im tatsächlichen macOS-Systemordner
(`getconf DARWIN_USER_TEMP_DIR`) und ordnet sie über `.owner-pid` dem eigenen
CLI-Lauf zu. Sie muss einen solchen Ordner vor dem Signal wirklich beobachten
und danach sein Verschwinden prüfen. Nur ein gesetztes `TMPDIR` zu prüfen reicht
nicht: Foundation ignoriert diese Umgebungsvariable auf manchen macOS-Ständen.
Leere persistente Ausgabesperrdateien sind kein verbliebenes Audio-Staging.

`ChapterAnalysisWorkerTests` prüft eine synthetische Liste mit 12.000 Kapiteln
(1.826.684 Bytes): Prozesskonfiguration außerhalb eines Swift-Tasks und des
Main Threads, unveränderte Titel/Zeiten sowie genau eine Prozessabmeldung.
Zusätzlich prüft die Suite Abbruch vor dem Start und im Rennen zwischen
Startprüfung und Prozessstart. Die Prozessgruppen-Suite prüft weiterhin den
Abbruch eines laufenden Kapitelwerkzeugs einschließlich seiner Nachkommen.
Die gemessene Laufzeit dieser Probe ist kein Leistungsvergleich für Hörbücher.

`tests/verify_scripts.sh` prüft die Syntax (`bash -n`) der Shell-Skripte im Projekt- und Testordner,
die Versions-Syntaxtabelle, den Abgleich von `VERSION` mit `MARKETING_VERSION`
und die Ein-Snapshot-Identität aus `script-helpers.sh`. Es führt außerdem
`tests/verify_sign_bundle.py` aus: echte kleine Ad-hoc-App-/Tool-/Framework-
Signaturen, statischer Core, Reihenfolge, Strip-/Modulbereinigung,
Vorbedingungen sowie kontrollierte Fehler von `codesign`, `find` und `file`.
Die Developer-ID-Flags werden geprüft, der kontrollierte Aufruf endet vor
einer echten Signierung. Dafür werden macOS, Python, Clang und die Apple-
Signierwerkzeuge benötigt; alle Test-Bundles bleiben außerhalb `/Applications`.
`tests/verify_install_lifecycle.py` führt eine unveränderte Kopie von `install.sh`
mit kontrollierten Build-, Signier- und Notary-Diensten aus.
`HOERBUCHKLOEPPLER_INSTALL_DEST` zeigt auf einen eigenen Temp-Ordner.
Das Skript baut den regulären Swift-Helfer und führt Kopie, Dateiaustausch
und Rückzug mit echten Dateisystemoperationen aus. Die Prüfung umfasst
Erstinstallation, Austausch, fehlgeschlagene Prüfungen vor und nach dem
Austausch, beide Ausstiegsoptionen, Prozessbesitz und simulierte PID-Änderung.
Sie prüft fremde Einträge am Ziel, Elternordner, Staging oder Backup,
einschließlich Änderungen beim Kompilieren des Helfers und nach der
Abschlussprüfung. Auch diese Prüfung gehört zu `tests/verify_scripts.sh`.
`swift test --package-path tools/InstallBundle -Xswiftc -warnings-as-errors`
prüft den Helfer zusätzlich auf exklusive Umbenennung, ausgetauschte Einträge
zwischen Umbenennung und Identitätsprüfung, Backup-Kollision, Rückzug
zwischen Austausch und Backup sowie das Löschen von Symlinks ohne Zugriff
auf ihre Ziele.
`tests/verify_release_lifecycle.py` führt eine unveränderte Kopie von
`release.sh --no-finder-layout` mit kontrollierten Installations-, Image- und
Apple-Diensten aus. Kopien, Links und die abschließende Umbenennung geschehen
wirklich in eigenen Testordnern. Geprüft werden Reihenfolge, App/Lizenzhinweise/
Applications-Link im Image-Inhalt, Fehler bis zur Gatekeeper-Prüfung und der
Erhalt eines früheren guten Images. Aktive oder unbekannte Mounts müssen samt
RW-Image erhalten bleiben; ein fehlgeschlagener Statusabruf darf keine
Bereinigung erlauben. Der Test verwendet keine echten Mounts, keine
Apple-Dienste und keinen Finder. Er gehört ebenfalls zu `tests/verify_scripts.sh`.
Ein Wiederholungslauf nach gescheitertem Aushängen prüft ausdrücklich den
Erhalt des vorherigen RW-Images und seiner Identität.
Ein ergänzender echter, unsichtbarer HFS+-DMG-Probelauf am 2026-10-07 belegte
das vollständige App-Bundle im Wurzelverzeichnis und sauberes Aushängen.
`tests/verify_build_lifecycle.py` prüft außerdem eine unveränderte Kopie von
`build.sh`: Optionen, vorhandene/fehlende/beschädigte Abhängigkeiten, Download-,
Archiv-/Binary-Prüfsummen- und Extraktionsfehler, Startproben sowie
CLI-/App-Build und Ad-hoc-Signierungsvertrag. Compiler, Prüfsummenausgaben und
Downloads sind kontrollierte Fixtures; sie ersetzen keine echten Builds oder
kryptografische Prüfung der Upstream-Binaries. Ein ergänzender realer
`build.sh --deps-only`-Lauf am 2026-10-07 bestätigte deren Prüfsummen und Start.
Die MediaInfo-Mounts sind im Fixture ebenfalls kontrolliert: Nach teilweise
erfolgreichem Attach wird aufgeräumt; aktive oder unbekannte Mounts bleiben mit
ihren Daten erhalten. Der Test gehört zu `tests/verify_scripts.sh` und arbeitet ohne
Netzwerk, reale Mounts oder Installationen.

Die geprüften Funktionen sind `internal` statt `private`, damit `@testable
import` drankommt. Das ist Absicht, kein vergessenes `private`.

## Terminal-Ausgabe prüfen (ohne vor dem Terminal zu sitzen)

```bash
python3 tests/verify_cli_terminal.py   # läuft ~3 s, braucht ffmpeg + swift build
```

Das Skript erledigt das frühere Handrezept maschinell: Es startet die CLI an
einem Pseudoterminal, unterbricht sie mit SIGINT, sobald der Fortschrittsbalken
erscheint, spielt den Strom durch einen Mini-Emulator und prüft, dass jede
Logzeile im Endbild steht und der Exit-Code 130 ist.

Das Rezept dahinter, falls es von Hand nachvollzogen werden soll: Die CLI
zeichnet den Pacman-Statusblock per ANSI-Cursor-Sprüngen neu. Ob das
Bild stimmt, sieht man einer `> datei.raw`-Mitschrift nicht an — die
Escape-Sequenzen müssen erst „gerendert" werden:

1. Lauf mit `--verbose --mode parallel` nach `raw`-Datei umleiten. `--verbose`
   ist wichtig: nur dann feuert `logVerbose` aus den Encoding-Threads mitten in
   die Redraw-Schleife.
2. Den Strom durch einen Mini-Emulator schicken, der `ESC[1A`, `ESC[2K`,
   `ESC[G` und Text nachbildet — mehr nutzt die CLI nicht — und das Endbild
   ausgeben.
3. **Erfolgskriterium:** Jede geschriebene Logzeile steht im Endbild noch
   vollständig da. Vor dem Fix gingen 4 von 18 Zeilen verloren (u.a. „🏁 Alle
   Vorgänge beendet."), danach 0 von 18.

Deshalb laufen alle Terminal-Ausgaben der CLI über `TerminalRenderer` in
`KloepplerCLI.swift`; der Core schreibt nie direkt auf stdout, sondern über
`ConversionSession.logSink`.

## Schlüssel-Dateien zum Prüfen bei Änderungen

- `FFmpegWrapper.swift` — Kommando-Bau und Kodierpipeline;
  `ProcessTermination.swift` — Prozessstart und -abbruch;
  `OutputStaging.swift` — Staging, Sperren, atomare Übernahme, Bereinigung.
- `ConversionSession.swift` — Lebenszyklus, Thread-sicheres Logging.
- `KloepplerCLI.swift` — CLI-Ablauf und `--verbose`;
  `TerminalRenderer.swift` — Terminal-Output und ANSI.
- `AudioFile+Extensions.swift` — Metadaten/Kapitel/Cover.

## Bekannte Test-Lücken / offen

- Stream-Copy-Merge mit verschiedenen Codecs.
- Lautheitssteuerung (`FFmpegWrapper.convert`): abgedeckt seit 2026-09-10. Der
  interne `convert(session:plan:measureBookLoudness:)` nimmt den Messwert als
  Testnaht entgegen; `LoudnessTests.analysisOnlyKeepsLevelAndSurvivesFailure`
  prüft damit die reine Analyse (Gain bleibt 0), den Fehlschlag der reinen
  Analyse (Konvertierung läuft weiter) und den Fehlschlag der Angleichung (Lauf
  bricht ab). Ein SIGTERM direkt nach der Ankündigung des Messpasses prüft
  `tests/verify_cli_matrix.py` (Exit 143, terminales `cancelled`, keine
  `HB_Loudness_*`-Reste). Offen bleibt nur ein Signal tief im laufenden
  loudnorm-Durchlauf.
- Fehlschlag von `mediainfo` beim Import ist nicht injizierbar
  (`getBinaryURL` bevorzugt das Bundle); die Regel „leere Auswahl nur bei
  leerem Titel/Autor“ ist deshalb nur über den prozessfreien Pfad getestet.
- Extrem große/kleine Segmente.
- UI-Responsiveness bei schwerem parallelem Encoding.
- **Voll-Buch (>20 Kapitel) maschinell verifiziert (2026-07-16):** reales
  23-Kapitel-Buch (11:22 h) im Parallel-Modus, 23 korrekte Kapitelmarken,
  Cover, Metadaten, Exit 0. Nach Gehör weiterhin ungeprüft.
- **CLI end-to-end verifiziert (Stand 2026-06-25):** Standard- + Parallel-Modus,
  m4b-Re-Import (`extractChapters` via gebündeltem ffmpeg), Auto-Split
  (`--max-duration` → `-01`/`-02`), Stereo (44100 Hz), Cover (eingebettet +
  `folder.jpg`), Kapiteltitel mit Sonderzeichen, Fehler-Exit-Codes, SIGINT-
  Abbruch inkl. Temp-Cleanup. SIGINT während der AVFoundation-Vorbereitung
  wurde am 2026-08-15 mit 1.001 WAV-Dateien und Exit 130 verifiziert. Am
  2026-08-25 wurden SIGINT und SIGTERM während eines realen ffmpeg-Laufs je
  dreimal mit Exit 130 beziehungsweise 143, ohne finale Ausgabe und ohne
  Staging-Reste geprüft; weitere 24 Läufe deckten die Abschluss-Rennbedingung ab.
- **GUI-Abläufe geprüft (2026-10-07, 1.4.31):** notarisiertes Release-Bundle
  über Launch Services mit Projekt gestartet. Text- und Kapitel-Undo über
  Menü, Tastenkürzel und Toolbar, Ersetzen/Abbrechen, gemeinsamer Audioimport,
  erneutes Öffnen nach Schließen sowie zwei unabhängige Projektfenster geprüft.
  Ein privater Provider-Testaufbau verwendet dieselbe Import-/Dialoglogik und
  prüft die tatsächliche 60-Sekunden-Frist samt Wiederholen, Abbrechen und
  gesperrter Kapitelbearbeitung. Großes Cover sowie kleine/große Fenster und
  Scrollen der Seitenleiste visuell geprüft. Dies deckt gezielte Zustände ab;
  Audioqualität nach Gehör und sämtliche übrigen Ansichten bleiben ungeprüft.

## GUI-Import

„Dateien oder Ordner hinzufügen …“ (Cmd+O) und Drag-and-drop verwenden
dieselben Core-Importregeln. Die Fortschrittsleiste zählt analysierte Einträge;
beim Erkennen eines Ordners wächst die Gesamtzahl um dessen Dateien. Cover-
und Metadatenanalyse können danach noch Zeit benötigen.
„Import abbrechen“ verwirft den noch nicht übernommenen Batch vollständig,
erhält vorhandene Kapitel und Metadaten und beendet dessen Analyseprozesse.
Verspätete Provider-Antworten verlieren ihre Importberechtigung. Während der
abschließenden Metadatenübernahme ist Abbrechen deaktiviert.
Datei-Adressen eines Drag-and-drop-Anbieters müssen innerhalb von 60 Sekunden
vorliegen. Danach wird der gesamte neue Batch verworfen; das vorhandene Hörbuch
bleibt erhalten. Der Dialog bietet „Wiederholen“ und „Abbrechen“, ohne automatisch
erneut zu laden. Die Frist endet, sobald alle Adressen vorliegen; die eigentliche
Audioanalyse unterliegt diesem Provider-Zeitlimit nicht.

Regression: `userCancellationPreservesExistingBook` prüft Teilfortschritt,
Task-Abbruch, erhaltene Bearbeitung und verspätete Beiträge vor/nach Neustart.

## Projekt- und JSON-Regression

`swift test -Xswiftc -warnings-as-errors` enthält Roundtrips, fehlende und
veränderte Quellen, FIFO-Abweisung, Versionsvalidierung, Nachimportreihenfolge
und Kapitel-Undo/Redo einschließlich Entfernen des letzten Kapitels.

```sh
swift build --package-path HoerbuchkloepplerCore
python3 tests/verify_cli_project.py
```

Das Skript erzeugt zwei reale WAVs und ein Projekt, prüft explizite Dateifolge,
JSON-Parsing ohne Diagnosen auf stdout, schreibfreies Inspect mit nicht
existierendem Zielordner und Fehler ohne Ausgabedatei bei veränderter Quelle.
Die Standard-Konvertierung wird vollständig dekodiert; bei 32 kHz werden
höchstens 100 ms AAC-Randabweichung zugelassen. Fixtures bleiben zur Diagnose
im genannten temporären Ordner. Format und Grenzen: [Projekte](projects.md).

## Sprecher und Lautheit

`--narrator`, `--series`, `--volume-number` (1–65535) und `--language`
(z. B. `deu`, `eng`; gebräuchliche Zweibuchstabencodes werden erweitert)
überschreiben die jeweiligen importierten Projektwerte.
`--analyze-loudness` misst das vollständige Buch; `--normalize-loudness`
impliziert die Analyse und wendet einen gemeinsamen linearen Pegel an.
Zusätzlicher Dekodier-/Analysepass und temporärer WAV-Bestand werden vorab
in der GUI erklärt und im Lauf protokolliert. Beide Optionen sind standardmäßig aus.

## Erweiterte Abnahme

Voraussetzungen: `ffmpeg` in `Resources/bin/` (`./build.sh --deps-only`, liegt
nicht im Repo), die Debug-CLI aus `swift build` und für
`verify_audio_transitions.py` zusätzlich `ffprobe` im PATH (Homebrew). Die
Skripte brechen mit klarer Meldung ab, wenn etwas fehlt. Danach, nach
`swift test` im Core:

```sh
python3 tests/verify_cli_project.py
python3 tests/verify_audio_transitions.py
python3 tests/verify_cli_matrix.py
swift test --package-path HoerbuchkloepplerCore --filter AppSupportTests
HOERBUCHKLOEPPLER_VERIFY_PROVIDER_TIMEOUT=1 swift test --package-path HoerbuchkloepplerCore \
  --filter providerImportAndCoverDrop
```

Die GUI-Importprüfung verwendet echte NSItemProvider ohne Fenster/Fokus und
prüft acht Dateien, Fortschritt, hängende/verspätete Provider, Timeout mit
Erhalt des Bestands, Wiederholen desselben Batches, Benutzerabbruch sowie
einen neuen Import vor Ablauf des alten Timers. Die schnellen Fälle verwenden
eine verkürzte Frist; `--default-timeout` misst zusätzlich die echte
Standardfrist. Der sichtbare Timeoutdialog und beide Aktionen wurden zusätzlich
im laufenden Test-Bundle mit derselben Importlogik geprüft.
`chapterAndTextUndo` in `AppSupportTests` prüft echtes AppKit-Text-Undo und Kapitel-Undo
ohne sichtbare Fenster, einschließlich leerem Textverlauf, anderem aktivem
Fenster und Sperren während Import/Konvertierung. Menüeinbindung, Toolbar und
Tastenkürzel sind zusätzlich im laufenden App-Bundle geprüft.

`systemDocumentOpening` in `AppSupportTests` prüft den System-URL-Koordinator mit
unsichtbaren AppKit-Fenstern: die vollständige Delegate-Dateiliste vor der
ersten Fensterregistrierung, das Abmelden eines noch gehaltenen geschlossenen
Fensters, mehrere Audioereignisse als ein vollständiger Import, Projektöffnung
im leeren Fenster, Bestätigung/Abbrechen vor Ersetzen, eine bereits aufgelöste
Alert-Bindung, defekte Projekte, gemischte Auswahl und laufenden Import.
Ein kontrolliert verzögerter Import prüft zusätzlich später eintreffende
System-URLs außerhalb der anfänglichen Sammelfrist.
Launch-Services-Öffnung und tatsächliche Alert-Bedienung sind zusätzlich im
App-Bundle geprüft. Die Prüfung eines Finder-Doppelklicks ist davon unabhängig.
`python3 tests/verify_terminal_renderer.py` prüft physische Statuszeilen an
PTYs mit 12/24/40/80 Spalten, Unicode, kleinem Fenster und Größenwechseln.
Die Anzeige reserviert die letzte Spalte gegen automatischen Umbruch und
begrenzt den Statusblock auf die sichtbare Höhe. Nach einem Größenwechsel
bleibt der vorige Status einmal stehen; der nächste Block beginnt darunter,
damit kein Cursor-Sprung mit veralteter Geometrie Logzeilen trifft.
Die CLI-Matrix erzeugt lange stille Testquellen für echte Stunden-Splits.
AAC-Toleranzen und gemessene Performance-Kapitelversätze stehen in encoding.md.

### Cover-Grenzen

Die Swift-Suite `ArtworkResourceTests` erzeugt eigene MP3-, M4A- und PNG-Dateien.
Sie prüft eine begrenzte Vorschau für ein Bild mit 96 Millionen Pixeln,
die unveränderten Coverbytes und den Erhalt der bisherigen Auswahl bei
ungültigen Bildern oder einem gültigen PNG mit 33 MiB Zusatzdaten. Die
echte ffmpeg-Extraktion findet auch nach einem ungültigen oder zu großen
ersten APIC-Bild das nachfolgende gültige Cover. Für die Suite werden
Python 3 und das gebündelte FFmpeg benötigt.
