# Ausbau- und Performance-Möglichkeiten

Stand: 2026-09-10. Die Funktionen der früheren Ideenliste wurden umgesetzt und
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

- **`TerminalRenderer` zählt Blockzeilen logisch statt physisch** und liest die
  Terminalbreite nie (kein `TIOCGWINSZ`, kein `SIGWINCH`). In einem sehr schmalen
  Fenster belegt eine Pacman-Zeile zwei physische Zeilen, wird aber als eine
  gezählt; der nächste Redraw kann dann eine Logzeile überschreiben. Eine saubere
  Lösung braucht die Anzeigebreite inklusive Emoji — dabei das Rendering zu
  verschlechtern ist wahrscheinlicher als es zu verbessern.
  `tests/verify_cli_terminal.py` prüft das Endbild inzwischen maschinell und
  könnte um eine Schmalfenster-Variante erweitert werden.
- **`RunReport.phase` mischt zwei Vokabulare**: `session.conversionPhase` liefert
  deutsche UI-Beschriftungen („Bereit“, „Buchlautheit messen“), während die CLI
  daneben englische Maschinen-Token („input“, „preparing“) fest verdrahtet. Ein
  gescheiterter Lauf meldet als Phase „Bereit“. Ebenso fehlt `success` auf
  nicht-terminalen Zeilen, statt `null` zu sein. Beides zu vereinheitlichen ändert
  eine versionierte Schnittstelle und gehört mit einem `schemaVersion`-Sprung
  entschieden.
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
