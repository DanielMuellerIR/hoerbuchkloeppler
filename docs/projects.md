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
Auch Finder beziehungsweise „Öffnen mit“ können Projekte und unterstützte
Audiodateien an die App übergeben. Audiodateien werden gemeinsam importiert.
Ein Projekt öffnet sich im leeren Fenster direkt; ein vorhandenes Hörbuch wird
erst nach Bestätigung ersetzt. Während Import oder Konvertierung wird eine neue
Systemöffnung mit einer sichtbaren Meldung abgewiesen. Die App registriert sich
für Audio als alternative Anwendung und übernimmt keinen Standardplayer.

Der eigene Projekttyp folgt Apples
[UTI-Deklaration für Dateitypen](https://developer.apple.com/documentation/uniformtypeidentifiers/defining-file-and-data-types-for-your-app).
Die Kapitelliste unterstützt Mehrfachauswahl und Nummerierung mit Präfix,
Umordnen per Listendrag oder Pfeilbuttons, Undo/Redo für Kapiteländerungen
(Cmd+Z/Cmd+Shift+Z), Teilen an der aktuellen Abspielposition und Zusammenführen
mit dem nächsten Abschnitt. Zusammenführen setzt dieselbe Quelle und lückenlos
anschließende Zeitabschnitte voraus; der erste Titel bleibt erhalten.
Nachimporte hängen neue, sortierte Kapitel an die vorhandene Reihenfolge an.
Das Schließen des Konvertierungsprotokolls erhält das bearbeitete Buch.

Menü, Tastenkürzel und Toolbar verwenden dieselbe Undo-Zuständigkeit: In einem
bearbeitbaren Textfeld wird dessen Text zurückgenommen oder wiederholt. Ein
leerer Textverlauf greift nicht auf Kapiteländerungen zurück. Außerhalb eines
Textfelds gilt der Kapitelverlauf des aktiven Projektfensters; während Import,
Konvertierung oder eines offenen Sheets bleibt dieser gesperrt.

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
Jedes Ereignis enthält `schemaVersion: 2`, Phase, Gesamtfortschritt,
Ausgabepfade und `success`. Für `started` und `progress` ist `success: null`,
für `finished` ist es `true`, für `failed` und `cancelled` ist es `false`.
Terminale Ereignisse nennen ausschließlich tatsächlich erfolgreiche Dateien.
Diagnosen bleiben auf stderr. Ein früher Eingabe-/Projektfehler
liefert `failed`, auch wenn kein `started` vorausging. ArgumentParser meldet
Syntaxfehler weiterhin auf stderr. Exit-Codes bleiben unverändert.

`phase` ist sprachunabhängig und beschreibt den letzten Arbeitsschritt:

| Wert | Arbeitsschritt |
| --- | --- |
| `input` | Eingaben laden und prüfen |
| `preparing` | Konvertierung vorbereiten |
| `measuring_loudness` | Buchlautheit messen |
| `decoding` | Audio in WAV-Zwischenstände dekodieren |
| `encoding` | AAC kodieren |
| `muxing` | Kodiertes Audio, Kapitel und Cover zusammenbauen |

Auch nach einem Fehler oder Abbruch bleibt der letzte Arbeitsschritt erhalten;
das Ergebnis steht in `event` und `success`. Die deutschen UI-Beschriftungen
werden nicht als Maschinenwerte verwendet. Schema 2 ersetzt das frühere
Laufbericht-Schema 1; Projektformat und Inspect-Bericht bleiben bei Version 1.

Die GUI berechnet Quellenhashes beim Öffnen/Speichern außerhalb des Main Actors.
`ProjectFingerprintStore` bindet den wiederverwendeten Hash an Gerät, Inode,
Größe und Änderungszeiten; eine anschließend veränderte Quelle wird beim Start
ohne erneutes vollständiges Lesen abgewiesen. Der synchrone Core-/CLI-Einstieg
bleibt verfügbar.
