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

Nur reguläre Dateien mit Ausführungsrecht gelten als Kandidaten. Ein defektes
oder nicht ausführbares Bundle-Tool verdeckt deshalb keinen funktionierenden
`$PATH`-Fallback; der System-Check meldet „OK“ nur bei Exit 0 und nichtleerer
Versionsausgabe.

## Schutzgrenze der temporären Bereinigung

Der Core löscht temporäre Ordner, Staging-Dateien und verdrängte alte Ausgaben
nur mit einem zuvor erfassten Besitznachweis. Dazu gehören ein exklusiver
0700-Ordner, Besitzer-Marker sowie Volume und Inode. Vor einer rekursiven
Bereinigung verschiebt der Core den geprüften Ordner unter einen zufälligen
Quarantänenamen, öffnet genau diesen Ordner und entfernt seine Einträge relativ
zum offenen Verzeichnis-Deskriptor. Einzeldateien werden ebenfalls zuerst
atomar quarantänisiert und danach erneut gegen den erwarteten Inode geprüft.

Diese Prüfungen schützen gegen parallele Klöppler-Läufe, Dateisynchronisierer
und versehentliche Pfadwechsel. Ein absichtlich eingreifender Prozess unter
derselben Unix-Benutzer-ID ist dagegen keine Sicherheitsgrenze: `unlinkat`
entfernt einen Namen relativ zu einem Ordner, nimmt aber keinen erwarteten
Inode als Bedingung entgegen. Ein solcher Prozess kann deshalb noch nach der
letzten Identitätsprüfung denselben Namen austauschen. `NSFileCoordinator` würde
das nicht schließen, weil es nur kooperierende Teilnehmer koordiniert und rohe
POSIX-Zugriffe nicht erzwingt. Eine harte Grenze bräuchte getrennte
Systemkonten oder Rechte und passt nicht zum lokalen Ein-Benutzer-Werkzeug.

Bei jeder erkennbaren Abweichung handelt der Core deshalb rest-erhaltend: Er
lässt den Eintrag unangetastet, versucht einen atomaren Rollback oder bewahrt
ihn unter einem Namen mit dem Präfix `.HB_RecoveryCleanup_` auf und schreibt
eine Warnung ins Log. Der automatische Sweep entfernt einen solchen Rest erst,
wenn Name, Besitzer-Marker und aufgezeichnete Identität wieder eindeutig
zusammenpassen.

## Installation

`./install.sh` mutiert `/Applications` erst, nachdem Notarisierungs-Ticket,
Signatur und Gatekeeper-Akzeptanz am Build-Artefakt erfolgreich geprüft wurden.
Das Skript kopiert das Bundle zunächst neben das Ziel und wiederholt dort die
Signatur-, Ticket-, Gatekeeper- und Laufzeitprogramm-Prüfungen. Beim Austausch
behält es die vorige App bis zur erfolgreichen Prüfung des Installationsziels
als Backup; schlägt ein nachgelagerter Test fehl, setzt der EXIT-Trap dieses
Bundle atomar zurück. Eine laufende Ziel-App erhält zuerst SIGTERM und nach fünf
Sekunden ohne Beendigung SIGKILL. Registrierung, Startzeit und vollständiges
Kommando jedes Kandidaten stammen dabei aus einem einzigen `ps`-Snapshot; vor
jedem Signal muss derselbe Snapshot noch zum exakten Zielprogramm passen.
`./install.sh --no-notarize` erzeugt und prüft ausschließlich den
Developer-ID-signierten Test-Build im Projekt-Root und installiert ihn nie.

`build.sh` und `release.sh` lesen `VERSION` über dieselbe strikte Prüfung. Nur
zwei- oder dreiteilige numerische Versionen sind erlaubt; `release.sh` prüft sie,
bevor es DMG-, Staging- oder Cleanup-Pfade daraus ableitet.

## Ausführungsrecht der Binaries

Falls `Process()` die Binaries nicht starten kann (`Permission denied`), fehlt
das x-Bit:

```bash
chmod +x HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin/ffmpeg \
         HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin/mediainfo
```
