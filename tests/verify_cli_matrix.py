"""CLI-Abnahme: echte Split-Ausgaben, Rückimport, Fehler und Signalabbruch."""

import argparse
import json
import os
import pathlib
import selectors
import signal
import subprocess
import tempfile
import time
from hashlib import sha256
from uuid import uuid4

from cli_temp import owned_temp_directories, system_temporary_directory, test_workspace

REPO = pathlib.Path(__file__).resolve().parents[1]
CLI = REPO / "HoerbuchkloepplerCore/.build/debug/kloeppler"
FF = REPO / "HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin/ffmpeg"


def verify(root):
    # Voraussetzungen vorab prüfen: ffmpeg liegt nicht im Repo (./build.sh --deps-only), die CLI kommt aus swift build.
    assert FF.exists(), f"ffmpeg fehlt: {FF} — vorher ./build.sh --deps-only ausführen"
    assert CLI.exists(), (
        f"kloeppler fehlt: {CLI} — vorher swift build --package-path HoerbuchkloepplerCore ausführen"
    )
    # Foundation kann TMPDIR auf macOS ignorieren. Deshalb den wirklichen
    # Systemordner beobachten und über .owner-pid ausschließlich eigene Läufe prüfen.
    cli_tmp = root / "tmp"
    cli_tmp.mkdir()
    environment = dict(os.environ, TMPDIR=str(cli_tmp))
    system_tmp = system_temporary_directory()
    report = []

    def tool(*args):
        return subprocess.run(
            [str(FF), "-v", "error", *map(str, args)], capture_output=True, check=True
        )

    def run(args, expected=0):
        start = time.monotonic()
        p = subprocess.run(
            [str(CLI), *map(str, args)],
            capture_output=True,
            timeout=300,
            env=environment,
        )
        (root / f"command-{len(report)}.stderr").write_bytes(p.stderr)
        assert p.returncode == expected, (args, p.returncode, p.stderr.decode()[-3000:])
        report.append(
            dict(
                args=list(map(str, args)),
                seconds=round(time.monotonic() - start, 3),
                exit=p.returncode,
            )
        )
        return p

    def decoded(path):
        p = subprocess.Popen(
            [
                str(FF),
                "-v",
                "error",
                "-i",
                str(path),
                "-map",
                "0:a:0",
                "-ac",
                "1",
                "-ar",
                "8000",
                "-f",
                "s16le",
                "-",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        count = 0
        while True:
            data = p.stdout.read(1024 * 1024)
            if not data:
                break
            count += len(data)
        assert p.wait() == 0, p.stderr.read().decode()
        return count / 2 / 8000

    def inspect(path):
        return json.loads(run(["--file", path, "--inspect", "--format", "json"]).stdout)

    # Argumentprüfung: ungültige Werte müssen als Usage-Fehler (64) enden, nicht als
    # gewöhnlicher Fehler. Bisher war davon keine einzige Grenze getestet.
    (root / "leer").mkdir()
    for bad in [
        ["--bitrate", "999k"],
        ["--bitrate", "7k"],
        ["--bitrate", "48"],
        ["--samplerate", "7999"],
        ["--samplerate", "48001"],
        ["--mode", "bogus"],
        ["--format", "JSON"],
        ["--max-duration", "-1"],
        ["--workers", "0"],
        ["--import-workers", "0"],
        ["--mono", "--stereo"],
        ["--no-cover", "--cover", root / "cover.png"],
        ["--language", "xx1"],
        ["--volume-number", "70000"],
        ["--volume-number", "+5"],
        ["--volume-number", "007"],
        ["--volume-number", "0"],
    ]:
        run([root / "leer", *bad], 64)
    # Gültige Randwerte dürfen NICHT abgelehnt werden; sie scheitern erst am leeren
    # Ordner (Exit 1), was die Grenzen von der Ordnerprüfung trennt.
    for good in [
        ["--bitrate", "8k"],
        ["--bitrate", "320k"],
        ["--samplerate", "8000"],
        ["--samplerate", "48000"],
        ["--mode", "StAnDaRd"],
        ["--mode", "bogus", "--mode", "PARALLEL"],
    ]:
        run([root / "leer", *good], 1)
    # Der GUI-Handoff (CLIInvocation) gibt Freitext als `--option=wert`. Genau das
    # muss der echte Parser annehmen — in der getrennten Form läse er einen Wert mit
    # führendem Bindestrich als Option. Kein Swift-Test schickt einen Handoff durch
    # den echten Parser, deshalb steht die Probe hier.
    run([root / "leer", "--title=-Aufzeichnungen"], 1)
    run([root / "leer", "--title", "-Aufzeichnungen"], 64)
    help_text = run(["--help"]).stdout
    assert run(["--mode", "bogus", "--format", "bogus", "--help"]).stdout == help_text
    print("usage exits OK", flush=True)
    for index in [1, 2]:
        tool(
            "-f",
            "lavfi",
            "-i",
            "anullsrc=r=8000:cl=mono",
            "-t",
            "1801",
            "-c:a",
            "flac",
            "-metadata",
            f"title=Kapitel {index}",
            "-metadata",
            "album=Matrixbuch",
            "-metadata",
            "artist=Autor",
            "-metadata",
            "album_artist=Verlag",
            root / f"{index}.flac",
        )
    tool(
        "-f",
        "lavfi",
        "-i",
        "color=c=blue:s=64x64",
        "-frames:v",
        "1",
        "-threads",
        "1",
        root / "cover.png",
    )
    files = ["--file", root / "2.flac", "--file", root / "1.flac"]
    p = run(
        [
            *files,
            "--inspect",
            "--format",
            "json",
            "--output",
            root / "absent" / "book.m4b",
            "--no-cover",
        ]
    )
    r = json.loads(p.stdout)
    assert [c["title"] for c in r["chapters"]] == ["Kapitel 2", "Kapitel 1"]
    assert r["metadata"]["title"] == "Matrixbuch", r["metadata"]
    assert r["metadata"]["author"] == "Autor", r["metadata"]
    assert not (root / "absent").exists()
    print("inspect order + headless metadata OK", flush=True)
    metadata = [
        "--title",
        "Matrixbuch",
        "--author",
        "Autor",
        "--narrator",
        "Sprecher",
        "--series",
        "Reihe",
        "--volume-number",
        "2",
        "--language",
        "deu",
        "--cover",
        root / "cover.png",
    ]
    for mode in ["standard", "parallel"]:
        p = run(
            [
                *files,
                *metadata,
                "--mode",
                mode,
                "--max-duration",
                "1",
                "--samplerate",
                "8000",
                "--bitrate",
                "24k",
                "--workers",
                "2",
                "--format",
                "json",
                "--output",
                root / f"{mode}.m4b",
            ]
        )
        events = [json.loads(line) for line in p.stdout.splitlines()]
        assert events[-1]["event"] == "finished" and events[-1]["success"], events[-1]
        assert all(e["schemaVersion"] == 2 and "success" in e for e in events), events
        assert all(
            e["success"] is None
            for e in events
            if e["event"] in ("started", "progress")
        ), events
        assert all(
            e["phase"]
            in (
                "input",
                "preparing",
                "measuring_loudness",
                "decoding",
                "encoding",
                "muxing",
            )
            for e in events
        ), events
        outputs = list(map(pathlib.Path, events[-1]["outputs"]))
        assert len(outputs) == 2, outputs
        for index, path in enumerate(outputs):
            r = inspect(path)
            assert r["hasCover"], r
            assert r["metadata"]["narrator"] == "Sprecher", r["metadata"]
            assert r["metadata"]["series"] == "Reihe", r["metadata"]
            assert r["metadata"]["volumeNumber"] == "2", r["metadata"]
            assert r["metadata"]["language"] == "deu", r["metadata"]
            assert len(r["chapters"]) == 1, r["chapters"]
            assert r["chapters"][0]["title"] == f"Kapitel {2 - index}", r["chapters"]
            seconds = decoded(path)
            # Einzelsegment: höchstens zwei AAC-Rahmen Randabweichung bei 8 kHz.
            assert abs(seconds - 1801) <= 2 * 1024 / 8000, (path, seconds)
            report.append(
                dict(
                    mode=mode,
                    output=path.name,
                    decodedSeconds=seconds,
                    chapter=r["chapters"][0],
                    metadata=r["metadata"],
                    cover=r["hasCover"],
                )
            )
            print(
                mode,
                path.name,
                "decodedSeconds",
                seconds,
                "metadata+cover reimport OK",
                flush=True,
            )

    with tempfile.TemporaryDirectory(prefix="HB_Temp_probe-", dir=system_tmp) as probe:
        leftover_probe = pathlib.Path(probe)
        (leftover_probe / ".owner-pid").write_text(str(os.getpid()))
        assert leftover_probe in owned_temp_directories(system_tmp, os.getpid())
        assert leftover_probe not in owned_temp_directories(system_tmp, -1)

    def abort(sig, analyze=False):
        observed = set()
        target = root / ("cancel-analysis.m4b" if analyze else "cancel-encoding.m4b")
        previous_output = b"Ausgabe vor der Lautheitsanalyse"
        args = [
            str(CLI),
            *map(str, files),
            "--no-cover",
            "--mode",
            "standard",
            "--samplerate",
            "48000",
            "--format",
            "json",
            "--output",
            str(target),
        ]
        if analyze:
            target.write_bytes(previous_output)
            args += ["--analyze-loudness", "--force"]
        p = subprocess.Popen(
            args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment
        )
        selector = selectors.DefaultSelector()
        selector.register(p.stderr, selectors.EVENT_READ, "err")
        selector.register(p.stdout, selectors.EVENT_READ, "out")
        buffers = {"err": b"", "out": b""}
        sent = None
        deadline = time.monotonic() + 60
        while p.poll() is None and time.monotonic() < deadline:
            observed.update(owned_temp_directories(system_tmp, p.pid))
            for key, _ in selector.select(0.1):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                buffers[key.data] += chunk
            marker = b"Lautheitsanalyse:" if analyze else b'"event":"started"'
            combined = buffers["err"] if analyze else buffers["out"]
            if sent is None and marker in combined and observed:
                if analyze:
                    p.send_signal(signal.SIGSTOP)
                    try:
                        competitor = run(
                            [
                                "--file",
                                root / "1.flac",
                                "--no-cover",
                                "--force",
                                "--format",
                                "json",
                                "--output",
                                target,
                            ],
                            1,
                        )
                        assert (
                            "verwendet bereits dieses Ziel"
                            in competitor.stderr.decode()
                        ), competitor.stderr
                        assert target.read_bytes() == previous_output
                    finally:
                        p.send_signal(sig)
                        p.send_signal(signal.SIGCONT)
                else:
                    time.sleep(0.15)
                    p.send_signal(sig)
                sent = time.monotonic()
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
            assert False, ("Cancellation timeout", buffers["err"].decode()[-2000:])
        out, err = p.communicate()
        buffers["out"] += out
        buffers["err"] += err
        assert sent is not None, "Signal marker missing"
        assert p.returncode == 128 + sig, (
            p.returncode,
            buffers["err"].decode()[-3000:],
        )
        events = [json.loads(line) for line in buffers["out"].splitlines()]
        assert events[-1]["event"] == "cancelled", events
        assert observed, "Kein echter Core-Arbeitsordner beobachtet"
        if analyze:
            assert target.read_bytes() == previous_output
        else:
            assert not target.exists()
        assert not owned_temp_directories(system_tmp, p.pid)
        assert not any(path.exists() for path in observed), observed
        assert not list(root.rglob("*.partial*"))
        report.append(
            dict(
                signal=sig,
                analysis=analyze,
                exit=p.returncode,
                cancelSeconds=round(time.monotonic() - sent, 3),
                cleanup=True,
            )
        )
        print("cancel", sig, "analysis", analyze, report[-1], flush=True)
        if analyze:
            run(
                ["--file", root / "1.flac", "--no-cover", "--force", "--output", target]
            )
            assert decoded(target) > 0

    abort(signal.SIGINT)
    abort(signal.SIGTERM, True)
    (root / "bad.wav").write_bytes(b"not audio")
    p = run(
        ["--file", root / "bad.wav", "--format", "json", "--output", root / "bad.m4b"],
        1,
    )
    events = [json.loads(line) for line in p.stdout.splitlines()]
    assert events[-1]["event"] == "failed"
    assert not (root / "bad.m4b").exists()
    # --inspect --format json gibt auch bei einem frühen Fehler genau eine JSON-Zeile
    # aus; sonst bekäme ein Konsument einen Parserfehler statt einer Diagnose.
    p = run(["--file", root / "gibtsnicht.wav", "--inspect", "--format", "json"], 1)
    events = [json.loads(line) for line in p.stdout.splitlines()]
    assert (
        len(events) == 1
        and events[0]["event"] == "failed"
        and events[0]["success"] is False
    ), events
    for invalid_folder in [root / "gibtsnicht", root / "bad.wav"]:
        p = run([invalid_folder, "--inspect", "--format", "json"], 1)
        events = [json.loads(line) for line in p.stdout.splitlines()]
        assert (
            len(events) == 1
            and events[0]["event"] == "failed"
            and events[0]["success"] is False
        ), events
    # `--normalize-loudness` erreicht sonst nirgends das echte Binary: Der Swift-Test
    # durchsucht nur die selbst gebaute Argumentliste des GUI-Handoffs.
    run([root / "leer", "--normalize-loudness", "--analyze-loudness"], 1)
    print("inspect failure json OK", flush=True)
    # Eine Projektdatei mit nicht lesbarer Versionsangabe bekommt eine klare
    # Meldung statt eines rohen Decoding-Fehlers.
    (root / "fremd.hkproject").write_text(
        '{"formatVersion":"2","sources":[],"sections":[]}'
    )
    p = run(["--project", root / "fremd.hkproject", "--inspect"], 1)
    assert b"Projektversion ist keine Zahl" in p.stderr, p.stderr[-500:]
    print("project version diagnosis OK", flush=True)
    # Ohne --output benennt sich die Ausgabe nach dem Titel-Tag beziehungsweise dem
    # Quellnamen OHNE dessen Endung — nicht "1.flac.m4b".
    untagged = root / "ohnetag"
    untagged.mkdir()
    tool(
        "-f",
        "lavfi",
        "-i",
        "anullsrc=r=8000:cl=mono",
        "-t",
        "1",
        "-c:a",
        "flac",
        untagged / "kapitel.flac",
    )
    r = json.loads(
        run(
            ["--file", untagged / "kapitel.flac", "--inspect", "--format", "json"]
        ).stdout
    )
    assert [pathlib.Path(o).name for o in r["outputs"]] == ["kapitel.m4b"], r["outputs"]
    # Vorhandene Zieldatei ohne --force und ohne Terminal: Abbruch mit Hinweis.
    (untagged / "kapitel.m4b").write_bytes(b"alt")
    p = run(["--file", untagged / "kapitel.flac"], 1)
    assert b"--force" in p.stderr, p.stderr[-500:]
    assert (untagged / "kapitel.m4b").read_bytes() == b"alt"
    p = run(
        [
            "--file",
            untagged / "kapitel.flac",
            "--force",
            "--bitrate",
            "24k",
            "--samplerate",
            "8000",
        ]
    )
    assert (untagged / "kapitel.m4b").read_bytes() != b"alt"
    print("default name and overwrite OK", flush=True)

    # Ein vorhandenes Projekt muss nach dem Ersetzen des Import-Kontexts weiterhin
    # seine Quellen prüfen und exportieren können.
    project_source = untagged / "kapitel.flac"
    source_bytes = project_source.read_bytes()
    source_id = str(uuid4())
    location = {"path": "ohnetag/kapitel.flac", "isRelative": True}
    project = root / "Buch.hkproject"
    project.write_text(
        json.dumps(
            {
                "formatVersion": 1,
                "sources": [
                    {
                        "id": source_id,
                        "location": location,
                        "readLocation": location,
                        "sha256": sha256(source_bytes).hexdigest(),
                    }
                ],
                "sections": [
                    {
                        "id": str(uuid4()),
                        "sourceID": source_id,
                        "start": 0,
                        "duration": 1,
                        "title": "Projektkapitel",
                    }
                ],
            }
        )
    )
    project_output = root / "Projekt.m4b"
    project_args = [
        "--project",
        project,
        "--format",
        "json",
        "--output",
        project_output,
    ]
    inspection = json.loads(run([*project_args, "--inspect"]).stdout)
    assert (
        not inspection["sourceIssues"]
        and inspection["chapters"][0]["title"] == "Projektkapitel"
    ), inspection
    events = [json.loads(line) for line in run(project_args).stdout.splitlines()]
    assert events[-1]["event"] == "finished" and project_output.stat().st_size > 0, (
        events
    )
    exported_bytes = project_output.read_bytes()
    project_source.write_bytes(source_bytes + b"changed")
    inspection = json.loads(run([*project_args, "--inspect"], 1).stdout)
    assert inspection["sourceIssues"][0]["reason"] == "Quelle wurde verändert", (
        inspection
    )
    event = json.loads(run([*project_args, "--force"], 1).stdout)
    assert (
        event["event"] == "failed" and project_output.read_bytes() == exported_bytes
    ), event
    project_source.write_bytes(source_bytes)
    print("project inspect, export and changed source OK", flush=True)

    (root / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False))
    print("CLI-Matrix geprüft", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--keep-temp", action="store_true", help="Testdaten auch nach Erfolg behalten."
    )
    with test_workspace("hk-cli-matrix-", keep=parser.parse_args().keep_temp) as work:
        verify(work)
