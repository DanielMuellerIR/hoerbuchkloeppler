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

Nur reguläre Dateien mit Ausführungsrecht gelten als Kandidaten. Fehlt ein
ausführbares Bundle-Tool, sucht die App im `$PATH` und in den Standardpfaden.
Der System-Check meldet „OK“ nur bei Exit 0 und nichtleerer Versionsausgabe.
Ein fehlgeschlagener Start eines ausführbaren Kandidaten wird einmal wiederholt.

## Ausgabe und Wiederanlauf

App und CLI reservieren jedes Ziel bis zum Ende des Laufs über eine
gemeinsame `fcntl`-Sperre im Ausgabeordner. Die versteckte Sperrdatei bleibt
bestehen, damit alle Läufe denselben Inode sperren. Ein vorhandener Zielsymlink
belegt den bisherigen, aufgelösten Schlüssel und den stabilen Schlüssel des
Verzeichniseintrags, damit ein Austausch des Links dieselbe Ziel-URL gesperrt
hält. Eine bereits laufende ältere Version kann nur ihren ursprünglichen
Schlüssel halten, bis ihr Lauf beendet ist.

Der Core legt pro Ausgabe einen exklusiven 0700-Arbeitsordner auf dem
Zielvolume an. Er hält den Deskriptor der Zwischendatei offen und reicht ihn
FFmpeg als FD 0 weiter. FFmpeg schreibt über `/dev/fd/0` in die geöffnete Datei,
auch wenn der sichtbare Pfad inzwischen ausgetauscht wurde. `-nostdin`
deaktiviert interaktive Befehle. MediaInfo prüft die fertige Datei im
Arbeitsordner vor der Übernahme.

Ein freies Ziel erscheint atomar per `RENAME_EXCL`. Bei einem bestätigten
vorhandenen Ziel übernimmt `RENAME_SWAP` die neue Datei und legt die bisherige
Ausgabe am Staging-Pfad ab. Der Core prüft anschließend beide Einträge.
Für ein bestätigtes Ziel zählen Gerät, Inode, Dateityp, Größe und
Änderungszeit. Für einen noch beschriebenen Staging-Inode oder -Ordner
genügen Gerät, Inode und Dateityp zur Identifikation. Ein vorhandenes
Staging-xattr liefert einen zusätzlichen Besitznachweis. Bei Abweichung
versucht der Core den Rücktausch oder sichert den Eintrag zur manuellen
Wiederherstellung.

Die Bereinigung unterscheidet Arbeitsordner und Ausgabe-Quarantänen. Vor
rekursiver Löschung verschiebt der Core den geprüften Arbeitsordner atomar in
Quarantäne und löscht relativ zu dessen geöffnetem Verzeichnisdeskriptor.
Ausgabe-Quarantänen führen mit `.owner-pid` und `.entry-identity.json` den
Besitzer und den löschbaren Eintrag. Vor einem Swap bezeichnet der Datensatz
die neue Datei. Erst wenn beide Einträge nach dem Austausch geprüft sind,
darf der Wiederanlauf anhand eines aktualisierten Datensatzes die Altdatei
entfernen. Bis diese Bestätigung gespeichert ist, bleibt die Altdatei bei
einem Absturz oder fehlgeschlagenen Rücktausch im Staging-Ordner erhalten.
Ältere Datensätze werden für ihren Primäreintrag weiterhin gelesen. Eine vor
dem Swap eingetragene Alternatividentität berechtigt nicht zum Löschen.
Ein ggf. liegengebliebener Eintrag unter `.HB_EntryCleanup` wird erneut am
Deskriptor geprüft. Zusätzliche Dateien oder abweichende Identitäten verhindern
die automatische Bereinigung.

Der Wiederanlauf prüft für benannte Quarantänen zusätzlich die darin
angegebene PID gegen die Besitzerdatei. Er löscht Ausgabe-Quarantänen nur
nach einem nachweislich beendeten Besitzerprozess. Ältere `.partial`-Dateien
direkt neben dem Ziel brauchen dazu ihren zum Namen passenden PID-Marker
als xattr am Inode. Im System-Tempordner können ältere `.HB_Cleanup_`-Ordner
mit fehlendem Datensatz zu einer Ausgabe oder zu einer Konvertierung gehören.
Der Sweep entfernt aus solchen Ordnern ausschließlich bekannte reguläre
Arbeitsdateien. Unbekannte Nutzdaten bleiben am bisherigen Pfad erhalten.
Verwaiste `HB_Loudness_`-Ordner älterer Versionen bleiben mit passendem
Besitznachweis in der Bereinigung.

Fehlgeschlagene Rücktausche und fremde Einträge können unter einem
`.recovery-`-Namen oder in `.HB_RecoveryCleanup_` verbleiben. Der Sweep nimmt
diese Namen von der automatischen Bereinigung aus. Die Meldung beim Fehler
nennt den verbleibenden Pfad.

Diese Prüfungen schützen gegen parallele Klöppler-Läufe, Dateisynchronisierer
und versehentliche Pfadwechsel. Ein absichtlich eingreifender Prozess unter
derselben Unix-Benutzer-ID ist dagegen keine Sicherheitsgrenze: `unlinkat`
entfernt einen Namen relativ zu einem Ordner, nimmt aber keinen erwarteten
Inode als Bedingung entgegen. Ein solcher Prozess kann deshalb noch nach der
letzten Identitätsprüfung denselben Namen austauschen. `NSFileCoordinator` würde
das nicht schließen, weil es nur kooperierende Teilnehmer koordiniert und rohe
POSIX-Zugriffe nicht erzwingt. Eine harte Grenze bräuchte getrennte
Systemkonten oder Rechte und passt nicht zum lokalen Ein-Benutzer-Werkzeug.

## Installation

`./install.sh` mutiert `/Applications` erst, nachdem Notarisierungs-Ticket,
Signatur und Gatekeeper-Akzeptanz am Build-Artefakt erfolgreich geprüft wurden.
Das Skript kopiert das Bundle zunächst neben das Ziel und wiederholt dort die
Prüfungen für Signatur, Ticket, Gatekeeper und Laufzeitprogramme. Das Skript
erfasst Elternordner und Zielbundle über Gerät und Inode, bevor es den
Swift-Helfer unter `tools/InstallBundle` kompiliert. Der Helfer prüft diese
Identitäten nach dem Kompilieren, vor dem Beenden der Ziel-App und vor dem
Austausch erneut.
Der Helfer tauscht ein vorhandenes Bundle atomar aus und verwahrt es als
Backup. Bei einer Erstinstallation veröffentlicht er das neue Bundle nur bei
freiem Zielpfad. Nach dem Austausch prüft das Skript Signatur, Ticket,
Gatekeeper und Laufzeitprogramme erneut am Ziel. Erst dann darf der Helfer
das Backup entfernen. Bei einer fehlgeschlagenen Prüfung stellt er das vorige
Bundle wieder her, solange die beteiligten Einträge noch eindeutig
zugeordnet sind. Ein zwischenzeitlich ausgetauschtes Ziel und das nötige
Backup bleiben erhalten. Die Bereinigung verschiebt eigene Einträge atomar
in Quarantäne und löscht relativ zu offenen Verzeichnis-Deskriptoren.
Ausgetauschte Einträge bleiben mit Warnung erhalten.
Eine laufende Ziel-App
erhält zuerst SIGTERM und nach fünf
Sekunden ohne Beendigung SIGKILL. Registrierung, Startzeit und vollständiges
Kommando jedes Kandidaten stammen dabei aus einem einzigen `ps`-Snapshot; vor
jedem Signal muss derselbe Snapshot noch zum exakten Zielprogramm passen.
`./install.sh --no-notarize` erzeugt und prüft ausschließlich den
Developer-ID-signierten Test-Build im Projekt-Root und installiert ihn nie.

`build.sh` und `release.sh` lesen `VERSION` über dieselbe strikte Prüfung. Nur
zwei- oder dreiteilige numerische Versionen sind erlaubt; `release.sh` prüft sie,
bevor es DMG-, Staging- oder Cleanup-Pfade daraus ableitet.

`release.sh` ersetzt ein vorhandenes fertiges DMG erst nach erfolgreicher
Signatur-, Notary- und Gatekeeper-Prüfung. Fehler entfernen ausschließlich die
Zwischenstände des Laufs. Ist der private Mount noch aktiv oder kann
`hdiutil info` seinen Zustand nicht feststellen, bleiben Mount-Verzeichnis
und RW-Image zur späteren Prüfung erhalten. Auch nach einem erfolgreichen
Detach-Aufruf muss der Status sicher inaktiv sein, bevor das Image konvertiert
wird. Das DMG bleibt ausschließlich für eigene Macs bestimmt.
RW- und ungeprüftes DMG liegen in einem exklusiven Arbeitsordner je Lauf.
Ein Wiederholungslauf kann deshalb auch bei frühem Fehler kein noch
eingehängtes Image des vorherigen Laufs löschen.

Dieselbe Mount-Statusprüfung schützt den MediaInfo-Download in `build.sh`.
Auch ein nach dem Einhängen fehlgeschlagener Attach-Aufruf wird berücksichtigt.
Solange das private, schreibgeschützte Download-Image aktiv oder sein Zustand
unbekannt ist, wird sein Arbeitsverzeichnis nicht gelöscht. Der gemeldete
Pfad bleibt für eine spätere gezielte Prüfung erhalten.

## Ausführungsrecht der Binaries

Falls `Process()` die Binaries nicht starten kann (`Permission denied`), fehlt
das x-Bit:

```bash
chmod +x HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin/ffmpeg \
         HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin/mediainfo
```
