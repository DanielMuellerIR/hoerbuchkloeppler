# Entwicklung & Betrieb

## `.gitignore` / nie einchecken

- `.build/` (Swift-Build-Artefakte).
- `pkg_out/`, `*/xcuserdata/`, `DerivedData/`, `.DS_Store`, `test.txt`.
- Die externen Binaries (`ffmpeg`/`mediainfo`) werden **nicht** eingecheckt,
  sondern vom Build-Skript geladen — siehe [dependencies.md](dependencies.md).

## Externe Binaries

`ffmpeg` und `mediainfo` sind zur Laufzeit nötig. Sie werden nicht mit dem Repo
verteilt (Größe + `ffmpeg` ist GPL); das Build-Skript lädt sie vom offiziellen
Upstream nach `HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin/`,
von wo das Package sie via `Bundle.module` einbettet. Zur Laufzeit fällt
`FFmpegWrapper.getBinaryURL` andernfalls auf ein per Homebrew installiertes
`ffmpeg`/`mediainfo` im `$PATH` zurück. Details: [dependencies.md](dependencies.md).

## Ausführungsrecht der Binaries

Falls `Process()` die Binaries nicht starten kann (`Permission denied`), fehlt
das x-Bit:

```bash
chmod +x HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin/ffmpeg \
         HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin/mediainfo
```
