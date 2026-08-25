# Ausbau- und Performance-Möglichkeiten

Stand: 2026-08-25. Diese Liste trennt Produktideen von bereits beauftragter
Implementierung. Prioritäten bewerten Nutzen und technische Anschlussfähigkeit;
sie sind keine Roadmap. Die bestehenden Verträge bleiben Leitplanken: gemeinsamer
Core für App und CLI, `aac_at` mit `cvbr`, atomare Ausgabe und kein öffentlicher
DMG-Vertrieb.

## Funktionen

### P1 — Konvertierungsplan als JSON ausgeben

`FFmpegWrapper.makeConversionPlan` berechnet bereits Gruppen, Split-Ziele und
Kollisionen für beide Frontends. Die CLI mischt dagegen Status, Logs und
Ergebnisdaten auf stdout. Ein `--inspect` oder `--dry-run --format json` könnte
ohne Schreibzugriff Quellkapitel, erkannte Metadaten, geplante Ziele,
Überschreibkonflikte und geschätzte Dauer ausgeben. Ein separater JSON-Eventstrom
für echte Läufe würde Fortschritt und Abschluss stabil maschinenlesbar machen.

Erfolgskriterium: versioniertes Schema, stdout enthält bei JSON-Ausgabe nur JSON,
Diagnosen gehen nach stderr; App und CLI verwenden denselben Plan-Snapshot.

### P1 — Projekte speichern und Kapitel gezielt bearbeiten

Die App erlaubt heute Kapiteltitel, Anhören und Löschen, sortiert Imports aber
automatisch; `ContentView` besitzt weder `.onMove` noch Split-/Merge-Aktionen. Ein
kleines Projektformat könnte Quellpfade, Reihenfolge, Zeitbereiche, Titel, Cover,
Metadaten und Einstellungen speichern. Darauf aufbauend lohnen sich:

- Kapitel per Drag-and-drop umordnen und mehrere Titel nach einem Muster umbenennen,
- ein Kapitel an der Abspielposition teilen,
- benachbarte Abschnitte derselben Quelle zusammenfassen,
- fehlende oder veränderte Quellen beim erneuten Öffnen sichtbar markieren.

Das Projektformat darf keine Audiodaten kopieren und muss relative Pfade sowie
eindeutige Hinweise für externe Quellen klar unterscheiden.

### P1 — Speicherplatz vor dem Start prüfen

Der Core summiert bereits Eingangsgrößen, prüft aber keinen freien Platz. Der
Standardmodus erzeugt zusätzlich unkomprimierte WAV-Segmente; auch der
Parallelmodus braucht Segmente, Staging-Ausgabe und bei Überschreiben kurzzeitig
die alte Datei. Ein Preflight sollte je betroffenem Volume konservativ schätzen
und vor dem Start Ziel- und Temp-Volume nennen. Bei unsicherer Schätzung warnt er,
statt einen sicheren Lauf fälschlich abzulehnen.

### P2 — Hörbuch-Metadaten erweitern

`ConversionSession` und `finalMuxArguments` schreiben derzeit Titel/Album, Autor
und Genre. Sinnvolle optionale Felder sind Sprecher, Reihe, Bandnummer,
Erscheinungsjahr, Sortiertitel, Sprache und Copyright. Import, GUI, CLI-Handoff
und M4B-Ausgabe brauchen dafür ein gemeinsames typisiertes Metadatenmodell; freie
ffmpeg-Schlüssel in der Oberfläche würden die beiden Frontends auseinanderziehen.

### P2 — Lautheit prüfen und optional angleichen

Eine Analyse kann Spitzenpegel und integrierte Lautheit pro Buch melden. Eine
optionale Angleichung sollte albumweit arbeiten, damit Kapitel nicht gegeneinander
springen. Für `loudnorm` wäre ein Analysepass plus Kodierpass nötig; deshalb muss
die UI zusätzliche Laufzeit anzeigen und die Funktion standardmäßig ausgeschaltet
bleiben. Abnahme: dokumentiertes Zielniveau, Clipping-Test und Hörvergleich an
Sprache, Musik und bereits normalisierten Quellen.

### P2 — Einzeldateien und explizite Reihenfolge im CLI

Die App nimmt Dateien und Ordner an, das CLI verlangt genau einen Ordner. Mehrere
Positionsargumente oder eine Manifestdatei würden gezielte Auswahl und Reihenfolge
ohne temporären Sammelordner ermöglichen. Das sollte auf demselben Projekt-/Plan-
Modell wie der Kapitel-Editor aufbauen und Symlink-, Deduplizierungs- und
Snapshot-Regeln nicht duplizieren.

## Performance

### P1 — Audioanalyse je Datei zusammenführen

Eine gewöhnliche Datei wird heute zuerst über `AudioFile.loadDurationAndTitle`
für Dauer und Titel und danach über `extractEmbeddedArtwork` mit einem zweiten
`AVAsset` erneut für Metadaten geöffnet. Der Ordnerscan hält die Ergebnisse zwar
geordnet, teilt aber keinen Analyse-Snapshot. Ein gemeinsames Ergebnis aus Dauer,
Titel und geprüftem Artwork könnte je physischer URL genau eine Metadatenladung
verwenden und zugleich die Datenmenge eingebetteter Cover früh sichtbar machen.

Vor der Zusammenlegung messen: 100 und 1.000 Dateien mit und ohne Artwork,
Anzahl der `AVAsset`-/Metadatenladungen, Gesamtdauer und Spitzen-RSS. Der Snapshot
muss an die beim Scan erfasste Dateiidentität gebunden sein; ein bloßer Pfadcache
darf nach einem Dateiaustausch keine alten Metadaten liefern.

### P1 — Ordneranalyse begrenzt parallelisieren

`ConversionSession.scanFolder` wartet in einer Schleife auf jede Audioanalyse,
bevor die nächste beginnt. Bei vielen kleinen Dateien dominiert dadurch die
Metadatenlatenz. Eine begrenzte Task-Gruppe kann Dauer, Titel und Kapitel parallel
laden; Ergebnisse werden erst danach in Finder-Reihenfolge zusammengesetzt.

Vor einer Änderung messen: derselbe Korpus mit 100, 1.000 und gemischten lokalen/
externen Dateien, Parallelität 1/2/4/8, jeweils Laufzeit, Spitzen-RSS und Anzahl
gleichzeitiger ffmpeg-Prozesse. Abbruch muss alle Tasks und Prozesse beenden.

### P1 — Artwork nur einmal je Import untersuchen

Bei nacheinander eintreffenden GUI-Providern startet `processIncomingFiles`
erneut eine Suche über die bis dahin vollständige Liste. Das kann bei N Providern
1+2+…+N Kandidatenzugriffe erzeugen. Die laufende CodeQA-Abdeckung führt dies als
`artwork-analysis-pipeline`: Provider zuerst sammeln, eine Suche nach `finishImport`
starten und alte Arbeit wirklich abbrechen. Messen: Zahl der Asset-Öffnungen und
Zeit bis `isPreparingArtwork == false` bei 100 Dateien mit und ohne eingebettetes
Cover.

### P2 — Parallelität an Rechner und Datenträger anpassen

`runParallelTasks` verwendet pauschal `activeProcessorCount - 1` ffmpeg-Prozesse.
Das kann auf Rechnern mit vielen Kernen RAM und langsame externe Laufwerke
überlasten. Ein automatisches Limit sollte CPU-Zahl, freien Speicher, Dateizahl
und gemessenen Durchsatz berücksichtigen; ein fortgeschrittener Nutzer kann es
begrenzen. Benchmark-Matrix: interne SSD und externes Laufwerk, 2/4/8/Auto Jobs,
Gesamtdauer, Spitzen-RSS, geschriebene Bytes und thermische Drosselung.

### P2 — Standardmodus ohne WAV-Zwischenablage untersuchen

Der Standardmodus dekodiert Kapitel zunächst parallel in WAV und liest sie für
einen einzigen AAC-Encode erneut. Ein einziger ffmpeg-Filtergraph könnte Quellen
trimmen und konkatenieren, ohne den unkomprimierten Zwischenbestand zu schreiben.
Das ist nur nach einem Output-Diff sinnvoll: Kapitelzeiten, Metadaten, lückenlose
Übergänge, Abbruchbereinigung und Audio-Prüfsummen eines lossless Referenzexports
müssen gleich bleiben. Besonders relevant ist der Vergleich auf langsamen oder
knappen Temp-Volumes.

### P3 — GUI-Log inkrementell darstellen

`ConversionOverlayView.buildLogAttributedString` baut bei jeder View-Auswertung
den formatierten Text aus allen `eventLogs` neu; gleichzeitig sortiert die View
den Fortschritts-Dictionary erneut. Der Core vermeidet die frühere quadratische
Neuberechnung von `logString` bereits, die Darstellung tut dies noch nicht. Erst
mit Instruments oder einem reproduzierbaren 10.000-Zeilen-Test belegen, dann den
formatierten Log-Snapshot beim Anhängen aktualisieren oder virtualisierte Zeilen
verwenden. Abnahme: identischer kopierbarer Text und flüssige Bedienung bei langen
Verbose-Läufen.

## Technische Voraussetzungen aus der laufenden QA

Einige Erweiterungen sollten erst nach den bereits erfassten Grenzen beginnen:
Audio-Track-Validierung, GUI-Importabbruch, Prozessbaum-Besitz,
descriptorgebundene Quell-/Zielordner und ein gemeinsamer abbrechbarer Runner für
MediaInfo. Der aktuelle Stand und die konkreten Belege liegen in
`.codeqa/coverage.json`; diese Datei ist die Fortsetzungsquelle, nicht diese
Ideenliste.
