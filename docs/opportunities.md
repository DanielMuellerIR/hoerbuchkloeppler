# Technische Grenzen und mögliche Folgearbeiten

- Der Performance-Modus verbindet getrennte AAC-Segmente. Die vom Encoder
  an den Segmenträndern hinzugefügten Samples (Priming und Padding) können
  Audioübergänge gegenüber geplanten Kapitelmarken verschieben. Standard
  eignet sich für durchgehende Musik und genaue Übergänge. Eine lückenlose
  Verbindung ohne erneute Kodierung bleibt zu untersuchen.
- Im Versuch mit einem gemeinsamen Filtergraphen ohne WAV wuchs die
  Speicherbelegung mit der Zahl gleichzeitig offener Quellen. Ein begrenztes
  Streamingverfahren wäre ein eigenes Experiment.
- Die synchrone Übernahme vieler importierter Einträge benötigt bei 1.000 kurzen
  Quellen noch rund 300 ms. Analyse und Artwork sind bereits begrenzt parallel.
- Die bisherigen Messungen verwenden lokale Testdateien im warmen Cache.
  Die [Langbuchmessung](long-book-measurement.md) ergänzt eine lokale Probe
  mit zwölf synthetischen Stunden und beschreibt einen geplanten
  Streaming-Versuch. Langbücher auf langsamen externen Datenträgern und
  thermische Drosselung brauchen eigene Messreihen.
- Die Lautheitsangleichung ändert den Pegel des gesamten Buchs um denselben
  Wert. Die Dynamik bleibt erhalten. Die Spitzenbegrenzung kann das Ziel
  von −18 LUFS verhindern.
- Die Übernahme eingebetteter Cover ist auf 32 MiB pro Bildpaket begrenzt.
  AVFoundation kann bei der Metadatenanalyse eigene Containerpuffer anlegen.
- Die subjektive Hörprüfung steht aus. Die bisherigen GUI- und Dekodiertests
  sind unter [Bauen und Testen](build-and-test.md) dokumentiert.
