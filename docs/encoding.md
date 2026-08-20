# Kodierung & Muxing

Alle Argumente werden in `FFmpegWrapper.swift` gebaut.

## Zwei Verarbeitungs-Modi

Schalter: `AudioSettings.useParallelEncoding` (`true` = Parallel/Performance).

### Standard-Modus — `performSequentialConversion`

1. Jedes Kapitel **parallel** in unkomprimiertes `.wav` slicen (`pcm_s16le`,
   **Ziel-Abtastrate UND Ziel-Kanalzahl** aus den Settings) — `getArgsForStandardSlicing`.
   (Slicing auf die Ziel-Rate statt hart 44100 vermeidet einen doppelten Resample
   beim finalen Encode; Slicing auf die Ziel-Kanalzahl statt hart Stereo halbiert
   bei Mono-Ausgabe den Temp-Bedarf.)
2. **Ein einziger** direkter Encode: `concat` der WAVs → `aac_at`/CVBR in eine
   eindeutige Partial-Datei neben dem Ziel; erst nach erfolgreicher Validierung
   wird sie per `rename(2)` atomar zur finalen `.m4b`.

> **Temp-Fußabdruck:** Standard hält **alle** Slice-WAVs gleichzeitig vor (sie
> werden erst nach dem finalen Encode gelöscht), weil der eine durchgehende Encode
> die komplette concat-Liste braucht. Unkomprimiertes PCM ist groß → bei mehreren
> langen Büchern viele GB. Inkrementell (Slice→Encode→Löschen) ginge nur mit
> Einzel-Encodes pro Segment — genau der **Performance-Modus**, der ohne WAVs
> auskommt. Wer wenig Platz hat, nutzt Performance; wer CPU schonen will, Standard.

Es wird genau einmal kodiert, direkt in den End-Container. **Kein** Stream-Copy
vorkodierter Segmente.

### Performance-Modus — `performParallelConversion`

1. Jedes Kapitel **parallel** direkt mit `aac_at`/CVBR in `.m4a` enkodieren —
   `getArgsForParallelEncoding`.
2. Finaler `-c copy` „Stream Copy Merge": `concat`-mux ohne Re-Kodierung.

Schneller (Demo 2026-06-03: ~2,4× ggü. Standard), weil parallel enkodiert wird
und der finale Schritt nur muxt.

> **Einschränkung (Performance-Modus):** Weil separat kodierte AAC-Segmente per
> `-c copy` ohne Neu-Kodierung zusammengefügt werden, trägt jedes Segment sein
> AAC-Encoder-Priming/-Padding. Bei **durchgehender Musik** über Kapitelgrenzen
> könnte das an den Übergängen hörbar werden. Für **Sprach-Hörbücher** ist das in
> der Praxis unkritisch: Kapitel enden und beginnen mit Stille, Priming/Padding
> sind selbst Stille → an der Grenze wird nur minimal zusätzliche Stille eingefügt,
> kein Wellenform-Sprung, also kein Knackser. Rest-Risiko nur bei hart ohne
> Stille-Rand geschnittenen Kapiteln + minimale kumulative Dauer-Drift. Wer ganz
> sichergehen will oder gemischtes Material hat: **Standard-Modus** verwenden (ein
> einziger durchgehender Encode). Ein Hörtest an real erzeugten Büchern steht noch
> aus (siehe Projekt-Backlog).

## Encoder: `aac_at -aac_at_mode cvbr`

- Apples nativer AudioToolbox-Encoder, **Constrained VBR**. Bessere Qualität als
  ffmpeg-natives AAC (Niveau Audiobook Builder).
- Ziel-Bitrate via `-b:a` (Default `48k`), Sample-Rate `-ar`, Kanäle `-ac`
  (mono/stereo).

### Entscheidung cvbr — NICHT auf echtes `vbr` umstellen

Stand 2026-06-03 bewusst bei `cvbr` geblieben (Daniel). Echtes
`-aac_at_mode vbr` würde MediaInfo „Variable" zeigen, ist aber
**qualitätsbasiert** → die `--bitrate`/Settings-Bitrate würde bedeutungslos.
`cvbr` behält die Bitraten-Steuerung. Nicht „zurückfixen".

## „Constant"-Label ist kosmetisch (verifiziert 2026-06-03)

ffmpeg 8.1.1 + gebündeltes mediainfo melden bei `aac_at cvbr` **immer**
„Bit rate mode: Constant" — in **beiden** Modi.

- Früher als Performance-Mode-Artefakt des `-c copy` angenommen (der die
  MP4-Bitraten-Header-Atome durch einen statischen Average-Header ersetzt).
- **Isolations-Test widerlegt das:** auch ein einzelner direkter
  `aac_at cvbr`-Encode (ohne Concat/Copy) wird „Constant" gelabelt.
- Folge: **MediaInfos „Bit rate mode" ist hier kein verlässlicher
  VBR-Indikator.** Der Audio-Stream bleibt Constrained VBR.
- **Code-Stand:** Das Laufzeit-Log gibt den „Constant"-Hinweis jetzt in
  **beiden** Modi aus (zuvor nur Performance-Mode, irreführend) und mit
  korrigiertem Wortlaut (es ist ein `aac_at`/CVBR-Label-Artefakt, nicht Folge
  des Stream-Copy) — `FFmpegWrapper.convert`.

## Referenz-Encoding: kleine Sprach-Hörbücher (Stand 2026-07-05)

Default-Referenz für neue Konvertierungen ist **AAC mono, 32 kHz, ~48 kbit/s**
(Stichprobe Sprachhörbuch: `AAC / 48.0 kb/s / 1 Kanal / 32000 Hz`). Für reine
Sprache ist der Unterschied zur höchsten Qualität praktisch unhörbar, die Dateien
werden aber sehr klein — das ist der bewusste Default (Begründung/„Geheimtipp" in
der README). Höher kodierte Bestände sind Re-Kodierungs-Kandidaten.

## Mediainfo-Dauer bei VBR unzuverlässig (2026-07-05)

Die Dauer-**Schätzung** von `mediainfo` auf VBR-AAC-M4B weicht bei mehrstündigen
Sammlungen drastisch ab (im Batch bis 4,4 h Abweichung bei einer 78-h-Sammlung).
Spieldauer-Verifikation deshalb IMMER **dekodiert** (`ffprobe` mit echtem Decode
bzw. Container-Stats), nie über die Mediainfo-Schnellschätzung.

## Output-Struktur (verifiziert)

Die `.m4b` enthält: Kapitel-Marken aus Tags oder dem sichtbaren Quellpfad
(`AudioFile.sourceURL`; bei Symlinks also der Linkname), nicht aus der
aufgelösten physischen Lese-URL. Die FFMETADATA-`[CHAPTER]`-Blöcke baut
`writeConcatAndChapters`, Titel maskiert `escapeFFMetadata`. Hinzu kommen ein
eingebettetes Cover (`-disposition:v attached_pic`; auch reines
eingebettetes Artwork via `resolveCoverInputPath`), Metadaten title/artist/genre
sowie `album=title` (Hörbuch-Konvention: das Buch als „Album" der Kapitel).

## Auto-Split nach Dauer

`makeConversionPlan` ist die gemeinsame Quelle für Gruppen und tatsächliche
Zielpfade. `splitAudioFilesIfNeeded` gruppiert Kapitel bei `maxDurationHours`;
Ausgabe-Namen `-01`, `-02` … via `resolveOutputURL`. GUI und CLI prüfen und
melden genau diese Ziele. CLI-Steuerung: `--max-duration <std>`.

Finale ffmpeg-Läufe schreiben nie direkt mit `-y` auf eine bestehende Ausgabe.
Fehler oder Abbruch entfernen nur die eindeutige Partial-Datei; das bestätigte
Original bleibt bis zum atomaren Commit erhalten.

## Prozess-Management & Cancellation

- **Laufbezogener Kontext:** Jeder Konvertierungslauf besitzt seine eigenen Prozesse und Temp-Verzeichnisse in einem `ConversionContext`.
- **Cancellation:** Ein Abbruch beendet und bereinigt ausschließlich den Kontext der betroffenen `ConversionSession`; parallele Fenster bleiben unberührt. Ein schneller Neustart macht die alte Completion per Lauf-ID ungültig.
- **Signal-Handling:** Das CLI fängt `SIGINT` (Ctrl+C) bereits während Ordnerscan
  und Metadatenanalyse ab. Es cancelt den registrierten Swift-Vorbereitungstask,
  beendet laufbezogene externe Prozesse und wertet Cancellation zwischen den
  AVFoundation-Ladevorgängen aus. Beim Encoding wartet es auf das vollständige
  Temp-/Partial-Cleanup. Ein Signal nach dem letzten atomaren Commit ändert
  einen erfolgreichen Exit nicht mehr.
