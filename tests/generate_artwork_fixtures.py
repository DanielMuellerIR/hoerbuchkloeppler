#!/usr/bin/env python3
"""Begrenzte synthetische Cover, einschließlich großer Pixel- und Bytezahl."""
import pathlib
import struct
import subprocess
import sys
import zlib

root = pathlib.Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
ffmpeg = sys.argv[2]


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def png(path, width, height):
    encoder = zlib.compressobj()
    with path.open("wb") as output:
        output.write(b"\x89PNG\r\n\x1a\n")
        output.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        row = b"\0" + b"\x20\x80\xc0" * width
        for _ in range(height):
            data = encoder.compress(row)
            if data:
                output.write(chunk(b"IDAT", data))
        output.write(chunk(b"IDAT", encoder.flush()))
        output.write(chunk(b"IEND", b""))


png(root / "small.png", 64, 32)
png(root / "large.png", 12_000, 8_000)
# Gültiges privates PNG-Chunk vor IEND; die Bildpixel bleiben klein.
small = (root / "small.png").read_bytes()
(root / "oversized.png").write_bytes(
    small[:-12] + chunk(b"hkLp", bytes(33 * 1024 * 1024)) + small[-12:]
)
(root / "invalid.png").write_bytes(b"kein Bild")
subprocess.run([
    ffmpeg, "-nostdin", "-v", "error", "-f", "lavfi", "-i",
    "sine=frequency=440:duration=0.25", "-c:a", "libmp3lame", "-write_id3v1", "0",
    "-id3v2_version", "0", "-y", str(root / "audio.mp3")
], check=True)
audio = (root / "audio.mp3").read_bytes()


def mp3(name, images):
    frames = b""
    for image in images:
        payload = b"\0image/png\0\x03\0" + image
        frames += b"APIC" + struct.pack(">I", len(payload)) + b"\0\0" + payload
    size = len(frames)
    syncsafe = bytes((size >> shift) & 0x7f for shift in (21, 14, 7, 0))
    (root / name).write_bytes(b"ID3\x03\0\0" + syncsafe + frames + audio)


for name in ("small", "large", "oversized", "invalid"):
    mp3(name + ".mp3", [(root / (name + ".png")).read_bytes()])
mp3("later-valid.mp3", [b"defekt", small])
subprocess.run([
    ffmpeg, "-nostdin", "-v", "error", "-i", str(root / "audio.mp3"),
    "-i", str(root / "small.png"), "-map", "0:a", "-map", "1:v", "-c:a", "aac",
    "-c:v", "copy", "-disposition:v", "attached_pic", "-y", str(root / "small.m4a")
], check=True)
