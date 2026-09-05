# Ausbau- und Performance-Möglichkeiten

Stand: 2026-09-05. Die Funktionen der früheren Ideenliste wurden umgesetzt und
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
- Visuelle GUI-Abnahme und subjektive Hörprüfung sind von automatischer
  Kompilierung, Koordinationstests und vollständigem Dekodieren zu unterscheiden.

Die historische CodeQA-Abdeckung in `.codeqa/coverage.json` wird nicht als Prüfung
der neuen Funktionen ausgegeben. Neue/erweiterte Bereiche stehen dort zur
nächsten unabhängigen Prüfung an.
