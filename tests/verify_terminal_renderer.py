#!/usr/bin/env python3
"""Prüft Status-Neuzeichnung an echten PTYs mit einem unabhängigen Zellmodell."""
import argparse
import fcntl
import json
import os
import pathlib
import pty
import re
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time
import unicodedata

REPO = pathlib.Path(__file__).resolve().parents[1]
ESCAPE = re.compile(r"\x1b\[(1A|2K|G)")


def glyphs(text):
    result = []
    for character in text:
        if result and (unicodedata.combining(character) or character in "\ufe0f\u200d"
                       or result[-1].endswith("\u200d")):
            result[-1] += character
        else:
            result.append(character)
    return result


def width(glyph):
    if "\ufe0f" in glyph or "\u200d" in glyph or any(0x1F300 <= ord(c) <= 0x1FAFF for c in glyph):
        return 2
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in glyph)


class Screen:
    def __init__(self, columns):
        self.columns = columns
        self.lines = [[]]
        self.row = self.column = 0

    def feed(self, stream):
        index = 0
        while index < len(stream):
            match = ESCAPE.match(stream, index)
            if match:
                if match[1] == "1A":
                    self.row = max(0, self.row - 1)
                elif match[1] == "2K":
                    self.lines[self.row] = []
                else:
                    self.column = 0
                index = match.end()
                continue
            end = stream.find("\x1b", index)
            if end < 0:
                end = len(stream)
            for glyph in glyphs(stream[index:end]):
                if glyph == "\r":
                    self.column = 0
                    continue
                if glyph == "\n":
                    self.row += 1
                    self.column = 0
                else:
                    cells = width(glyph)
                    if self.column + cells > self.columns:
                        self.row += 1
                        self.column = 0
                    while len(self.lines) <= self.row:
                        self.lines.append([])
                    line = self.lines[self.row]
                    line.extend([" "] * max(0, self.column + cells - len(line)))
                    if cells:
                        line[self.column:self.column + cells] = [glyph] + [""] * (cells - 1)
                    self.column += cells
                while len(self.lines) <= self.row:
                    self.lines.append([])
            index = end

    def text(self):
        return "\n".join("".join(line) for line in self.lines)


class Terminal:
    def __init__(self, executable, columns, rows=24):
        self.master, slave = pty.openpty()
        self.resize(columns, rows)
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE,
                                        stdout=slave, stderr=subprocess.PIPE)
        os.close(slave)

    def resize(self, columns, rows=24):
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        if hasattr(self, "process"):
            self.process.send_signal(signal.SIGWINCH)

    def command(self, action, text=""):
        self.process.stdin.write((json.dumps({"action": action, "text": text}) + "\n").encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + 10
        output = bytearray()
        acknowledged = False
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.master, self.process.stderr], [], [], .05)
            if self.master in ready:
                chunk = os.read(self.master, 65536)
                if not chunk:
                    raise AssertionError("PTY vor Befehlsabschluss beendet")
                output.extend(chunk)
            if self.process.stderr in ready:
                acknowledgement = self.process.stderr.readline()
                assert acknowledgement == b"done\n", acknowledgement.decode(errors="replace")
                acknowledged = True
            if acknowledged and not select.select([self.master], [], [], .05)[0]:
                return output.decode()
        raise AssertionError("Renderer antwortet nicht innerhalb von 10 Sekunden")

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        os.close(self.master)
        self.process.stderr.close()
        assert self.process.returncode == 0, self.process.returncode


def verify(executable, resizing=True):
    for columns in (12, 24, 40, 80):
        terminal = Terminal(executable, columns)
        screen = Screen(columns)
        try:
            for action, text in [
                ("log", "LOG-before"),
                ("draw", "Status: " + "lange Zeile " * 8 + "\n001 漢字 🛠️ é ᗧ•••• 75%\n"),
                ("draw", "Status: kürzer\n002 🛠️ ᗧ•••• 90%\n"),
                ("log", "LOG-middle"),
                ("draw", "Status: fertig\n"),
                ("clear", ""),
                ("log", "LOG-after"),
            ]:
                screen.feed(terminal.command(action, text))
            for marker in ("LOG-before", "LOG-middle", "LOG-after"):
                assert marker in screen.text(), f"Breite {columns}: {marker} überschrieben:\n{screen.text()}"
            assert "Status:" not in screen.text(), f"Breite {columns}: alte Statuszeilen bleiben stehen:\n{screen.text()}"
            if resizing:
                terminal.command("draw", "Status: vor Größenwechsel\nFortschritt 50%\n")
                terminal.resize(18)
                changed = terminal.command("draw", "Status: nach Größenwechsel\n")
                assert "\x1b[1A" not in changed, "Größenwechsel löscht Zeilen mit veralteter Geometrie"
                terminal.command("clear")
                terminal.resize(80)
                terminal.command("log", "LOG-resize")
        finally:
            terminal.close()
    terminal = Terminal(executable, 12, rows=4)
    screen = Screen(12)
    try:
        screen.feed(terminal.command("log", "LOG-small"))
        screen.feed(terminal.command("draw", "Status:\n" + "👨‍👩‍👧‍👦 漢字\t\x1b[2K\n" * 20))
        screen.feed(terminal.command("clear"))
        screen.feed(terminal.command("log", "LOG-end"))
        assert "LOG-small" in screen.text() and "LOG-end" in screen.text(), screen.text()
        assert "Status:" not in screen.text(), screen.text()
    finally:
        terminal.close()
    print("VERIFIED: Logzeilen bei 12/24/40/80 Spalten und konservativer Größenwechsel")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--renderer-source", type=pathlib.Path,
                        default=REPO / "HoerbuchkloepplerCore/Sources/kloeppler/TerminalRenderer.swift")
    parser.add_argument("--skip-resize", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="hk-terminal-renderer-") as directory:
        executable = pathlib.Path(directory) / "renderer"
        subprocess.run(["swiftc", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
                        str(args.renderer_source), str(REPO / "tests/terminal_renderer_harness.swift"),
                        "-o", str(executable)], check=True)
        verify(executable, not args.skip_resize)


if __name__ == "__main__":
    main()
