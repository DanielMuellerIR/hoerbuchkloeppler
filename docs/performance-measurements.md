# Importmessung und Encodingexperiment 2026-09-05

Messung lokal unter macOS auf Apple M5. ffmpeg 9.0.1 (Homebrew), `aac_at` mit `cvbr`. Keine GUI geöffnet. Drei Wiederholungen, wenn nicht anders angegeben; Zeit als Median, RSS als höchster gemessener Wert. Keine geleerten Dateisystem-Caches, keine kalten Laufwerke oder Netzlaufwerke. Messergebnisse gelten für kurze, lokal gespeicherte Testdateien.

## Import-Baseline

Die bereits vorhandene CLI wurde vor Änderungen kopiert (SHA256 `ceee1bcff0cc646c2c64ccce878461d8d6699807cc9dc76317e811f7e507257c`). Jeder Eingang ist eine eigene reguläre Datei mit eigenem Inode, keine Hardlinks. WAV: 0,25 Sekunden Sinuston, 48 kHz. M4A: derselbe Inhalt, `aac_at/cvbr`, 64 kbit/s und eingebettetes 256×256-JPEG. Die CLI importiert vollständig und stoppt anschließend mit erwarteter Exit 1 an einem ungültigen `--output`-Wert ohne Dateiendung. Damit wird keine Konvertierung gestartet und keine Ausgabedatei angelegt. Die Laufzeit enthält Prozessstart, Import und abschließende Zielvalidierung, ist daher keine reine Analysezeit.

| Quellen | Artworksuche | Sekunden | RSS MiB |
| --- | --- | ---: | ---: |
| WAV 100 | aus | 0,3983 | 59,06 |
| WAV 100 | an | 0,4243 | 59,23 |
| WAV 1000 | aus | 1,2093 | 76,44 |
| WAV 1000 | an | 1,4096 | 76,34 |
| M4A 100 | aus | 0,3835 | 59,41 |
| M4A 100 | an | 0,3846 | 61,27 |
| M4A 1000 | aus | 1,2054 | 75,69 |
| M4A 1000 | an | 1,2203 | 77,52 |

RSS: `/usr/bin/time -l`, Bytes in MiB umgerechnet. Audioanalyse benutzt AVFoundation, deshalb entsprechen externe Prozessstarts keiner sinnvollen Gesamtzahl der Analyseaufrufe.

Abbruch während Import: SIGINT 0,5 s nach Prozessstart bei 1000 Quellen, je Format fünf Wiederholungen. Alle zehn Läufe endeten geordnet mit Exit 130. WAV: 2,66–4,63 ms bis Prozessende, Median 3,01 ms. M4A: 2,97–3,20 ms, Median 3,08 ms. Ein Vorversuch bei 0,15 s traf vor Einrichtung des Signalhandlers und endete durch Signal 2; diese Werte gelten ausdrücklich nicht als geordneter Importabbruch.

## Begrenzte Analyseparallelität

Ein eigener Swift-Harness ruft die bestehende öffentliche `loadAudioFiles(from:)`-Methode einmal pro Quelle auf. Er benutzt 1/2/4/8 Tasks und prüft die Zahl erfolgreich geladener Dateien. Discovery, Dublettenerkennung, Artworksuche, Metadatenwahl und Übernahme ins Projekt sind hier nicht enthalten. Gemessen wurden exakt 100 bzw. 1000 Methodenaufrufe und ebenso viele erfolgreiche Ergebnisse. Interne AVFoundation-Aufrufe wurden nicht instrumentiert; die Ausgangsimplementierung lädt Audiotracks, Dauer und Metadaten separat. Daraus keine gemessene interne Aufrufzahl ableiten.

| Quellen | 1 Task s / MiB | 2 Tasks s / MiB | 4 Tasks s / MiB | 8 Tasks s / MiB |
| --- | ---: | ---: | ---: | ---: |
| WAV 100 | 0,0670 / 17,31 | 0,0469 / 17,59 | 0,0390 / 18,12 | 0,0399 / 18,94 |
| WAV 1000 | 0,6068 / 18,19 | 0,3965 / 18,59 | 0,3047 / 19,23 | 0,2925 / 20,16 |
| M4A 100 | 0,0613 / 17,02 | 0,0507 / 17,39 | 0,0382 / 17,75 | 0,0366 / 18,44 |
| M4A 1000 | 0,6170 / 17,97 | 0,3929 / 18,42 | 0,3383 / 18,94 | 0,3154 / 19,86 |

Empfehlung: vier Analyse-Tasks als Default. Acht bringen bei 1000 Quellen nur noch etwa 4–7 Prozent, benötigen dabei mehr Speicher. Der Harness beweist den Performanceeffekt, nicht die deterministische Ergebnisreihenfolge einer späteren Integration: dafür Ergebnisse anhand des Eingangsindex ablegen und gesondert testen.

## Encoding ohne WAV

Sechs Abschnitte mit zusammen 88,006 Sekunden Planlänge aus drei Quellen: lokale synthetisierte deutsche Sprache als 44,1-kHz-Mono-WAV, deterministischer Dreiklang als 48-kHz-Stereo-FLAC und per `loudnorm` normalisierte Sprache als AAC-M4A. Schnittpositionen und Abschnittslängen sind absichtlich keine ganzen Sekunden. Beide Verfahren benutzen dieselben Input-Optionen `-ss`/`-t`, 48 kHz Stereo, `aac_at -aac_at_mode cvbr -b:a 96k`.

Standard-Vergleichsrezept (Slices seriell, nicht die parallelisierte Produktionspipeline): jeden Abschnitt als `pcm_s16le`-WAV schreiben, dann concat-Demuxer und einmal AAC-Encoding. Experiment: pro Input `aresample=48000,aformat=sample_fmts=s16:channel_layouts=stereo,asetpts=PTS-STARTPTS`, dann concat-Filter und einmal AAC-Encoding. Die explizite 16-Bit-Quantisierung entspricht der bestehenden WAV-Stufe.

| Verfahren | Zeit Median | WAV-Zwischenbestand |
| --- | ---: | ---: |
| Standard | 0,6931 s | 16.895.132 Bytes |
| Filtergraph | 0,4335 s | 0 Bytes |

Filtergraph rund 37 Prozent schneller als dieses serielle Vergleichsrezept; daraus folgt kein gemessener Geschwindigkeitsvorteil gegenüber der parallelisierten Produktionspipeline. Beide Ergebnisse wurden in jedem der drei Läufe vollständig zu 16-Bit-PCM dekodiert: byteidentisch, maximale Abweichung 0, RMS-Abweichung 0. Alle fünf Übergänge wurden zusätzlich in Fenstern von ±0,1 s verglichen, ebenfalls ohne Abweichung. Dekodierte Dauer jeweils 88,000 s: 6 ms kürzer als die Planlänge und damit innerhalb eines AAC-Frames bei 48 kHz (21,33 ms). Dieses Experiment prüft Audio, keine Kapitel-Metadaten, Cover, Split-, Fehler- oder Abbruchintegration.

Zusätzliche Skalierungsprobe (je ein Lauf) mit 100/1000 WAV-Inputs à 0,25 s im selben Filtergraph: 0,244 s / 53,23 MiB bzw. 2,400 s / 329,22 MiB. Der Standard-Gegenlauf für 1000 Dateien benötigte 25,100 s, 23,81 MiB RSS und 48.078.000 Bytes WAV-Zwischenbestand (ein Lauf). Vollständig dekodierte Audio-MD5 beider Ausgaben identisch: `55927279b7a65499a1f2c530556c6582`. Der Prozess des Filtergraphen hält alle Quellen gleichzeitig offen; die aktuelle hohe Descriptor-Grenze wurde nicht verändert. Speicher und offene Dateien wachsen mit der Kapitelzahl.

Entscheidung: noch nicht in den Produktionspfad übernehmen. Der kleine Audiovergleich belegt einen Nutzen und korrekte Samples; der einzelne große Graph ersetzt jedoch begrenzte Worker durch gleichzeitig offene Eingänge und zeigt bereits bei 1000 Mini-Dateien rund 329 MiB RSS. Für einen allgemeinen Ersatz fehlen ein begrenztes Streamingverfahren und Prüfungen langer heterogener Bücher einschließlich Prozessbesitz, Abbruch, Split, Cover und atomarer Ausgabe. Der bestehende Standardpfad bleibt erhalten.

## Reproduktion

`python3 tests/experiments/encoding_without_wav.py` erzeugt Sprach-, Musik- und
normalisierte Fixtures in einem neuen temporären Ordner und vergleicht beide
Verfahren dreimal vollständig dekodiert. `FFMPEG` kann das Werkzeug festlegen.
Die Messung verwendet macOS wegen `aac_at` und lokaler Sprachausgabe (`say -o`).
Rohwerte werden als `results.json` im ausgegebenen Messordner abgelegt.
Die Import-Baseline und die Skalierungsproben wurden separat gemessen; das
beigefügte Skript reproduziert den Vergleich mit sechs Abschnitten.

## Importdienst nach Zusammenlegung

`AudioImportService` bündelt Tracks, Dauer und Metadaten; die anschließende
Sprachabfrage und Artwork-Datenanforderungen werden separat gezählt.
Datei-Drops und Auswahl sammeln Provider vor der begrenzten Analyse.

## CLI-Vorher/Nachher

Gleiche Fixtures und Messmethode wie die Baseline oben: je drei Läufe, Median Sekunden; RSS höchster Einzelwert. Zeit umfasst CLI-Start/Import/Zielvalidierung.

| Quellen | Artwork | Vorher s | Nachher s | Änderung | Nachher RSS MiB |
| --- | --- | ---: | ---: | ---: | ---: |
| WAV 100 | aus | 0.3983 | 0.3484 | -12.5% | 60.50 |
| WAV 100 | an | 0.4243 | 0.3500 | -17.5% | 60.75 |
| WAV 1000 | aus | 1.2093 | 0.8341 | -31.0% | 78.19 |
| WAV 1000 | an | 1.4096 | 0.8663 | -38.5% | 80.50 |
| M4A 100 | aus | 0.3835 | 0.3513 | -8.4% | 60.86 |
| M4A 100 | an | 0.3846 | 0.3412 | -11.3% | 62.55 |
| M4A 1000 | aus | 1.2054 | 0.8644 | -28.3% | 78.78 |
| M4A 1000 | an | 1.2203 | 0.9026 | -26.0% | 80.56 |

## Instrumentierter Ordnerscan nach Änderung

Zeiten enthalten Dateisuche, Analyse und Coversuche, ohne CLI-Start. Zähler messen tatsächlich ausgeführte AVAsset-Anforderungen und Artwork-Datenanforderungen. Ein Asset-Aufruf lädt drei Eigenschaften. Property-interne Betriebssystemarbeit und String-Tagwerte werden nicht als eigene Asset-Aufrufe gezählt.

| Quellen | 1 Task s | 2 Tasks s | 4 Tasks s | 8 Tasks s | Asset-Aufrufe | Artwork-Datenaufrufe |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| WAV 100 | 0.0579 | 0.0356 | 0.0300 | 0.0301 | 100 | 0 |
| WAV 1000 | 0.5156 | 0.2787 | 0.2163 | 0.2245 | 1000 | 0 |
| M4A 100 | 0.0626 | 0.0421 | 0.0337 | 0.0321 | 100 | 1 |
| M4A 1000 | 0.5128 | 0.2900 | 0.2141 | 0.2091 | 1000 | 1 |

Ohne Artworksuche: in sämtlichen 48 Läufen null Artwork-Datenanforderungen. M4B-Gegenprobe mit zwei echten Kapiteln und Cover: ein Asset-Aufruf, ein ffmpeg-Kapitelprozess, ein Artwork-Datenaufruf; zwei Kapitel, keine Fehler.

## Abbruch nach Änderung

WAV1000: fünf Läufe, Exit-Codes [130, 130, 130, 130, 130], 288.97–370.16 ms bis Prozessende, Median 298.18 ms. SIGINT jeweils 0,5 s nach Start.

M4A1000: fünf Läufe, Exit-Codes [130, 130, 130, 130, 130], 289.06–331.91 ms bis Prozessende, Median 298.98 ms. SIGINT jeweils 0,5 s nach Start.

Grenzen: lokale kurze Dateien, warme Dateisystem-Caches, keine Netzlaufwerke. Lazy Metadaten-Snapshots erhöhen den Peak-RSS geringfügig, vermeiden dafür erneute Asset- und Artworkanalysen. Cache wird bei leerem Buch und neuem CLI-Vorbereitungslauf gelöscht; neue GUI-Imports behalten nur Metadaten bestehender Buchquellen.

Reproduktion im gleichen temporären Ordner: `after.py`, `Scan.swift`, `cancel-after.py`; Rohwerte `after.json`, `scan-after.json`, `cancel-after.json`. Baseline und Encodingexperiment bleiben in `REPORT.md`.

## Metadaten-Roundtrip

Zusätzlich `metadata(for: url)` mit den kanonischen Keys `narrator`, `series`, `volume_number`, `language`. Custom-Tags und native MP4-Aliase: composer (`itsk/%A9wrt`), grouping (`itsk/%A9grp`), binäre disc-Nummer (`itsk/disk`). Audiotrack-Sprache wird gemeinsam über `.languageCode`/`.extendedLanguageTag` angefragt; neuer Zähler `trackLanguageRequests`, bei den Fixtures genau eine Anfrage pro Quelle. Dadurch bleibt die Assetanalyse gebündelt, die abhängige Trackabfrage wird separat und ehrlich gezählt.

Echte Datei `native-tag-fixture/native.m4b` unter dem Messordner: Cover erhalten; Reimport liefert `narrator=Ada Beispiel`, `series=Die Testreihe`, `volume_number=3`, `language=deu`. Ein Assetload, ein Sprachload, ein Kapitelprozess, ein Artworkload. Die alternative use_metadata_tags-Datei wird als Gegenprobe aufbewahrt: AVFoundation findet darin weder diese Tags noch Cover.

## Abbruch innerhalb der eigentlichen Analyse

Der feste 0,5-s-Zeitpunkt trifft nach der Beschleunigung bereits die synchrone Buchübernahme (`processIncomingFiles`, Log „Importiere 1000 Audiodateien“). Ein Zusatzversuch bei 0,3 s traf in zwei von zehn Läufen noch vor Installation des Signalhandlers (Exit durch Signal2), bei den übrigen Läufen betrug die Abbruchdauer 2,77–5,75 ms. Diese Zeitpunkte messen unterschiedliche Phasen und sind nicht direkt vergleichbar.

Ein zusätzlicher Core-Harness `Cancel.swift` wartet deshalb auf mindestens 100 tatsächlich begonnene Analysen und ruft dann cancelPreparation auf. Alle zehn Abbrüche akzeptiert; bestehendes leeres Buch blieb leer:

WAV1000: 1.29–1.46 ms, Median 1.40 ms. Quellenzahlen vor/nach Abbruch: [(104, 104), (107, 107), (107, 107), (108, 108), (101, 101)].

M4A1000: 1.33–1.76 ms, Median 1.62 ms. Quellenzahlen vor/nach Abbruch: [(109, 109), (110, 110), (111, 111), (110, 110), (104, 104)].
