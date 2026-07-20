# Abhängigkeiten & eingebettete Binaries

## Swift-Pakete

- `swift-argument-parser` (≥ 1.3.0) — CLI-Parsing (`Package.swift`).

## Externe Tools (`ffmpeg`/`mediainfo`)

| Tool | Wofür | Ort | Größe |
|---|---|---|---|
| `ffmpeg` | Audio-Slicing/Encoding/Muxing | `HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin/ffmpeg` | ~76M |
| `mediainfo` | Metadaten-/Bitraten-Auslesen | `…/Resources/bin/mediainfo` | ~14M |

- Statische macOS-Binaries. **Nicht im Repo getrackt** — sie werden vom
  Build-Skript vom offiziellen Upstream in `Resources/bin/` geladen. Grund: `ffmpeg`
  ist GPL (nicht mitverteilen, wenn vermeidbar) und ~76 MB würden das Repo aufblähen.
- Beim Build bindet das Package sie via `resources: [.copy("Resources/bin")]`
  (`Package.swift`) → sie landen im `Bundle.module`.
- Laufzeit-Auflösung: `FFmpegWrapper.getBinaryURL` sucht erst im `Bundle.module`,
  dann im `$PATH`, dann in den üblichen Installationsorten Homebrew
  (`/opt/homebrew/bin`, `/usr/local/bin`) und MacPorts (`/opt/local/bin`)
  (Fallback, falls die eingebetteten Binaries fehlen).
- `ffprobe` wird **nicht** benötigt — die Kapitel-Analyse von m4b/mp4 läuft über
  `ffmpeg` (`-f ffmetadata`, geparst in `AudioFile+Extensions.swift` →
  `extractChapters`/`parseFFMetadataChapters`). So funktioniert der m4b-Re-Import
  auch ohne separat installiertes ffprobe.

## Ausführungsrecht (x-Bit)

Kann ein Datei-Sync (z. B. Cloud-Ordner) das x-Bit der Binaries im Working-Tree
strippen, failt `Process()` mit `Permission denied`. Fix siehe
[operations.md](operations.md) → „Ausführungsrecht der Binaries".
