# Hörbuchklöppler — Agent-Einstieg

macOS-Tool, das aus ungeordneten Audioquellen (mp3/m4a/wav/flac/m4b) eine
strukturierte `.m4b` baut: korrekte Kapitel, Cover, Metadaten. Zwei Frontends
auf gemeinsamem Core — SwiftUI-App + CLI `kloeppler`.

Diese Datei ist nur die **Karte**. Nutzer-Doku: [README.md](README.md) /
[README.de.md](README.de.md). Technische Details liegen themengetrennt in `docs/` —
gezielt das passende Dokument greppen/lesen statt alles laden.

## Typ & Zweck
- **Typ:** GUI-App
- **Zweck:** Baut aus ungeordneten Audioquellen eine strukturierte .m4b-Hörbuchdatei mit Kapiteln, Cover und Metadaten.
- **Plattform:** macOS-GUI (+ CLI auf gemeinsamem Core)

## Wohin für was

| Thema | Dokument |
|---|---|
| Modul-Aufbau, Execution-Engine, **Source-Map** (Datei → Zuständigkeit → Symbole) | [docs/architecture.md](docs/architecture.md) |
| Kodierung: Standard-/Parallel-Modus, `aac_at cvbr`, VBR/„Constant"-Befund | [docs/encoding.md](docs/encoding.md) |
| Einstellungen, Defaults, Persistenz (`settings.json`) | [docs/settings.md](docs/settings.md) |
| Bauen, CLI-Nutzung, Demo-/Verifikations-Rezept, Test-Lücken | [docs/build-and-test.md](docs/build-and-test.md) |
| Abhängigkeiten, externe Binaries (`ffmpeg`/`mediainfo`) | [docs/dependencies.md](docs/dependencies.md) |
| `.gitignore`, Binaries-Handling, x-Bit | [docs/operations.md](docs/operations.md) |

## Konventionen (nicht aus dem Code lesbar)

- **Pfade im Repo relativ** — Multi-Mac-Sync, nie `/Users/<name>/…`.
- **Kommentare/Doku Deutsch, Identifier Englisch.** Daten ISO 8601.
- **Externe `ffmpeg`/`mediainfo`** werden **nicht** eingecheckt (Größe + `ffmpeg`
  ist GPL), sondern vom Build-Skript vom Upstream geladen und via `Bundle.module`
  eingebettet; Homebrew als Laufzeit-Fallback — Details in
  [docs/dependencies.md](docs/dependencies.md) + [docs/operations.md](docs/operations.md).
- **Encoder bleibt `cvbr`**, nicht auf echtes `vbr` umstellen — Begründung in
  [docs/encoding.md](docs/encoding.md).
- **Drei Einstiegspunkte:** `build.sh` baut nur (ad-hoc), `install.sh` baut,
  notarisiert und installiert nach `/Applications`, `release.sh` packt daraus ein
  DMG und installiert nie. Profilname aus `NOTARY_PROFILE` oder
  `git config hoerbuchkloeppler.notaryProfile`.
- **Das DMG aus `release.sh` wird nie veröffentlicht.** Es ist nur der Weg auf
  einen weiteren eigenen Mac; Weitergabe würde die GPL-Pflichten des gebündelten
  `ffmpeg` auslösen. Deshalb hat `release.sh` bewusst keinen `--publish`-Pfad,
  keinen GitHub-Upload und keinen Tag — bitte auch keinen nachrüsten.

- **`SWIFT_TREAT_WARNINGS_AS_ERRORS` nicht in den Xcode-Build geben.** Xcode
  setzt bei lokalen Swift-Paketen bereits `-suppress-warnings`; ein zusätzliches
  `-warnings-as-errors` ergibt eine unzulässige Optionskombination, und der Build
  bricht ab (belegt 2026-08-29). Warnungen als Fehler deshalb nur in der
  Swift-Suite prüfen: `swift test -Xswiftc -warnings-as-errors`; `build.sh`
  fährt den xcodebuild-Pfad ohne den Schalter.

- **Temp-Verzeichnisse nur über Gerät und Inode wiedererkennen.** Die
  Besitzerprüfung eines von `ffmpeg` befüllten Staging-Ordners darf weder
  Verzeichnisgröße noch Zeitstempel vergleichen — beide ändern sich während der
  regulären Verarbeitung, und die Bereinigung verweigerte daraufhin den **eigenen**
  Ordner. Stabil sind allein Gerät und Inode. Vor dem rekursiven Löschen wird der
  Ordner atomar unter einen eindeutigen Quarantänenamen verschoben (belegt
  2026-08-25).

## Vorgänger-Versionen (Archiv-Tags)

Frühere Stände liegen als annotierte Tags in **diesem** Repo, nicht als separate
Ordner/Repos: `archive/v1-2026-05-01-vor-parallelisierung`, `archive/v2-2026-05-05`,
`archive/v3-2026-05-05` (alle am gemeinsamen Root). Abrufen ohne den Arbeitsbaum zu
stören: `git worktree add /tmp/alt archive/v2-2026-05-05`.
