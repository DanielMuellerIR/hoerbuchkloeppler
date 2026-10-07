"""Begrenzte macOS-Langbuchmessung der vorhandenen CLI, kein Leistungstest-Gate."""

import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import time


REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tests"))
from cli_temp import owned_temp_directories, system_temporary_directory

CLI = REPO / "HoerbuchkloepplerCore/.build/release/kloeppler"
FFMPEG = REPO / "HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin/ffmpeg"
INTERVAL = 0.25
MAXIMUM_SECONDS = 900
MAXIMUM_TEMP_BYTES = 4 * 1024**3


def sizes(directory, excluded=None):
    logical = allocated = 0
    for root, _, names in os.walk(directory):
        for name in names:
            path = Path(root) / name
            if path == excluded:
                continue
            try:
                stat = path.stat()
            except FileNotFoundError:
                continue
            logical += stat.st_size
            allocated += stat.st_blocks * 512
    return logical, allocated


def process_memory(root_pid):
    snapshot = subprocess.check_output(
        ["/bin/ps", "-A", "-o", "pid=,ppid=,rss="], text=True
    )
    rows = [tuple(map(int, line.split())) for line in snapshot.splitlines()]
    owned = {root_pid}
    while True:
        descendants = {pid for pid, parent, _ in rows if parent in owned}
        if descendants <= owned:
            break
        owned.update(descendants)
    cli = sum(rss * 1024 for pid, _, rss in rows if pid == root_pid)
    children = sum(rss * 1024 for pid, _, rss in rows if pid in owned and pid != root_pid)
    return cli, children, sum(pid in owned for pid, _, _ in rows)


def stop(process):
    if process.poll() is None:
        process.send_signal(signal.SIGINT)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def measure(root, sources, mode):
    work = root / mode
    temporary = work / "tmp"
    output_dir = work / "output"
    temporary.mkdir(parents=True)
    output_dir.mkdir()
    output = output_dir / "Langbuch.m4b"
    args = [str(CLI), str(sources), "--mode", mode, "--workers", "4",
            "--import-workers", "4", "--mono", "--samplerate", "32000",
            "--bitrate", "48k", "--max-duration", "0", "--no-cover",
            "--title", "Synthetisches Langbuch", "--format", "json", "--output", str(output)]
    samples = []
    observed_temp = set()
    system_temp = system_temporary_directory()
    start = time.monotonic()
    with (work / "events.jsonl").open("wb") as stdout, (work / "stderr.log").open("wb") as stderr:
        process = subprocess.Popen(args, stdout=stdout, stderr=stderr,
                                   env=dict(os.environ, TMPDIR=str(temporary)))
        try:
            while process.poll() is None:
                cli_rss, child_rss, process_count = process_memory(process.pid)
                own_temp = owned_temp_directories(system_temp, process.pid)
                observed_temp.update(own_temp)
                temp_sizes = [sizes(path) for path in own_temp]
                temp_logical = sum(logical for logical, _ in temp_sizes)
                temp_allocated = sum(allocated for _, allocated in temp_sizes)
                staging_logical, staging_allocated = sizes(output_dir, excluded=output)
                sample = dict(seconds=time.monotonic() - start, cli_rss=cli_rss,
                              child_rss=child_rss, process_count=process_count,
                              temp_logical=temp_logical, temp_allocated=temp_allocated,
                              staging_logical=staging_logical, staging_allocated=staging_allocated)
                samples.append(sample)
                if sample["seconds"] > MAXIMUM_SECONDS:
                    raise RuntimeError("Messfrist von 15 Minuten überschritten")
                if max(temp_logical + staging_logical, temp_allocated + staging_allocated) > MAXIMUM_TEMP_BYTES:
                    raise RuntimeError("Grenze von 4 GiB temporären Daten überschritten")
                time.sleep(INTERVAL)
            elapsed = time.monotonic() - start
        finally:
            stop(process)
            (work / "samples.json").write_text(json.dumps(samples, indent=2) + "\n")
    assert process.returncode == 0, (mode, process.returncode)
    events = [json.loads(line) for line in (work / "events.jsonl").read_text().splitlines()]
    assert events[-1]["event"] == "finished" and events[-1]["success"] is True
    inspected = subprocess.run([str(CLI), "--file", str(output), "--inspect", "--format", "json"],
                               capture_output=True, text=True, timeout=60, check=True)
    inspection = json.loads(inspected.stdout)
    assert len(inspection["chapters"]) == 12
    for index, chapter in enumerate(inspection["chapters"]):
        assert chapter["title"] == f"Kapitel {index + 1:02d}", chapter
        assert abs(chapter["start"] - index * 3600) < 0.5, chapter
        assert abs(chapter["duration"] - 3600) < 0.5, chapter
    # Vollständig dekodieren, ohne PCM-Datei oder viele GiB Python-Daten anzulegen.
    decoded = subprocess.run([str(FFMPEG), "-nostdin", "-v", "error", "-xerror", "-i", str(output),
                              "-map", "0:a:0", "-progress", "pipe:1", "-f", "null", "-"],
                             capture_output=True, text=True, timeout=180, check=True)
    decoded_seconds = int([line.split("=", 1)[1] for line in decoded.stdout.splitlines()
                           if line.startswith("out_time_us=")][-1]) / 1_000_000
    assert abs(decoded_seconds - 43_200) <= 14 * 1024 / 32_000, decoded_seconds
    assert observed_temp, "Tatsächlicher Core-Arbeitsordner wurde nicht beobachtet"
    assert not owned_temp_directories(system_temp, process.pid)
    assert not any(path.exists() for path in observed_temp), "Temporäre Audiodaten nach Erfolg übrig"
    remaining = [path for path in output_dir.iterdir()
                 if not (path.name.startswith(".hoerbuchkloeppler-")
                         and path.suffix == ".lock" and path.stat().st_size == 0)]
    assert remaining == [output], "Ausgabe-Staging nach Erfolg übrig"
    result = dict(mode=mode, seconds=elapsed, output_bytes=output.stat().st_size,
                  sample_count=len(samples), cleanup=True, decoded_without_error=True,
                  decoded_timeline_seconds=decoded_seconds,
                  chapters=inspection["chapters"],
                  cli_peak_rss=max(s["cli_rss"] for s in samples),
                  tree_peak_rss=max(s["cli_rss"] + s["child_rss"] for s in samples),
                  peak_process_count=max(s["process_count"] for s in samples),
                  peak_temp_logical=max(s["temp_logical"] for s in samples),
                  peak_temp_allocated=max(s["temp_allocated"] for s in samples),
                  peak_combined_logical=max(s["temp_logical"] + s["staging_logical"] for s in samples),
                  peak_combined_allocated=max(s["temp_allocated"] + s["staging_allocated"] for s in samples))
    print(json.dumps({k: v for k, v in result.items() if k != "chapters"}), flush=True)
    return result


def main():
    assert platform.system() == "Darwin", "Benötigt macOS und aac_at"
    assert CLI.is_file() and FFMPEG.is_file(), "Zuerst Release-CLI und gebündeltes ffmpeg bauen"
    root = Path(tempfile.mkdtemp(prefix="hk-long-book-"))
    print("Messordner:", root, flush=True)
    report = dict(commit=subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
                  cli_sha256=hashlib.sha256(CLI.read_bytes()).hexdigest(),
                  system=platform.platform(), sample_interval_seconds=INTERVAL, results=[])
    report_path = root / "report.json"
    sources = root / "sources"
    sources.mkdir()
    seed = root / "seed.flac"
    subprocess.run([str(FFMPEG), "-nostdin", "-v", "error", "-f", "lavfi", "-i",
                    "sine=frequency=220:sample_rate=32000:duration=3600", "-ac", "1",
                    "-c:a", "flac", str(seed)], capture_output=True, timeout=180, check=True)
    for index in range(12):
        shutil.copyfile(seed, sources / f"Kapitel {index + 1:02d}.flac")
    report["source_bytes"] = sizes(sources)[0]
    report["ffmpeg_version"] = subprocess.check_output([str(FFMPEG), "-version"], text=True).splitlines()[0]
    try:
        for mode in ("standard", "parallel"):
            report["results"].append(measure(root, sources, mode))
            report_path.write_text(json.dumps(report, indent=2) + "\n")
    finally:
        report_path.write_text(json.dumps(report, indent=2) + "\n")
    print("VERIFIED", report_path, flush=True)


if __name__ == "__main__":
    main()
