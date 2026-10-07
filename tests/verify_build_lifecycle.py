"""Unverändertes Build-Skript mit kontrollierten Downloads und Compilern."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


REPO = Path(__file__).resolve().parents[1]
BIN_DIR = Path("HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore/Resources/bin")
APP_NAME = "Hörbuchklöppler.app"

WRAPPER = r'''#!/usr/bin/env python3
import json, os, sys, tempfile
from pathlib import Path
name, args = Path(sys.argv[0]).name, sys.argv[1:]
failure = os.environ.get("HK_BUILD_FAIL", "")
state_file = Path(os.environ["HK_BUILD_STATE"])
state = json.loads(state_file.read_text()) if state_file.exists() else {"active": False, "detaches": 0}
with open(os.environ["HK_BUILD_LOG"], "a") as handle:
    handle.write(json.dumps({"tool": name, "args": args, "cwd": str(Path.cwd())}) + "\n")
def fail(step):
    if failure == step:
        sys.exit(27)
def save():
    state_file.write_text(json.dumps(state))
def write_binary(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(Path(os.environ["HK_BUILD_WRAPPER"]).read_text())
    path.chmod(0o755)
if name == "mktemp":
    assert args == ["-d"]
    print(tempfile.mkdtemp(prefix="build-download-", dir=os.environ["TMPDIR"]))
elif name == "shasum":
    target = Path(args[-1])
    label = {"ffmpeg.zip": "FFMPEG_ARCHIVE", "mediainfo.dmg": "MEDIAINFO_ARCHIVE",
             "ffmpeg": "FFMPEG_BINARY", "mediainfo": "MEDIAINFO_BINARY"}[target.name]
    hashes = json.loads(os.environ["HK_BUILD_HASHES"])
    digest = hashes[label]
    if failure == "checksum:" + label or target.read_bytes() == b"corrupt":
        digest = "0" * 64
    print(digest + "  " + str(target))
elif name == "curl":
    target = Path(args[args.index("-o") + 1])
    assert "--retry" in args and "--max-time" in args
    assert args[args.index("--max-time") + 1] == "300"
    assert any(arg.startswith("https://") for arg in args)
    fail("curl:" + target.name)
    target.write_bytes(b"controlled-archive")
elif name == "unzip":
    fail("unzip")
    if failure != "missing_ffmpeg":
        write_binary(Path(args[args.index("-d") + 1]) / "ffmpeg")
elif name == "hdiutil":
    if args[0] == "attach":
        fail("attach")
        assert "-nobrowse" in args and "-readonly" in args
        mount = Path(args[args.index("-mountpoint") + 1])
        mount.mkdir()
        if failure != "missing_pkg":
            (mount / "fixture.pkg").write_text("controlled-package")
        state.update(active=True, mount=str(mount.resolve()))
        save()
        fail("attach_partial")
    elif args[0] == "info":
        if failure in ("info", "info_detached") and "mount" in state:
            sys.exit(28)
        if state["active"]:
            print(state["mount"])
    elif args[0] == "detach":
        state["detaches"] += 1
        save()
        if failure in ("detach", "info"):
            sys.exit(29)
        state["active"] = failure == "detach_lies"
        save()
    else:
        raise RuntimeError(args)
elif name == "pkgutil":
    assert args[0] == "--expand-full"
    fail("pkgutil")
    if failure != "missing_mediainfo":
        write_binary(Path(args[-1]) / "Payload/usr/local/bin/mediainfo")
    else:
        Path(args[-1]).mkdir()
elif name in ("ffmpeg", "mediainfo"):
    fail("runtime:" + name)
    if failure != "empty_runtime:" + name:
        print("Controlled " + name + " version")
elif name == "swift":
    assert args == ["build", "-c", "release"], args
    fail("swift")
    output = Path.cwd() / ".build/release/kloeppler"
    output.parent.mkdir(parents=True)
    output.write_text("controlled CLI")
elif name == "xcodebuild":
    assert "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES" not in args
    assert "MARKETING_VERSION=1.2.3" in args and "CODE_SIGNING_ALLOWED=NO" in args
    assert args[args.index("-destination") + 1] == "platform=macOS"
    fail("xcodebuild")
    output = Path.cwd() / "build/Build/Products/Release"
    output.mkdir(parents=True)
    if failure != "missing_app":
        app = output / "Hörbuchklöppler.app/Contents"
        app.mkdir(parents=True)
        (app / "fixture.txt").write_text("new-app")
elif name == "sign-bundle.sh":
    assert args == ["./Hörbuchklöppler.app", "-"], args
    assert (Path(args[0]) / "Contents/fixture.txt").read_text() == "new-app"
    fail("sign")
else:
    raise RuntimeError("Unbekanntes Fixture-Werkzeug: " + name)
'''


def run_case(root, name, *, arguments=(), failure=None, cached=True, version="1.2.3", success=True):
    case = root / name
    workspace = case / "workspace"
    workspace.mkdir(parents=True)
    wrappers = case / "wrappers"
    wrappers.mkdir()
    temporary = case / "temporary"
    temporary.mkdir()
    for script in ("build.sh", "script-helpers.sh"):
        shutil.copyfile(REPO / script, workspace / script)
    (workspace / "VERSION").write_text(version + "\n")
    (workspace / "HoerbuchkloepplerCore").mkdir()
    for tool in ("mktemp", "shasum", "curl", "unzip", "hdiutil", "pkgutil", "swift", "xcodebuild", "sign-bundle.sh"):
        path = (workspace if tool == "sign-bundle.sh" else wrappers) / tool
        path.write_text(WRAPPER)
        path.chmod(0o755)
    if cached:
        for tool in ("ffmpeg", "mediainfo"):
            path = workspace / BIN_DIR / tool
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"corrupt" if cached == "corrupt" else WRAPPER.encode())
            path.chmod(0o644 if cached == "nonexecutable" else 0o755)
    old_app = workspace / APP_NAME / "Contents/fixture.txt"
    old_app.parent.mkdir(parents=True)
    old_app.write_text("previous-app")
    log, state_file = case / "calls.jsonl", case / "state.json"
    source = (REPO / "build.sh").read_text()
    hashes = dict(re.findall(r'(FFMPEG_ARCHIVE|FFMPEG_BINARY|MEDIAINFO_ARCHIVE|MEDIAINFO_BINARY)_SHA256="([a-f0-9]+)"', source))
    assert len(hashes) == 4
    env = dict(os.environ, PATH=str(wrappers) + os.pathsep + os.environ["PATH"], TMPDIR=str(temporary),
               HK_BUILD_LOG=str(log), HK_BUILD_STATE=str(state_file), HK_BUILD_HASHES=json.dumps(hashes),
               HK_BUILD_WRAPPER=str(wrappers / "shasum"), HK_BUILD_FAIL=failure or "")
    result = subprocess.run(["bash", str(workspace / "build.sh"), *arguments],
                            env=env, capture_output=True, text=True, timeout=30)
    calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    assert (result.returncode == 0) == success, (name, result.stdout, result.stderr)
    preserved = failure in ("detach", "detach_lies", "info", "info_detached")
    assert bool(list(temporary.iterdir())) == preserved, (name, result.stderr)
    assert preserved or not state.get("active", False), (name, state)
    if preserved:
        assert "temporäre Daten bleiben erhalten" in result.stderr, (name, result.stderr)
    invoked = [call["tool"] for call in calls]
    if "--help" in arguments or "--unknown" in arguments:
        assert not calls, name
        assert result.returncode == (0 if success else 64)
    elif success:
        deps_only = "--deps-only" in arguments
        cli_only = "--cli-only" in arguments
        assert ("swift" in invoked) == (not deps_only), name
        assert ("xcodebuild" in invoked) == (not deps_only and not cli_only), name
        assert ("sign-bundle.sh" in invoked) == (not deps_only and not cli_only), name
        assert old_app.read_text() == ("previous-app" if deps_only or cli_only else "new-app"), name
        assert invoked.count("curl") == (2 if cached is not True or "--force-deps" in arguments else 0), name
        if not deps_only and not cli_only:
            assert invoked.index("swift") < invoked.index("xcodebuild") < invoked.index("sign-bundle.sh"), name
            assert "App gebaut:" in result.stdout
    else:
        assert "App gebaut:" not in result.stdout and "Fertig." not in result.stdout, name
        if failure != "sign":
            assert old_app.read_text() == "previous-app", name
        if failure not in ("swift", "xcodebuild", "missing_app", "sign") and version == "1.2.3":
            assert "swift" not in invoked and "xcodebuild" not in invoked, name
    print("PASS:", name)


def main():
    with tempfile.TemporaryDirectory(prefix="hk-build-fixtures-") as directory:
        root = Path(directory).resolve()
        for name, arguments, cached in [("full_cached", (), True), ("deps_only", ("--deps-only",), False),
                                       ("cli_only", ("--cli-only",), True), ("force_deps", ("--force-deps",), True),
                                       ("corrupt_cache", ("--deps-only",), "corrupt"),
                                       ("nonexecutable_cache", ("--deps-only",), "nonexecutable")]:
            run_case(root, name, arguments=arguments, cached=cached)
        for failure in ("curl:ffmpeg.zip", "unzip", "missing_ffmpeg", "checksum:FFMPEG_ARCHIVE", "checksum:FFMPEG_BINARY",
                        "curl:mediainfo.dmg", "checksum:MEDIAINFO_ARCHIVE", "attach", "attach_partial", "missing_pkg", "pkgutil",
                        "detach", "detach_lies", "info", "info_detached", "missing_mediainfo", "checksum:MEDIAINFO_BINARY",
                        "runtime:ffmpeg", "runtime:mediainfo", "empty_runtime:ffmpeg", "empty_runtime:mediainfo"):
            run_case(root, failure.replace(":", "_"), failure=failure, cached=False, success=False)
        for failure in ("swift", "xcodebuild", "missing_app", "sign"):
            run_case(root, failure, failure=failure, success=False)
        run_case(root, "invalid_version", version="../../invalid", success=False)
        run_case(root, "unknown_option", arguments=("--unknown",), success=False)
        run_case(root, "help", arguments=("--help",))


if __name__ == "__main__":
    main()
