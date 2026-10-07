# Bauen, CLI & Testen

## Alles bauen (empfohlen)

```bash
./build.sh            # lädt ffmpeg/mediainfo vom Upstream + baut CLI + App
                      #   -> ./Hörbuchklöppler.app (zum Testen), CLI in .build/release/
./build.sh --cli-only # nur Binaries + Core/CLI (kein Xcode-App-Build)
./build.sh --help     # alle Optionen
```

Das Skript lädt die externen Binaries (nicht im Repo — siehe
[dependencies.md](dependencies.md)) und legt die fertige App im Repo-Root ab.

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

```
kloeppler <ordner> [--mode parallel|standard] [--bitrate 48k] \
          [--samplerate 32000] [--max-duration 0] [--mono|--stereo] \
          [--title <titel>] [--author <autor>] [--genre <genre>] \
          [--cover <bild>|--no-cover] [--output <ziel>] \
          [--verbose] [--force]
```

- `<ordner>` = absoluter Pfad zu einem Ordner mit Audiodateien (1 Datei = 1
  Kapitel). Cover = größte Bilddatei / `folder.jpg` im Ordner.
- `--max-duration <std>` teilt lange Bücher auf `-01`, `-02` … auf (0 =
  unbegrenzt). Pendant zur GUI-Einstellung „Maximale Dauer".
- `--title` / `--author` setzen Buchtitel/Autor explizit und gewinnen gegen die
  aus den Datei-Tags erkannten Kandidaten (`--title` bestimmt auch den Dateinamen).
  Ohne diese Optionen entscheidet die CLI bei mehrdeutigen Tag-Kandidaten selbst
  nach fester Priorität: Album vor Title bzw. Performer vor Album_Performer
  (die GUI öffnet in diesem Fall stattdessen die manuelle Auswahl).
- `--genre`, `--cover` und `--no-cover` bilden die entsprechenden GUI-Werte im
  kopierten CLI-Handoff vollständig ab. Eine explizite Cover-Datei muss regulär,
  lesbar und höchstens 32 MiB groß sein.
- `--output <ziel>` = Zielordner (Datei heißt dann `<Titel>.m4b`) **oder** voller
  `.m4b`-Pfad. Ohne Angabe landet die `.m4b` im **Eltern**-Ordner der Quelle,
  benannt nach Titel-Tag bzw. Ordnername (sanitisiert) — `--output` ist nötig,
  wenn die Quelle auf einem vollen/schreibgeschützten Datenträger liegt.
- **Eingabe-Validierung:** `--mode` (nur `parallel`/`standard`), `--bitrate`
  (8–320 kbit/s als `<zahl>[k]`) und `--samplerate` (8000–48000) werden vorab
  geprüft; ungültige
  Werte brechen mit Usage-Fehler (Exit 64) ab, statt erst später in ffmpeg.
- Existiert die Zieldatei: ohne `--force` interaktive Nachfrage, aber nur wenn
  stdin und stdout Terminals sind. Bei Umleitung oder Pipe bricht die CLI mit
  Fehlercode ab und verweist auf `--force`.
- **Exit-Code:** 0 nur bei echtem Erfolg, sonst ≠ 0; SIGINT liefert 130 und
  SIGTERM 143 (skript-/agent-tauglich).

## Demo-/Verifikations-Rezept (2026-06-03 erprobt)

```bash
# Kleiner Subset-Ordner (z.B. 3 Kapitel + folder.jpg) genügt für End-to-End.
.build/release/kloeppler "/pfad/zum/ordner" --mode standard --mono \
    --bitrate 48k --samplerate 32000 --verbose

# Output mit den gebündelten Binaries prüfen:
BIN=Sources/HoerbuchkloepplerCore/Resources/bin
"$BIN/ffmpeg" -i "out.m4b" -hide_banner 2>&1 | grep -E 'Chapter|Stream|title'
"$BIN/mediainfo" "out.m4b"
```

Beobachtetes Verhalten verifizieren (Kapitel, Cover, Metadaten, Sample-Rate) —
nicht nur „Build grün".

## Unit-Tests (Core)

```bash
cd HoerbuchkloepplerCore && swift test        # vollständige Core-/CLI-Suite
cd .. && ./test_scripts.sh                    # Build-/Install-/Release-Wächter
python3 test_project_cli.py                   # Projekt-CLI von Ende zu Ende
python3 tests/verify_cli_matrix.py            # CLI-Abnahme: Optionen, Exit-Codes, Signale
python3 tests/verify_cli_terminal.py          # ANSI-Endbild der CLI
python3 tests/verify_audio_transitions.py     # Kapiteleinsätze im erzeugten m4b nachmessen
```

`tests/experiments/encoding_without_wav.py` ist bewusst **kein** Test: Es misst
und druckt, sichert aber nichts zu. Nicht in einen Gate-Lauf aufnehmen.

Deckt die reine Kernlogik ab: FFMETADATA-Escaping/Parsing, Kapitel-Arithmetik
(`buildChapterMetadata`), Auto-Split, Ausgabe-Dateinamen, Zeit-Parsing,
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

`test_scripts.sh` prüft die Syntax (`bash -n`) aller Root-Shell-Skripte,
die Versions-Syntaxtabelle, den Abgleich von `VERSION` mit `MARKETING_VERSION`
und die Ein-Snapshot-Identität aus `script-helpers.sh`. Es führt außerdem
`tests/verify_sign_bundle.py` aus: echte kleine Ad-hoc-App-/Tool-/Framework-
Signaturen, statischer Core, Reihenfolge, Strip-/Modulbereinigung,
Vorbedingungen sowie kontrollierte Fehler von `codesign`, `find` und `file`.
Die Developer-ID-Flags werden geprüft, der kontrollierte Aufruf endet vor
einer echten Signierung. Dafür werden macOS, Python, Clang und die Apple-
Signierwerkzeuge benötigt; alle Test-Bundles bleiben außerhalb `/Applications`.
`tests/verify_install_lifecycle.py` führt eine unveränderte Kopie von `install.sh`
mit kontrollierten Build-/Signier-/Notary-Diensten aus. Das vorhandene
`HOERBUCHKLOEPPLER_INSTALL_DEST` zeigt auf einen eigenen Temp-Ordner; `ditto`,
der Swift-Dateiaustausch und Rollback laufen wirklich. Erstinstallation,
Austausch, Quell-/Staging-/Laufzeitfehler, `--no-install`/`--no-notarize`,
Prozessbesitz, simulierte PID-Änderung sowie ausgetauschte Ziele/Elternordner
werden geprüft. Alle eigenen Helferprozesse werden beendet; im Konfliktfall
muss das alte Backup erhalten bleiben. Auch diese Prüfung gehört zu
`test_scripts.sh`. Sie ersetzt keine echte Apple-Notarisierung.
Zusätzliche Gegenproben ersetzen Elternordner, Staging oder Backup während
der späteren Prüfungen; die Bereinigung muss diese fremden Einträge erhalten.
`tests/verify_release_lifecycle.py` führt eine unveränderte Kopie von
`release.sh --no-finder-layout` mit kontrollierten Installations-, Image- und
Apple-Diensten aus. Kopien, Links und die abschließende Umbenennung geschehen
wirklich in eigenen Testordnern. Geprüft werden Reihenfolge, App/Lizenzhinweise/
Applications-Link im Image-Inhalt, Fehler bis zur Gatekeeper-Prüfung und der
Erhalt eines früheren guten Images. Aktive oder unbekannte Mounts müssen samt
RW-Image erhalten bleiben; ein fehlgeschlagener Statusabruf darf keine
Bereinigung erlauben. Der Test verwendet keine echten Mounts, keine
Apple-Dienste und keinen Finder. Er gehört ebenfalls zu `test_scripts.sh`.
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
ihren Daten erhalten. Der Test gehört zu `test_scripts.sh` und arbeitet ohne
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
- **Appstart geprüft (2026-09-05):** Release-App im Hintergrund gestartet und
  beendet; die aktive Anwendung blieb unverändert. GUI-Dateiprovider sind
  zusätzlich fensterlos geprüft. Visuelle Bedienung und Audioqualität nach
  Gehör bleiben ungeprüft.

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
python3 test_project_cli.py
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
python3 test_project_cli.py
python3 tests/verify_audio_transitions.py
python3 tests/verify_cli_matrix.py
bash tests/verify_gui_import.sh
bash tests/verify_gui_import.sh --default-timeout  # zusätzlich echte 60 Sekunden
```

Die GUI-Importprüfung verwendet echte NSItemProvider ohne Fenster/Fokus und
prüft acht Dateien, Fortschritt, hängende/verspätete Provider, Timeout mit
Erhalt des Bestands, Wiederholen desselben Batches, Benutzerabbruch sowie
einen neuen Import vor Ablauf des alten Timers. Die schnellen Fälle verwenden
eine verkürzte Frist; `--default-timeout` misst zusätzlich die echte
Standardfrist. Der sichtbare Timeoutdialog wird gesondert im App-Bundle geprüft.
`bash tests/verify_gui_undo.sh` prüft echtes AppKit-Text-Undo und Kapitel-Undo
ohne sichtbare Fenster, einschließlich leerem Textverlauf, anderem aktivem
Fenster und Sperren während Import/Konvertierung. Menüeinbindung und
Tastenkürzel im laufenden App-Bundle benötigen zusätzlich eine GUI-Prüfung.

`bash tests/verify_document_open.sh` prüft den System-URL-Koordinator ohne
Fenster: mehrere Audioereignisse als ein vollständiger Import, Projektöffnung
im leeren Fenster, Bestätigung/Abbrechen vor Ersetzen, eine bereits aufgelöste
Alert-Bindung, defekte Projekte, gemischte Auswahl und laufenden Import.
Ein kontrolliert verzögerter Import prüft zusätzlich später eintreffende
System-URLs außerhalb der anfänglichen Sammelfrist.
Finder-/Launch-Services-Zuordnung und tatsächliche Alert-Bedienung benötigen
zusätzlich die Prüfung im App-Bundle.
`python3 tests/verify_terminal_renderer.py` prüft physische Statuszeilen an
PTYs mit 12/24/40/80 Spalten, Unicode, kleinem Fenster und Größenwechseln.
Die Anzeige reserviert die letzte Spalte gegen automatischen Umbruch und
begrenzt den Statusblock auf die sichtbare Höhe. Nach einem Größenwechsel
bleibt der vorige Status einmal stehen; der nächste Block beginnt darunter,
damit kein Cursor-Sprung mit veralteter Geometrie Logzeilen trifft.
Die CLI-Matrix erzeugt lange stille Testquellen für echte Stunden-Splits.
AAC-Toleranzen und gemessene Performance-Kapitelversätze stehen in encoding.md.

### Cover-Grenzen

`tests/verify_artwork.sh` erzeugt eigene MP3-/M4A- und PNG-Fixtures: 96 Millionen
Pixel, ein gültiges PNG mit 33 MiB Zusatzdaten, ungültige Bilder und ein späteres
gültiges Cover. Es prüft begrenzte Vorschau, unveränderte Exportbytes und den
Erhalt einer bestehenden Auswahl bei Fehlern.
Auch ein übergroßes erstes APIC-Bild mit anschließendem gültigem Cover wird
mit der echten ffmpeg-Extraktion geprüft. Getrennte Prozesse vergleichen
maximales RSS des alten NSImage-Skalierablaufs und der Thumbnail-Übernahme;
die Baseline lädt absichtlich das große Original. Der Vergleich misst weder
allgemeine Importleistung noch eine feste RSS-Obergrenze. Temporäre Fixtures
werden nach dem Lauf entfernt. Die gebündelte ffmpeg-Version muss vorhanden sein.
