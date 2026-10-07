# Begrenzte Langbuchmessung 2026-10-07

Zwölf synthetische FLAC-Dateien mit je einer Stunde Sinuston (220 Hz, 32 kHz,
Mono), zusammen zwölf Stunden und 400.417.344 Bytes Eingangsdaten. Jede Quelle
ist eine eigene reguläre Datei. Beide vorhandenen Modi wurden mit vier Encoding-
und vier Import-Workern, 32 kHz, Mono, 48 kbit/s, `aac_at/cvbr`, ohne Split,
Cover oder Lautheitsanalyse ausgeführt. Die Kodierpipeline wurde nicht geändert.

Umgebung: Apple M5, macOS 26.7.1, Release-CLI aus Commit
`d01ceabc2e0e9f971015e2ff24ffc933d0924e9b`, gebündeltes ffmpeg 8.1.2-tessus
(x86_64, auf diesem Mac über Rosetta). CLI-SHA256:
`c8a9d59564a599a7664d8ffb625c1e9c4a2a541771db9b767aca8dfd945705f0`.

Je ein gültiger Lauf, Reihenfolge Standard → Parallel, lokale SSD, keine
geleerten Dateisystem-Caches und keine parallel laufende Testsuite. Die Laufzeit
enthält CLI-Start, Import, Konvertierung und Ausgabeprüfung der CLI, jedoch nicht
die anschließende unabhängige Dekodierung. Der Beobachter fragt nominell alle
250 ms ab; seine Arbeit verlängert das tatsächliche Intervall. Die Werte sind
ein begrenzter Ausgangspunkt, kein allgemeiner Geschwindigkeitsvergleich.

| Messgröße | Standard | Parallel |
| --- | ---: | ---: |
| Laufzeit | 68,66 s | 31,94 s |
| Höchster abgetasteter CLI-RSS | 38,98 MiB | 38,67 MiB |
| Höchste abgetastete RSS-Summe des Prozessbaums | 154,04 MiB | 201,70 MiB |
| Höchste beobachtete Prozesszahl inklusive CLI | 5 | 5 |
| Temporäre Audiodaten, logische Größe | 2636,72 MiB | 205,06 MiB |
| Temporäre Audiodaten, belegte Blöcke | 2702,26 MiB | 215,81 MiB |
| Temp + Ausgabe-Staging, logische Größe | 2736,27 MiB | 402,56 MiB |
| Temp + Ausgabe-Staging, belegte Blöcke | 2814,27 MiB | 423,82 MiB |
| Fertige M4B-Datei | 99,54 MiB | 205,05 MiB |

RSS ist die Summe der beobachteten Prozesse, keine Messung ausschließlich
physisch belegter RAM-Seiten: Gemeinsame Seiten können mehrfach enthalten sein,
kurze Spitzen zwischen Abfragen fehlen. Plattenwerte stammen aus `st_size` und
`st_blocks × 512`; Quell- und fertige Ausgabedateien sind nicht im Temp-Wert
enthalten. Die kombinierte Zeile misst beide temporären Bestände zum selben
Zeitpunkt, statt voneinander unabhängige Maxima zu addieren.

Die erwartete PCM-Nutzlast im Standardmodus beträgt
`43.200 s × 32.000 Samples/s × 2 Bytes = 2.764.800.000 Bytes`.
Der beobachtete logische Temp-Höchstwert beträgt 2.764.803.128 Bytes einschließlich
WAV-Headern und kleinen Verwaltungsdateien. Der WAV-Zwischenbestand erklärt hier
den größten Plattenbedarf. Die deutlich verschiedenen AAC-Dateigrößen zeigen
zugleich, warum sich aus diesem tonalen Fixture weder gleiche Audioqualität noch
ein allgemeiner Geschwindigkeitsvorteil für Sprachbücher ableiten lässt.

Beide Ergebnisse wurden über die CLI erneut importiert: zwölf Kapitel in der
richtigen Reihenfolge, Titel sowie Start- und Dauerwerte geprüft. Beide Dateien
wurden vollständig mit ffmpeg und Fehlerabbruch dekodiert. Die dekodierte
Zeitleiste beträgt bei beiden 43.200,030 Sekunden und wurde zusätzlich gegen
zwölf Stunden mit einer Grenze von vierzehn AAC-Rahmen geprüft. Alle tatsächlich beobachteten eigenen Audio-Arbeitsordner
verschwanden nach Erfolg; neben dem Ergebnis bleibt nur die absichtlich
persistente, leere Ausgabesperrdatei.

## Reproduktion und Messgrenzen

```bash
swift build --package-path HoerbuchkloepplerCore -c release -Xswiftc -warnings-as-errors
PYTHONDONTWRITEBYTECODE=1 python3 tests/experiments/measure_long_book.py
```

Das Skript nennt seinen neuen Messordner und speichert Rohwerte, tatsächliche
Abfragezeitpunkte, CLI-Ereignisse und Ergebnisprüfungen. Es begrenzt jeden Lauf auf
15 Minuten und vier GiB temporäre Daten; bei einem Grenzfehler wird der eigene
CLI-Lauf abgebrochen. Für die Messung andere rechenintensive Arbeit pausieren.
Aufbewahrung und Entfernung des genannten Messordners liegen beim Aufrufer.

Foundation ignoriert auf diesem macOS ein gesetztes `TMPDIR`. Der Beobachter
sucht deshalb im tatsächlichen System-Temp-Verzeichnis und berücksichtigt nur
Arbeitsordner mit der passenden `.owner-pid`. Ein Vorversuch mit dem falschen
Temp-Pfad und ein Lauf mit gleichzeitiger Testlast sind verworfen; sie gehen
nicht in die Tabelle ein. Die CLI-Matrix benutzt dieselbe Besitzerzuordnung und
verlangt vor einem Signal einen wirklich beobachteten Arbeitsordner.

Offen bleiben heterogene Sprachquellen, viele kurze Kapitel, Cover,
Lautheitsanalyse, Split, externe Laufwerke, kalte Caches und längere thermische
Last. Diese Messung begründet keine Änderung der Standardeinstellungen.

## Kleinster nächster Versuch

Der belegte Ansatzpunkt ist das Speichern aller Standard-WAV-Segmente vor dem
einzigen AAC-Encode. Ein gesonderter, höchstens vierstündiger Versuch kann die
Quellen nacheinander in gleich formatiertes 16-Bit-PCM dekodieren und über einen
begrenzten Stream an genau einen AAC-Encoder liefern. Damit bleiben gleichzeitig
offene Quellen begrenzt; ein Graph mit sämtlichen Buchquellen wird vermieden.

Der Versuch gehört zunächst ausschließlich in ein Experiment. Die
Produktintegration benötigt eine eigene Entscheidung. Konkrete Kriterien:

- Die PCM-Folge entspricht dem Standard-WAV-Rezept, einschließlich identischer
  Quantisierung, Abschnittsgrenzen und Reihenfolge. Zuerst kurze heterogene
  Quellen vergleichen, danach das Langbuch.
- Temp einschließlich Ausgabe-Staging höchstens zehn Prozent dieser
  Standard-Baseline; RSS-Summe nicht mehr als 25 Prozent über der Baseline.
- Drei getrennte Zeitmessungen je Verfahren; eine behauptete Beschleunigung
  benötigt mindestens 15 Prozent beim Median. Plattenersparnis und Laufzeit
  getrennt bewerten.
- Abbruch vor dem Start, beim Schreiben und während des Encodes, Werkzeugfehler
  und volle Ausgabe müssen alle eigenen Prozesse und Arbeitsdaten aufräumen.
- Vor Produktintegration den bestehenden Besitzvertrag der Ausgabe erhalten:
  Der finale Prozess hält seinen geschützten Ausgabedeskriptor derzeit als
  `stdin` offen. Ein PCM-Eingang darf diesen Deskriptor nicht verdrängen.

Ohne bestandene Audio-, Ressourcen- und Abbruchprüfung endet der Versuch mit
einem dokumentierten Ergebnis. Die bestehende Pipeline bleibt bis zu einer
gesondert geprüften Integration erhalten.
