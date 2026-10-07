# Ausbau- und Performance-Möglichkeiten

Stand: 2026-10-07. Die Funktionen der früheren Ideenliste wurden umgesetzt und
in die Fachdokumentation übernommen:

- Importauswahl, Fortschritt und Abbruch: [build-and-test.md](build-and-test.md).
- Projektformat, Kapitelbearbeitung und JSON-CLI: [projects.md](projects.md).
- Ausgabevorschau, Qualitätsprofile und begrenzte Prozesse: [settings.md](settings.md).
- Metadaten, Buchlautheit und AAC-Übergangsgrenzen: [encoding.md](encoding.md).
- Importmessungen und Experiment ohne WAV: [performance-measurements.md](performance-measurements.md).

GUI-Drops bündeln die Cover-Suche bereits; `LogTranscriptView` vermeidet den
Textneubau bei bloßen Fortschrittsupdates. Beides ist keine offene Optimierung.

## Verbleibende Grenzen und mögliche Folgearbeiten

- Der Performance-Modus verbindet getrennte AAC-Encodes. Priming und Padding
  verschieben Audioübergänge gegenüber geplanten Kapitelmarken; Standard bleibt
  die Wahl für durchgehende Musik und genaue Übergänge. Eine lückenlose Verbindung
  ohne erneutes Encoding ist gesondert zu untersuchen.
- Ein einzelner Filtergraph ohne WAV wurde wegen wachsender Speicherbelegung und
  gleichzeitig offener Quellen nicht übernommen. Ein begrenztes Streamingverfahren
  wäre ein eigenes Experiment.
- Die synchrone Übernahme vieler importierter Einträge benötigt bei 1.000 kurzen
  Quellen noch rund 300 ms. Analyse und Artwork sind bereits begrenzt parallel.
- Die bisherigen Messungen verwenden lokale, warme Testdateien. Langbücher,
  langsame externe Datenträger und thermische Drosselung bleiben gesonderte
  Messreihen; die Ergebnisse erlauben keine entsprechende Leistungszusage.
- Lautheitsangleichung verwendet einen gemeinsamen linearen Pegel. Die
  Spitzenbegrenzung kann das Ziel −18 LUFS verhindern; Dynamik wird erhalten.
- ⌘Z/⇧⌘Z liegen als `keyboardShortcut` auf den Toolbar-Buttons „Rückgängig“/
  „Wiederholen“, während das SwiftUI-Standardmenü „Bearbeiten“ dieselben Tasten
  für den Text-Undo belegt. Mit Fokus in einem Textfeld gewinnt das Feld; das
  Verhalten ohne Fokus ist nicht dokumentiert. Sauber wäre
  `CommandGroup(replacing: .undoRedo)` in `.commands` der `WindowGroup`, was den
  Session-Zugriff aus der App-Struktur erfordert (Review 2026-09-06, offen).
- Visuelle GUI-Abnahme und subjektive Hörprüfung sind von automatischer
  Kompilierung, Koordinationstests und vollständigem Dekodieren zu unterscheiden.

### Aus der CodeQA-Kampagne 2026-09-10 bewusst offen gelassen

Jeder Punkt ist am Code belegt, aber keiner ließ sich ohne eigenen Auftrag oder
ohne unverhältnismäßiges Risiko im Rahmen der Kampagne erledigen.

- **Terminal-Neuzeichnung korrigiert (2026-10-07):** `TerminalRenderer` bricht
  Statuszeilen anhand der Terminalbreite und Unicode-Anzeigebreite um; Höhe und
  Größenwechsel werden berücksichtigt. Echte PTY-Gegenproben belegen den
  früheren Statusrest bei zwölf Spalten und dessen Korrektur. Logzeilen bleiben
  bei 12/24/40/80 Spalten erhalten. Nach Resize bleibt der alte Status bewusst
  einmal stehen. Details und Reproduktion: [build-and-test.md](build-and-test.md).
- **Laufbericht-Schema 2 (2026-10-07):** typisierte, sprachunabhängige Phasen
  und Ereignisse; `success` ist auch während des Laufs vorhanden (`null`). Bei
  Fehlern bleibt der letzte Arbeitsschritt erhalten. Projekt- und Inspect-
  Formate bleiben unabhängig bei Version 1. Vertrag: [projects.md](projects.md).
- **`info.plist` deklariert keine Dokumententypen.** Weder `.hkproject` noch die
  unterstützten Audioendungen sind eingetragen, und die App hat kein `onOpenURL`.
  Ein Doppelklick auf eine Projektdatei im Finder öffnet die App deshalb nicht,
  und sie taucht in keinem „Öffnen mit“-Menü auf. Ebenso fehlen
  `NSDesktopFolderUsageDescription` und `NSRemovableVolumesUsageDescription` — der
  häufigste Fall (Audioordner vom Schreibtisch) bekommt die TCC-Abfrage ohne
  Begründungstext.
- **Ein NSItemProvider, der nie antwortet, lässt den Import unbefristet stehen.**
  `ImportCoordinator.importProviders` hat weder Frist noch Rückfall; „Hörbuch
  erzeugen“ und „Projekt speichern“ bleiben gesperrt. Erholung nur über „Import
  abbrechen“. Eine Frist ist eine Produktentscheidung: zu kurz verwirft echte
  Drops von langsamen Volumes.
- **Kapitelanalyse blockiert einen Thread des Cooperative Pools.**
  `readFFMetadata` und `waitForProcessExit` laufen synchron im Rumpf einer
  `async`-Funktion, bis zu 30 s je Datei und bis zu `importWorkerLimit`
  gleichzeitig. `ProcessPipeReader` macht dieselbe Schleife bewusst auf einer
  eigenen Queue; die Kapitelextraktion sollte ihm folgen.
- **Die 32-MiB-Grenze für eingebettetes Artwork greift erst nach dem vollständigen
  Laden** (`item.load(.dataValue)`), und ein sehr großes PNG muss zum Erzeugen der
  32-px-Vorschau ganz dekodiert werden.
- **`test_scripts.sh` führt weiterhin keines der Build-, Installations- oder
  Release-Skripte aus.** Seit 1.4.16 prüft es alle sieben auf Syntax; die
  Beenden-und-Ersetzen-Sequenz von `install.sh`, die DMG- und
  Notarisierungskette von `release.sh` und die Innen-nach-außen-Reihenfolge von
  `sign-bundle.sh` bleiben ungetestet.

Die historische CodeQA-Abdeckung in `.codeqa/coverage.json` wird nicht als Prüfung
der neuen Funktionen ausgegeben. Neue/erweiterte Bereiche stehen dort zur
nächsten unabhängigen Prüfung an.
