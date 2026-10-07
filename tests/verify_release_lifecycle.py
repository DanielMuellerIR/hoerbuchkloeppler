"""DMG-Lifecycle in eigenen Ordnern mit kontrollierten Apple-Diensten."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


REPO = Path(__file__).resolve().parents[1]
APP_NAME = "Hörbuchklöppler.app"

WRAPPER = r'''#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
name, args = Path(sys.argv[0]).name, sys.argv[1:]
state_file = Path(os.environ["HK_RELEASE_STATE"])
state = json.loads(state_file.read_text()) if state_file.exists() else {"active": False, "detaches": 0}
failure = os.environ.get("HK_RELEASE_FAIL", "")
with open(os.environ["HK_RELEASE_LOG"], "a") as handle:
    handle.write(json.dumps({"tool": name, "args": args}) + "\n")
def save():
    state_file.write_text(json.dumps(state))
def fail(step):
    if failure == step:
        sys.exit(27)
if name == "install.sh":
    assert args == ["--no-install"], args
    fail("install")
    app = Path.cwd() / "Hörbuchklöppler.app/Contents"
    app.mkdir(parents=True)
    (app / "fixture.txt").write_text("complete app")
elif name == "hdiutil":
    command = args[0]
    if command == "create":
        fail("create")
        assert args[args.index("-srcfolder") + 1] == "./Hörbuchklöppler.app"
        assert args[args.index("-format") + 1] == "UDRW"
        Path(args[-1]).write_bytes(b"working-image")
        fail("create_partial")
    elif command == "attach":
        fail("attach")
        assert all(flag in args for flag in ("-nobrowse", "-noverify", "-noautoopen"))
        mount = Path(args[args.index("-mountpoint") + 1])
        shutil.copytree(Path.cwd() / "Hörbuchklöppler.app", mount / "Hörbuchklöppler.app")
        state.update(active=True, mount=str(mount))
        save()
        fail("attach_partial")
    elif command == "info":
        if failure in ("info", "info_detached") and "mount" in state:
            sys.exit(28)
        if state["active"]:
            print(state["mount"])
    elif command == "detach":
        state["detaches"] += 1
        save()
        mount = Path(state["mount"])
        if state["active"]:
            state["manifest"] = {
                "app": (mount / "Hörbuchklöppler.app/Contents/fixture.txt").is_file(),
                "notices": (mount / "THIRD-PARTY-NOTICES.md").is_file(),
                "applications": (mount / "Applications").is_symlink()
                    and os.readlink(mount / "Applications") == "/Applications",
            }
        save()
        if failure in ("detach", "info") or (failure == "detach_once" and state["detaches"] == 1):
            sys.exit(29)
        state["active"] = failure == "detach_lies"
        save()
    elif command == "convert":
        assert not state["active"], "Konvertierung bei aktivem Mount"
        fail("convert")
        assert args[args.index("-format") + 1] == "UDZO"
        Path(args[args.index("-o") + 1]).write_bytes(b"verified-new-image")
    else:
        raise RuntimeError(args)
elif name == "codesign":
    fail("sign")
elif name == "xcrun":
    if args[:2] == ["stapler", "validate"]:
        fail("app_validate" if args[-1].endswith(".app") else "dmg_validate")
    elif args[:2] == ["notarytool", "submit"]:
        fail("notary")
    elif args[:2] == ["notarytool", "history"]:
        fail("profile")
    elif args[:2] == ["stapler", "staple"]:
        fail("staple")
    else:
        raise RuntimeError(args)
elif name == "spctl":
    fail("gatekeeper")
elif name in ("git", "sync", "sleep"):
    pass
else:
    raise RuntimeError("Unerlaubtes Werkzeug im headless Test: " + name)
'''


def run_case(root, name, failure=None, arguments=("--no-finder-layout",), version="1.2.3"):
    case = root / name
    workspace = case / "workspace"
    workspace.mkdir(parents=True)
    wrappers = case / "wrappers"
    wrappers.mkdir()
    temporary = case / "temporary"
    temporary.mkdir()
    for script in ("release.sh", "script-helpers.sh", "notary-profile.sh"):
        shutil.copyfile(REPO / script, workspace / script)
    (workspace / "VERSION").write_text(version + "\n")
    if failure != "notices":
        shutil.copyfile(REPO / "THIRD-PARTY-NOTICES.md", workspace / "THIRD-PARTY-NOTICES.md")
    for tool in ("install.sh", "hdiutil", "codesign", "xcrun", "spctl", "git", "sync", "sleep", "osascript", "security"):
        path = (workspace if tool == "install.sh" else wrappers) / tool
        path.write_text(WRAPPER)
        path.chmod(0o755)
    dist = workspace / "dist"
    dist.mkdir()
    final = dist / "Hörbuchklöppler-1.2.3.dmg"
    final.write_bytes(b"previous-good-image")
    log = case / "calls.jsonl"
    state_file = case / "state.json"
    env = dict(os.environ, PATH=str(wrappers) + os.pathsep + os.environ["PATH"],
               TMPDIR=str(temporary), HK_RELEASE_LOG=str(log), HK_RELEASE_STATE=str(state_file),
               HK_RELEASE_FAIL=failure or "", HOERBUCHKLOEPPLER_SIGN_IDENTITY="Controlled Fixture Identity",
               NOTARY_PROFILE="controlled-fixture")
    result = subprocess.run(["bash", str(workspace / "release.sh"), *arguments],
                            env=env, capture_output=True, text=True, timeout=30)
    calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    success = failure in (None, "detach_once") and version == "1.2.3" and "--publish" not in arguments
    assert (result.returncode == 0) == success, (name, result.stdout, result.stderr)
    assert ("RELEASE OK:" in result.stdout) == success, name
    assert final.read_bytes() == (b"verified-new-image" if success else b"previous-good-image"), name
    preserved = failure in ("detach", "detach_lies", "info", "info_detached")
    assert not list(temporary.iterdir()), name
    preserved_work = list(dist.glob(".release-work.*"))
    assert bool(preserved_work) == preserved, (name, result.stderr)
    if preserved:
        assert len(preserved_work) == 1 and (preserved_work[0] / "working.dmg").exists(), name
    assert all(call["tool"] != "osascript" for call in calls), name
    if success:
        assert state["manifest"] == {"app": True, "notices": True, "applications": True}, state
        sequence = [(call["tool"], call["args"][:2]) for call in calls]
        working_image = next(call["args"][-1] for call in calls if call["tool"] == "hdiutil" and call["args"][0] == "create")
        ordered = [("install.sh", ["--no-install"]), ("xcrun", ["stapler", "validate"]),
                   ("hdiutil", ["create", "-srcfolder"]), ("hdiutil", ["attach", working_image]),
                   ("hdiutil", ["convert", working_image]),
                   ("codesign", ["--force", "--timestamp"]), ("xcrun", ["notarytool", "submit"]),
                   ("xcrun", ["stapler", "staple"]), ("xcrun", ["stapler", "validate"]),
                   ("spctl", ["--assess", "--type"])]
        cursor = 0
        for expected in ordered:
            cursor = sequence.index(expected, cursor) + 1
    if preserved:
        assert "temporäre Daten bleiben erhalten" in result.stderr, (name, result.stderr)
        assert not any(call["tool"] == "hdiutil" and call["args"][0] == "convert" for call in calls), name
    if failure == "detach":
        prior_image = preserved_work[0] / "working.dmg"
        before = prior_image.stat()
        prior_mount = dict(state)
        env["HK_RELEASE_FAIL"] = "install"
        again = subprocess.run(["bash", str(workspace / "release.sh"), *arguments],
                               env=env, capture_output=True, text=True, timeout=30)
        assert again.returncode != 0
        assert prior_image.read_bytes() == b"working-image"
        assert (prior_image.stat().st_dev, prior_image.stat().st_ino) == (before.st_dev, before.st_ino)
        assert state_file.exists() and json.loads(state_file.read_text())["mount"] == prior_mount["mount"]
        assert final.read_bytes() == b"previous-good-image"
        print("PASS: Wiederholung nach erhaltenem Mount bewahrt dessen Image und Inhalt")
    if version != "1.2.3" or "--publish" in arguments:
        assert not calls, (name, calls)
    print("PASS:", name)


def main():
    with tempfile.TemporaryDirectory(prefix="hk-release-fixtures-") as directory:
        root = Path(directory).resolve()
        for failure in (None, "install", "app_validate", "create", "create_partial", "attach", "attach_partial",
                        "notices", "detach_once", "detach", "detach_lies", "info", "info_detached", "convert",
                        "sign", "profile", "notary", "staple", "dmg_validate", "gatekeeper"):
            run_case(root, failure or "success", failure)
        run_case(root, "invalid_version", version="../invalid")
        run_case(root, "no_publish", arguments=("--publish",))


if __name__ == "__main__":
    main()
