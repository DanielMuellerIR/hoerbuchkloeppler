"""Kapitelmarken und Audioübergänge eines echten M4B-Exports vergleichen."""

import argparse
import array
import hashlib
import json
import math
import subprocess
import uuid
import wave
from pathlib import Path

from cli_temp import test_workspace

REPO = Path(__file__).resolve().parents[1]
CLI = REPO / "HoerbuchkloepplerCore/.build/debug/kloeppler"
FFMPEG = (
    REPO / "HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin/ffmpeg"
)
SAMPLE_RATE = 32_000
CHAPTER_LENGTHS = (0.6, 0.7, 0.8)
FREQUENCIES = (660, 440, 880)


def make_project(root):
    sources = []
    sections = []
    for index, (frequency, duration) in enumerate(zip(FREQUENCIES, CHAPTER_LENGTHS)):
        path = root / f"{index}.wav"
        with wave.open(str(path), "wb") as audio:
            audio.setparams((1, 2, SAMPLE_RATE, 0, "NONE", "not compressed"))
            samples = array.array(
                "h",
                (
                    int(4000 * math.sin(math.tau * frequency * n / SAMPLE_RATE))
                    for n in range(2 * SAMPLE_RATE)
                ),
            )
            audio.writeframes(samples.tobytes())
        source_id = str(uuid.uuid4())
        location = {"path": path.name, "isRelative": True}
        sources.append(
            {
                "id": source_id,
                "location": location,
                "readLocation": location,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            }
        )
        sections.append(
            {
                "id": str(uuid.uuid4()),
                "sourceID": source_id,
                "start": 0.1,
                "duration": duration,
                "title": f"Kapitel {index + 1}",
            }
        )
    project = root / "book.hkproject"
    project.write_text(
        json.dumps(
            {
                "formatVersion": 1,
                "sources": sources,
                "sections": sections,
                "metadata": {
                    "title": "Übergänge",
                    "genre": "Hörbuch",
                    "language": "deu",
                },
                "settings": {},
                "coverSuppressed": True,
            }
        )
    )
    return project


def read_chapter_marks(path):
    metadata = subprocess.check_output(
        [FFMPEG, "-nostdin", "-v", "error", "-i", path, "-f", "ffmetadata", "-"],
        text=True,
        timeout=30,
    )
    starts = []
    for block in metadata.split("[CHAPTER]")[1:]:
        fields = dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
        numerator, denominator = map(int, fields["TIMEBASE"].split("/"))
        starts.append(int(fields["START"]) * numerator / denominator)
    return starts


def find_audio_starts(samples):
    window = 320
    # Projektion auf die drei Tonfrequenzen, in 5-ms-Schritten.
    basis = [
        [
            complex(math.cos(phase), -math.sin(phase))
            for phase in (math.tau * frequency * n / SAMPLE_RATE for n in range(window))
        ]
        for frequency in FREQUENCIES
    ]
    starts = {}
    for offset in range(0, len(samples) - window, 160):
        block = samples[offset : offset + window]
        scores = [
            abs(sum(value * component for value, component in zip(block, tone))) ** 2
            / window**2
            for tone in basis
        ]
        dominant = max(range(len(scores)), key=scores.__getitem__)
        others = [score for index, score in enumerate(scores) if index != dominant]
        if scores[dominant] > 1e6 and scores[dominant] > max(others) * 3:
            starts.setdefault(dominant, offset / SAMPLE_RATE)
        if len(starts) == len(FREQUENCIES):
            return [starts[index] for index in range(len(FREQUENCIES))]
    raise AssertionError(f"Nicht alle Kapiteltöne im Export erkannt: {starts}")


def verify(root):
    assert FFMPEG.exists(), (
        f"ffmpeg fehlt: {FFMPEG}. Vorher ./build.sh --deps-only ausführen."
    )
    assert CLI.exists(), (
        f"kloeppler fehlt: {CLI}. Vorher swift build --package-path HoerbuchkloepplerCore ausführen."
    )
    project = make_project(root)
    expected_starts = [0.0, CHAPTER_LENGTHS[0], sum(CHAPTER_LENGTHS[:2])]
    report = []
    for mode in ("standard", "parallel"):
        output = root / f"{mode}.m4b"
        result = subprocess.run(
            [
                CLI,
                "--project",
                project,
                "--mode",
                mode,
                "--format",
                "json",
                "--output",
                output,
                "--samplerate",
                str(SAMPLE_RATE),
                "--mono",
            ],
            capture_output=True,
            check=True,
            timeout=30,
        )
        assert json.loads(result.stdout.splitlines()[-1])["success"]
        decoded = subprocess.check_output(
            [
                FFMPEG,
                "-nostdin",
                "-v",
                "error",
                "-i",
                output,
                "-map",
                "0:a:0",
                "-f",
                "s16le",
                "-",
            ],
            timeout=30,
        )
        samples = array.array("h", decoded)
        audio_starts = find_audio_starts(samples)
        marks = read_chapter_marks(output)
        assert len(marks) == len(expected_starts), (mode, marks)
        segment_padding = (2112 + 2048) if mode == "parallel" else 0
        for index, (actual, mark, expected) in enumerate(
            zip(audio_starts, marks, expected_starts)
        ):
            assert abs(mark - expected) <= 0.0011, (mode, marks)
            # AAC_AT-Priming plus höchstens zwei Padding-Rahmen je Segment.
            bound = (2048 + index * segment_padding) / SAMPLE_RATE
            assert abs(actual - expected) <= bound, (
                mode,
                index,
                actual,
                expected,
                bound,
            )
        duration = len(samples) / SAMPLE_RATE
        duration_bound = (
            2048 + (len(CHAPTER_LENGTHS) - 1) * segment_padding
        ) / SAMPLE_RATE
        assert abs(duration - sum(CHAPTER_LENGTHS)) <= duration_bound, (
            mode,
            duration,
            duration_bound,
        )
        report.append(
            {
                "mode": mode,
                "decodedSeconds": duration,
                "audioStarts": audio_starts,
                "chapterMarks": marks,
            }
        )
    (root / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--keep-temp", action="store_true", help="Testdaten auch nach Erfolg behalten."
    )
    with test_workspace(
        "kloeppler-transitions-", keep=parser.parse_args().keep_temp
    ) as work:
        verify(work)
