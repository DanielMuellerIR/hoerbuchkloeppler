"""Prüft das ANSI-Endbild der CLI maschinell.

`docs/build-and-test.md` beschreibt dieses Rezept bisher nur von Hand: Die CLI
zeichnet den Pacman-Statusblock per Cursor-Sprüngen neu, und einer rohen
Mitschrift sieht man nicht an, ob eine Logzeile am Ende noch dasteht. Das Skript
lässt die CLI an einem Pseudoterminal laufen, unterbricht sie mit SIGINT und
spielt den Strom durch einen Mini-Emulator nach.

Erfolgskriterium: Jede geschriebene Logzeile steht im Endbild noch vollständig
da — einschließlich der Abbruchmeldung.
"""
import atexit
import os
import pathlib
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parents[1]
CLI = REPO / "HoerbuchkloepplerCore/.build/debug/kloeppler"
FF = REPO / "HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin/ffmpeg"
assert FF.exists(), f"ffmpeg fehlt: {FF} — vorher ./build.sh --deps-only ausführen"
assert CLI.exists(), f"kloeppler fehlt: {CLI} — vorher swift build --package-path HoerbuchkloepplerCore"

# Der Renderer nutzt genau drei Sequenzen (siehe TerminalRenderer): eine Zeile
# hoch, Zeile löschen, an den Zeilenanfang.
ESCAPE = re.compile(r"\x1b\[(?:1A|2K|G)")
LOG_LINE = re.compile(r"^\[\d\d:\d\d:\d\d\.\d\d\d\] ")
# Der Fortschrittsbalken erscheint erst, wenn das Encoding wirklich läuft.
PACMAN = "\u15e7"


def render(stream: str) -> list[str]:
    """Bildet ESC[1A, ESC[2K, ESC[G und Text nach; gibt das Endbild zurück."""
    lines = [""]
    row = 0
    column = 0
    index = 0
    while index < len(stream):
        match = ESCAPE.match(stream, index)
        if match:
            sequence = match.group()
            if sequence == "\x1b[1A":
                row = max(0, row - 1)
            elif sequence == "\x1b[2K":
                lines[row] = ""
                column = 0
            else:  # ESC[G
                column = 0
            index = match.end()
            continue
        character = stream[index]
        index += 1
        if character == "\r":
            column = 0
            continue
        if character == "\n":
            row += 1
            column = 0
            while len(lines) <= row:
                lines.append("")
            continue
        while len(lines) <= row:
            lines.append("")
        padded = lines[row].ljust(column)
        lines[row] = padded[:column] + character + padded[column + 1:]
        column += 1
    return lines


root = pathlib.Path(tempfile.mkdtemp(prefix="hk-cli-terminal-"))
# Die drei Quellen belegen zusammen rund 86 MB; ohne das Aufräumen wüchse der
# Temp-Ordner mit jedem Lauf.
atexit.register(shutil.rmtree, root, True)
source = root / "quelle"
source.mkdir()
# Lang genug, damit das Encoding beim Signal noch läuft; 8000 Hz mono hält die
# Quelldateien trotzdem klein.
for index in (1, 2, 3):
    subprocess.run(
        [str(FF), "-v", "error", "-f", "lavfi", "-i",
         "sine=frequency=440:duration=1800", "-ar", "8000", "-ac", "1",
         "-metadata", f"title=Kapitel {index}",
         str(source / f"{index}.wav")],
        check=True,
    )

primary, secondary = pty.openpty()
process = subprocess.Popen(
    [str(CLI), str(source), "--verbose", "--mode", "parallel",
     "--output", str(root / "Buch.m4b"), "--title", "Terminalbuch",
     "--no-cover", "--bitrate", "24k", "--samplerate", "8000"],
    stdin=secondary, stdout=secondary, stderr=subprocess.DEVNULL,
    close_fds=True,
)
os.close(secondary)

chunks: list[bytes] = []
sent = False
started = time.monotonic()
while True:
    # Nicht nach fester Zeit unterbrechen: Auf schnellen Rechnern wäre der Lauf
    # sonst längst fertig. Das Signal folgt dem Fortschrittsbalken, der nur
    # während des Encodings gezeichnet wird.
    if not sent and PACMAN in b"".join(chunks).decode("utf-8", errors="replace"):
        process.send_signal(signal.SIGINT)
        sent = True
    ready, _, _ = select.select([primary], [], [], 0.05)
    if ready:
        try:
            data = os.read(primary, 65536)
        except OSError:
            break
        if not data:
            break
        chunks.append(data)
    elif process.poll() is not None:
        break
    if time.monotonic() - started > 120:
        process.kill()
        raise SystemExit("CLI endete nicht innerhalb von 120 Sekunden")
os.close(primary)
exit_code = process.wait()

raw = b"".join(chunks).decode("utf-8", errors="replace")
image = render(raw)
flat = "\n".join(image)

written = [line for line in ESCAPE.sub("", raw).splitlines() if LOG_LINE.match(line)]
assert written, "Kein einziger Logeintrag im Strom — Lauf war zu kurz"
missing = [line for line in written if line not in flat]
assert not missing, f"{len(missing)} von {len(written)} Logzeilen fehlen im Endbild: {missing[:3]}"

assert sent, "Der Lauf zeigte nie einen Fortschrittsbalken — SIGINT kam nie an"
assert "SIGINT empfangen" in raw, "CLI hat den Abbruch nie gemeldet"
assert "SIGINT empfangen" in flat, "Abbruchmeldung wurde vom Statusblock überschrieben"
assert exit_code == 130, f"SIGINT muss Exit 130 liefern, war {exit_code}"

print(f"VERIFIED {len(written)} Logzeilen im Endbild, Exit {exit_code}", flush=True)
