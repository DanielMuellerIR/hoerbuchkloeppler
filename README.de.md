**🌐 Sprache / Language:** [English](README.md) · [Deutsch](README.de.md)

<h1 align="center">Hörbuchklöppler</h1>

<p align="center">
  <strong>Macht aus einem Haufen loser Audiodateien ein einziges, sauber kapiteliertes <code>.m4b</code>-Hörbuch — mit Cover, korrekten Metadaten und erstaunlich kleinen Dateien.</strong>
</p>

Hörbuchklöppler ist ein macOS-Tool, das ungeordnete Audioquellen (`mp3`, `m4a`, `wav`, `flac` oder ein bestehendes `m4b`) zu einer sauberen `.m4b` zusammenbaut: Jede Eingabedatei wird ein Kapitel, Cover und Tags werden gesetzt, kodiert wird mit Apples nativem AAC-Encoder. Es gibt zwei Frontends auf gemeinsamem Core — eine **SwiftUI-App** und ein **Kommandozeilen-Tool `kloeppler`** für Skripte und Automatisierung.

---

## 💡 Der Trick für kleine Hörbücher (warum der Default 32 kHz / 48 kbit/s mono ist)

Hörbuchklöppler nutzt standardmäßig **mono, 48 kbit/s, 32 kHz** — mit Absicht. Wer Musik-Bitraten gewohnt ist, hält das für zu wenig. Für **gesprochenes Wort** ist es aber genau richtig:

- Bei reiner Sprache ist der Unterschied zu einer hoch kodierten Fassung **praktisch nicht hörbar**.
- Die Dateien werden **winzig** — ein mehrstündiges Buch schrumpft auf einen Bruchteil der üblichen Größe. Das zählt auf dem Handy, in der Cloud und über eine ganze Bibliothek hinweg.

Das ist die Kernidee des Tools, kein Zufall. Sprache trägt schlicht nicht die hohen Frequenzen und die breite Stereo-Information, die eine große Datei rechtfertigen würden. Wer skeptisch ist, **hört am besten selbst hin**:

```bash
# Irgendeine gemeinfreie Sprachaufnahme nehmen (z.B. ein LibriVox-Kapitel, gemeinfrei)
# und mit den Default-Einstellungen kodieren — dann mit dem Original vergleichen:
kloeppler /pfad/zum/ordner-mit-einem-kapitel --mono --bitrate 48k --samplerate 32000
```

> Eine fertige A/B-Hörprobe liegt den Releases bei: dieselbe 49-Sekunden-Aufnahme mit 128 kbit/s (772 KB) vs. der Hörbuchklöppler-Default (299 KB — rund **61 % kleiner**). Beide anhören — bei Sprache ist der Unterschied kaum hörbar. Quelle: *„Wunder über Wunder"* aus [Sammlung deutscher Gedichte 018](https://archive.org/details/sammlung_deutscher_gedichte_018_1506_librivox) ([LibriVox](https://librivox.org/) — gemeinfrei).

Für Musik oder Hörspiele lässt sich die Bitrate/Abtastrate natürlich hochsetzen (`--bitrate`, `--samplerate`, `--stereo`).

---

## Funktionen

- **Beliebiger Input → eine `.m4b`:** `mp3`, `m4a`, `wav`, `flac` und bestehende `m4b` (Kapitel werden neu ausgelesen).
- **Kapitel:** eine Eingabedatei = ein Kapitel; die Kapitelstruktur bestehender `m4b` wird eingelesen und bleibt editierbar.
- **Cover:** zuerst eingebettetes Artwork, sonst das größte Bild im Ordner (`folder.jpg`), oder selbst hineinziehen.
- **Metadaten:** Titel, Autor und Genre werden via MediaInfo erkannt und lassen sich überschreiben.
- **Auto-Split:** lange Bücher optional bei einer Maximaldauer (1–24 h) auf `-01`, `-02` … aufteilen.
- **Zwei Kodier-Modi** (siehe unten): ein sicherer sequenzieller und ein schneller paralleler Modus.
- **Skriptbar:** die `kloeppler`-CLI bietet jede Option als Flag, mit ehrlichen Exit-Codes.

---

## Installieren / Bauen

> **Kein fertiger Download / Releases-DMG — mit Absicht.** Anders als bei einigen
> anderen Projekten gibt es hier bewusst **keine** vorgebaute `.app`/`.dmg` unter
> Releases. Ein gebündelter Build enthielte `ffmpeg`, das unter der **GPL** steht;
> es mitzuverteilen würde die GPL-Pflichten (Quellcode oder ein schriftliches
> Angebot beilegen) auf dieses Projekt ziehen. Um dieses Projekt von diesen
> Pflichten freizuhalten, werden `ffmpeg`/`mediainfo` stattdessen **zur Build-Zeit**
> vom offiziellen Upstream geladen. Es gibt also keinen Ein-Klick-Download — dafür
> ist das Bauen ein einziger Befehl.

Voraussetzung: macOS (Apple Silicon oder Intel) und die Xcode-Kommandozeilen-Tools.

```bash
git clone https://github.com/DanielMuellerIR/hoerbuchkloeppler.git
cd hoerbuchkloeppler
./build.sh
```

`build.sh` lädt die externen Tools `ffmpeg` und `mediainfo` vom offiziellen Upstream (sie liegen **nicht** im Repo — siehe [Abhängigkeiten](#abhängigkeiten)), baut Core, CLI und App und legt `Hörbuchklöppler.app` zum bequemen Testen ins Projekt-Root.

```bash
./build.sh --cli-only   # nur das Kommandozeilen-Tool
./build.sh --help       # alle Optionen
```

### Nach /Applications installieren (optional, signiert & notarisiert)

`build.sh` erzeugt einen schnellen, nur ad-hoc signierten **Entwicklungs-Build** im Projekt-Root — praktisch zum Testen des aktuellen Stands. Wer die App dauerhaft in `/Applications` als **bewusst installierte, notarisierte Fassung** möchte — mit Developer ID signiert und von Apple notarisiert, sodass sie ohne Gatekeeper-Meckern startet (auch auf anderen Macs) — nutzt `install.sh`:

```bash
./install.sh                 # bauen → signieren → notarisieren → stapeln → /Applications
./install.sh --no-notarize   # Developer-ID-Test-Build im Projekt; installiert nie
./install.sh --help
```

Dafür braucht es ein **„Developer ID Application"**-Zertifikat im Schlüsselbund und ein `notarytool`-Schlüsselbund-Profil. Der Profilname kommt aus der Umgebungsvariable `NOTARY_PROFILE` oder einer clone-lokalen Git-Config — er wird nie committet, und die Zugangsdaten bleiben im Schlüsselbund (nie als Kommandozeilen-Argument). `--no-notarize` braucht weiterhin die Developer ID, beendet sich aber nach der Prüfung des projektlokalen Test-Builds; nach `/Applications` kommt ausschließlich ein erfolgreich notarisierter, gestapelter und von Gatekeeper akzeptierter Build. Ohne Developer ID: `./build.sh` verwenden.

Lokal bauen und in das eigene `/Applications` installieren ist **keine** Weiterverteilung und bleibt damit frei von den GPL-Pflichten, die das gebündelte `ffmpeg` sonst auslösen würde (siehe [Installieren / Bauen](#installieren--bauen) oben).

---

## Kommandozeile (`kloeppler`)

Die CLI ist ein vollwertiger Weg, Hörbuchklöppler zu nutzen — ideal für Skripte und KI-Agenten.

```
kloeppler <ordner> [--mode parallel|standard] [--bitrate 48k] \
          [--samplerate 32000] [--max-duration 0] [--mono|--stereo] \
          [--title <titel>] [--author <autor>] [--output <ziel>] \
          [--verbose] [--force]
```

- `<ordner>` — ein Ordner mit Audiodateien (eine Datei = ein Kapitel). Cover = größtes Bild / `folder.jpg`.
- `--title` / `--author` überschreiben die aus den Datei-Tags erkannten Werte (`--title` bestimmt auch den Dateinamen).
- `--output` — Zielordner oder voller `.m4b`-Pfad. Ohne Angabe landet die Datei neben der Quelle.
- `--max-duration <std>` — lange Bücher aufteilen (`0` = unbegrenzt).
- **Exit-Codes:** `0` nur bei echtem Erfolg, sonst `≠ 0` (SIGINT / Ctrl-C liefert `130`) — automatisierungstauglich.
- Eingaben werden vorab geprüft (Modus, Bitrate, Abtastrate) und brechen bei Fehlern früh mit klarer Meldung ab.

---

## Wie es arbeitet

Zwei Kodier-Strategien, pro Lauf umschaltbar:

- **Standard (sicher):** jedes Kapitel in unkomprimiertes `.wav` slicen, dann **ein einziger** AAC-Encode direkt in die finale `.m4b`. Kein Stream-Copy vorkodierter Segmente — am besten für durchgehende Musik über Kapitelgrenzen.
- **Performance (schnell):** jedes Kapitel parallel in AAC kodieren, dann per Stream-Copy ohne Neu-Kodierung zusammenfügen. Schneller — und bei gesprochenem Wort bleiben die Kapitelgrenzen sauber (Kapitel beginnen und enden mit Stille). Siehe [docs/encoding.md](docs/encoding.md).

Beide nutzen Apples `aac_at`-Encoder (AudioToolbox) im Constrained-VBR-Modus für bessere Qualität als ffmpegs natives AAC.

**Welchen wählen — Abwägung:**

| | Performance (Default) | Standard |
|---|---|---|
| **Tempo** | Am schnellsten | Langsamer |
| **CPU** | Nutzt alle Kerne — der Lüfter geht an | Schonender (nur ein finaler Encode) |
| **Temp-Speicher** | Klein (nur die komprimierten Segmente) | **Groß** — schreibt unkomprimiertes `.wav` für *alle* Kapitel gleichzeitig; beim Zusammenfassen mehrerer langer Bücher können das **viele GB** temporäre Dateien sein, bis der Lauf fertig ist |
| **Am besten für** | Die meisten Hörbücher; wenig freier Speicher | Gapless-Musik; wenn die CPU-Last niedrig bleiben soll |

Wer den Rechner leise und reaktiv halten will, nimmt Standard — braucht dann aber genug freien Speicher für die temporären WAVs. Ist der Speicher knapp, ist Performance besser.

---

## Abhängigkeiten

- [Swift Argument Parser](https://github.com/apple/swift-argument-parser) (via SwiftPM).
- **`ffmpeg`** und **`mediainfo`** zur Laufzeit — von `build.sh` geladen, nicht im Repo. `ffmpeg` steht unter der **GPL**; es wird hier als separater, unveränderter Subprozess aufgerufen (nicht hineingelinkt) und vom Nutzer vom offiziellen Upstream geladen, also von diesem Projekt nicht mitverteilt. Details: [docs/dependencies.md](docs/dependencies.md).

Eine tiefere Karte des Codes: [AGENTS.md](AGENTS.md) und der Ordner [`docs/`](docs/).

---

## Lizenz

Der eigene Code dieses Projekts steht unter der [MIT-Lizenz](LICENSE). Die externen `ffmpeg`/`mediainfo`-Binaries behalten ihre jeweiligen Upstream-Lizenzen (GPL-3.0 / BSD-2-Clause) — alle Drittlizenzen im Detail: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
