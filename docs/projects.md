# Projekte und Kapitelbearbeitung

Eine `.hkproject` ist JSON mit `formatVersion: 1`. Sie enthält die geordnete
Liste der Abschnitte (Quellkennung, Start in Sekunden, Dauer, Titel), Metadaten,
Einstellungen und einen Cover-Snapshot. Audiodateien werden nicht kopiert.
Quellen innerhalb des Projektordners werden relativ referenziert; externe
Quellen erhalten absolute Dateipfade. Bei Dateisymlinks werden sichtbarer Name
und physischer Lesepfad getrennt gespeichert. Projekte mit externen Quellen
müssen auf anderen Rechnern dieselben externen Pfade vorfinden.

Die Quellenprüfung vergleicht SHA-256 über den vollständigen Dateiinhalt. Sie
meldet fehlende, unlesbare oder veränderte Quellen; GUI und CLI starten damit
keine Konvertierung. Beim erneuten Speichern bleiben die ursprünglichen
Fingerprints erhalten, damit Speichern eine veränderte Quelle nicht still
akzeptiert. Entfernte Kapitel können entfernt und die Quelle neu importiert
werden. Unbekannte Formatversionen werden abgewiesen, bevor die Session ersetzt
wird. Projektdateien sind auf 48 MiB und Coverdaten auf 32 MiB begrenzt.

„Projekt speichern …“ (Cmd+S) speichert den bearbeiteten Zustand.
„Projekt öffnen …“ (Cmd+Shift+O) öffnet ihn. Cmd+O bleibt der Audioimport.
Die Kapitelliste unterstützt Mehrfachauswahl und Nummerierung mit Präfix,
Umordnen per Listendrag oder Pfeilbuttons, Undo/Redo für Kapiteländerungen
(Cmd+Z/Cmd+Shift+Z), Teilen an der aktuellen Abspielposition und Zusammenführen
mit dem nächsten Abschnitt. Zusammenführen setzt dieselbe Quelle und lückenlos
anschließende Zeitabschnitte voraus; der erste Titel bleibt erhalten.
Nachimporte hängen neue, sortierte Kapitel an die vorhandene Reihenfolge an.
Das Schließen des Konvertierungsprotokolls erhält das bearbeitete Buch.

Die Kapitelhistorie umfasst höchstens 100 Schritte und wird beim Projektöffnen
geleert; sie ist nicht Bestandteil der Projektdatei. Die GUI liest Quellen
beim Öffnen und Speichern außerhalb des Main Actors. Vor dem Start prüft sie
unveränderte Datei-Snapshots ohne erneutes vollständiges Lesen. Das erstmalige
Hashen eines großen Buchs benötigt dennoch entsprechende Lesezeit.

## CLI

```sh
kloeppler --project Buch.hkproject --inspect --format json
kloeppler --file 02.wav --file 01.wav --inspect --format json
kloeppler --project Buch.hkproject --format json --output Buch.m4b
```

Genau eine Eingabeform ist erlaubt: ein Ordner, `--project` oder wiederholtes
`--file`. Explizite Optionen überschreiben Projekteinstellungen und Metadaten.
`--file` erhält die angegebene Folge; gemeinsame Importregeln deduplizieren
mehrfach referenzierte Quellen und erhalten deren interne Kapitelreihenfolge.

`--inspect` analysiert und plant, legt jedoch weder Ausgabeordner noch
Ausgabedateien an und bereinigt keine alten Temp-Ordner. Der JSON-Bericht enthält
`schemaVersion: 1`, Metadaten, Einstellungen, Dauer, Abschnitte, Quellenprobleme,
Coverstatus und tatsächliche Zielpfade. Fehlende/geänderte Projektquellen sind
im Bericht sichtbar und liefern Exit 1.

Bei einer Konvertierung erzeugt `--format json` JSON Lines: `started`,
`progress` und genau ein terminales `finished`, `failed` oder `cancelled`.
Jedes Ereignis enthält `schemaVersion: 1`, Phase, Gesamtfortschritt und
Ausgabepfade; terminale Ereignisse nennen tatsächlich erfolgreiche Dateien und
`success`. Diagnosen bleiben auf stderr. Ein früher Eingabe-/Projektfehler
liefert `failed`, auch wenn kein `started` vorausging. ArgumentParser meldet
Syntaxfehler weiterhin auf stderr. Exit-Codes bleiben unverändert.

Die GUI berechnet Quellenhashes beim Öffnen/Speichern außerhalb des Main Actors.
`ProjectFingerprintStore` bindet den wiederverwendeten Hash an Gerät, Inode,
Größe und Änderungszeiten; eine anschließend veränderte Quelle wird beim Start
ohne erneutes vollständiges Lesen abgewiesen. Der synchrone Core-/CLI-Einstieg
bleibt verfügbar.
