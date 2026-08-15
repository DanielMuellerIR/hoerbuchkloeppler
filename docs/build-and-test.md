# Bauen, CLI & Testen

## Alles bauen (empfohlen)

```bash
./build.sh            # lädt ffmpeg/mediainfo vom Upstream + baut CLI + App
                      #   -> ./Hörbuchklöppler.app (zum Testen), CLI in .build/release/
./build.sh --cli-only # nur Binaries + Core/CLI (kein Xcode-App-Build)
./build.sh --help     # alle Optionen
```

Das Skript lädt die externen Binaries (nicht im Repo — siehe
[dependencies.md](dependencies.md)) und legt die fertige App im Repo-Root ab.

## Nur Core/CLI von Hand

```bash
cd HoerbuchkloepplerCore
swift build -c release      # -> .build/release/kloeppler
```

App alternativ direkt über `Hörbuchklöppler.xcodeproj` in Xcode (oder
`xcodebuild`) — dann müssen `ffmpeg`/`mediainfo` vorab via `./build.sh --deps-only`
in `Resources/bin/` liegen (sonst greift zur Laufzeit der Homebrew-Fallback).

## CLI `kloeppler`

```
kloeppler <ordner> [--mode parallel|standard] [--bitrate 48k] \
          [--samplerate 32000] [--max-duration 0] [--mono|--stereo] \
          [--title <titel>] [--author <autor>] [--genre <genre>] \
          [--cover <bild>|--no-cover] [--output <ziel>] \
          [--verbose] [--force]
```

- `<ordner>` = absoluter Pfad zu einem Ordner mit Audiodateien (1 Datei = 1
  Kapitel). Cover = größte Bilddatei / `folder.jpg` im Ordner.
- `--max-duration <std>` teilt lange Bücher auf `-01`, `-02` … auf (0 =
  unbegrenzt). Pendant zur GUI-Einstellung „Maximale Dauer".
- `--title` / `--author` setzen Buchtitel/Autor explizit und gewinnen gegen die
  aus den Datei-Tags erkannten Kandidaten (`--title` bestimmt auch den Dateinamen).
  Ohne diese Optionen entscheidet die CLI bei mehrdeutigen Tag-Kandidaten selbst
  nach fester Priorität: Album vor Title bzw. Performer vor Album_Performer
  (die GUI öffnet in diesem Fall stattdessen die manuelle Auswahl).
- `--genre`, `--cover` und `--no-cover` bilden die entsprechenden GUI-Werte im
  kopierten CLI-Handoff vollständig ab.
- `--output <ziel>` = Zielordner (Datei heißt dann `<Titel>.m4b`) **oder** voller
  `.m4b`-Pfad. Ohne Angabe landet die `.m4b` im **Eltern**-Ordner der Quelle,
  benannt nach Titel-Tag bzw. Ordnername (sanitisiert) — `--output` ist nötig,
  wenn die Quelle auf einem vollen/schreibgeschützten Datenträger liegt.
- **Eingabe-Validierung:** `--mode` (nur `parallel`/`standard`), `--bitrate`
  (`<zahl>[k]`) und `--samplerate` (8000–192000) werden vorab geprüft; ungültige
  Werte brechen mit Usage-Fehler (Exit 64) ab, statt erst später in ffmpeg.
- Existiert die Zieldatei: ohne `--force` interaktive Nachfrage; bei
  Pipe/Non-TTY bricht sie mit Fehlercode ab (Hinweis auf `--force`).
- **Exit-Code:** 0 nur bei echtem Erfolg, sonst ≠ 0 (skript-/agent-tauglich).

## Demo-/Verifikations-Rezept (2026-06-03 erprobt)

```bash
# Kleiner Subset-Ordner (z.B. 3 Kapitel + folder.jpg) genügt für End-to-End.
.build/release/kloeppler "/pfad/zum/ordner" --mode standard --mono \
    --bitrate 48k --samplerate 32000 --verbose

# Output mit den gebündelten Binaries prüfen:
BIN=Sources/HoerbuchkloepplerCore/Resources/bin
"$BIN/ffmpeg" -i "out.m4b" -hide_banner 2>&1 | grep -E 'Chapter|Stream|title'
"$BIN/mediainfo" "out.m4b"
```

Beobachtetes Verhalten verifizieren (Kapitel, Cover, Metadaten, Sample-Rate) —
nicht nur „Build grün".

## Unit-Tests (Core)

```bash
cd HoerbuchkloepplerCore && swift test        # 90 Tests, 17 Suites
```

Deckt die reine Kernlogik ab: FFMETADATA-Escaping/Parsing, Kapitel-Arithmetik
(`buildChapterMetadata`), Auto-Split, Ausgabe-Dateinamen, Zeit-Parsing,
NaN/Infinity-Härtung sowie Ausgabeplan/atomare Übernahme, Tool-Auflösung,
laufbezogenen Abbruch, Metadatenentscheidung, echte asynchrone
AVFoundation-Analyse einer WAV-Datei und shell-sicheren CLI-Handoff.
Bewusst **nicht** dabei: das reale Encoding-Ergebnis — dafür ist das Rezept oben da.

Die geprüften Funktionen sind `internal` statt `private`, damit `@testable
import` drankommt. Das ist Absicht, kein vergessenes `private`.

## Terminal-Ausgabe prüfen (ohne vor dem Terminal zu sitzen)

Die CLI zeichnet den Pacman-Statusblock per ANSI-Cursor-Sprüngen neu. Ob das
Bild stimmt, sieht man einer `> datei.raw`-Mitschrift nicht an — die
Escape-Sequenzen müssen erst „gerendert" werden:

1. Lauf mit `--verbose --mode parallel` nach `raw`-Datei umleiten. `--verbose`
   ist wichtig: nur dann feuert `logVerbose` aus den Encoding-Threads mitten in
   die Redraw-Schleife.
2. Den Strom durch einen Mini-Emulator schicken, der `ESC[1A`, `ESC[2K`,
   `ESC[G` und Text nachbildet — mehr nutzt die CLI nicht — und das Endbild
   ausgeben.
3. **Erfolgskriterium:** Jede geschriebene Logzeile steht im Endbild noch
   vollständig da. Vor dem Fix gingen 4 von 18 Zeilen verloren (u.a. „🏁 Alle
   Vorgänge beendet."), danach 0 von 18.

Deshalb laufen alle Terminal-Ausgaben der CLI über `TerminalRenderer` in
`KloepplerCLI.swift`; der Core schreibt nie direkt auf stdout, sondern über
`ConversionSession.logSink`.

## Schlüssel-Dateien zum Prüfen bei Änderungen

- `FFmpegWrapper.swift` — Kommando-Bau, Größen-Validierung, Prozesse.
- `ConversionSession.swift` — Lebenszyklus, Thread-sicheres Logging.
- `KloepplerCLI.swift` — Terminal-Output, ANSI, `--verbose`.
- `AudioFile+Extensions.swift` — Metadaten/Kapitel/Cover.

## Bekannte Test-Lücken / offen

- Stream-Copy-Merge mit verschiedenen Codecs.
- Extrem große/kleine Segmente.
- UI-Responsiveness bei schwerem parallelem Encoding.
- **Voll-Buch (>20 Kapitel) maschinell verifiziert (2026-07-16):** reales
  23-Kapitel-Buch (11:22 h) im Parallel-Modus, 23 korrekte Kapitelmarken,
  Cover, Metadaten, Exit 0. Nach Gehör weiterhin ungeprüft.
- **CLI end-to-end verifiziert (Stand 2026-06-25):** Standard- + Parallel-Modus,
  m4b-Re-Import (`extractChapters` via gebündeltem ffmpeg), Auto-Split
  (`--max-duration` → `-01`/`-02`), Stereo (44100 Hz), Cover (eingebettet +
  `folder.jpg`), Kapiteltitel mit Sonderzeichen, Fehler-Exit-Codes, SIGINT-
  Abbruch inkl. Temp-Cleanup. SIGINT während der AVFoundation-Vorbereitung
  wurde am 2026-08-15 mit 1.001 WAV-Dateien und Exit 130 verifiziert.
- **Noch ungetestet:** GUI-App-Lauf (nur Kompilierung via xcodebuild geprüft),
  Audio-Qualität nach Gehör.
