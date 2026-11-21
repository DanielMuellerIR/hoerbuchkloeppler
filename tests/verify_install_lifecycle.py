"""Installationsablauf mit kontrollierten Diensten und wirklichem Dateiaustausch."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import signal

from cli_temp import test_workspace


REPO = Path(__file__).resolve().parents[1]
APP_NAME = "Hörbuchklöppler.app"
REAL_TOOLS = {name: shutil.which(name) for name in ("ditto", "pgrep", "ps", "clang", "xcrun", "git", "swift")}
assert all(REAL_TOOLS.values()), REAL_TOOLS

WRAPPER = r'''#!/usr/bin/env python3
import json, os, shutil, subprocess, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
if name == "xcrun" and args[:1] not in (["notarytool"], ["stapler"]):
    os.execv(os.environ["HK_INSTALL_REAL_XCRUN"], [name, *args])
if name == "git" and "hoerbuchkloeppler.notaryProfile" not in args:
    os.execv(os.environ["HK_INSTALL_REAL_GIT"], [name, *args])
destination = Path(os.environ["HK_INSTALL_DEST"]).resolve()
target = Path(sys.argv[0]).resolve() if name in ("ffmpeg", "mediainfo") else (Path(args[-1]).resolve() if args else Path.cwd())
step = "destination" if target == destination or destination in target.parents else (
       "staging" if any(".install-" in part for part in target.parts) else "source")
with open(os.environ["HK_INSTALL_LOG"], "a") as handle:
    handle.write(json.dumps({"tool": name, "args": args, "step": step}) + "\n")
race = os.environ.get("HK_INSTALL_REPLACE_STEP")
def replace_destination():
    if destination.exists():
        saved = destination.parent / "InterferencePrevious.app"
        destination.rename(saved)
        shutil.copytree(saved, destination)
    else:
        shutil.copytree(os.environ["HK_INSTALL_TEMPLATE"], destination)
    (destination / "version.txt").write_text("foreign")
if name == "swift":
    swift = os.environ["HK_INSTALL_REAL_SWIFT"]
    if "--product" in args:
        if race == "helper_build_destination":
            replace_destination()
        if race == "helper_build_parent":
            saved = destination.parent.with_name("InterferenceParentBeforeBuild")
            destination.parent.rename(saved)
            destination.parent.mkdir()
            (saved / destination.name).rename(destination)
    if "--show-bin-path" in args and race == "after_installed_check":
        bin_dir = Path(subprocess.check_output([swift, *args], text=True).strip())
        wrapper_dir = Path(sys.argv[0]).parent
        (wrapper_dir / "real-install-bundle").symlink_to(bin_dir / "install-bundle")
        (wrapper_dir / "install-bundle").symlink_to(Path(sys.argv[0]))
        print(wrapper_dir)
    else:
        os.execv(swift, [name, *args])
elif name == "install-bundle":
    if args[1] == "cleanup":
        destination.rename(destination.with_name("InterferenceDisplaced.app"))
    os.execv(str(Path(sys.argv[0]).with_name("real-install-bundle")), [name, *args])
elif name == "build.sh":
    shutil.copytree(os.environ["HK_INSTALL_TEMPLATE"], Path.cwd() / "Hörbuchklöppler.app")
    if os.environ.get("HK_INSTALL_REPLACE_STEP") == "build":
        replace_destination()
    if os.environ.get("HK_INSTALL_REPLACE_STEP") == "parent":
        saved = destination.parent.with_name("InterferenceParent")
        destination.parent.rename(saved)
        destination.parent.mkdir()
        shutil.copytree(saved / destination.name, destination)
        (destination / "version.txt").write_text("foreign")
elif name == "sign-bundle.sh" or name == "git":
    pass
elif name == "xcrun":
    if args[:2] == ["notarytool", "submit"]:
        print("status: Accepted (kontrolliertes Fixture)")
    if args[:2] == ["stapler", "validate"] and os.environ.get("HK_INSTALL_FAIL") == "stapler:" + step:
        sys.exit(27)
elif name in ("codesign", "spctl", "ffmpeg", "mediainfo"):
    if name == "mediainfo" and step == "staging" and os.environ.get("HK_INSTALL_REPLACE_STEP") == "staging":
        replace_destination()
    if name == "mediainfo" and step == "staging" and race in ("staging_parent", "staging_entry"):
        staged = next(p for p in target.parents if ".install-" in p.name and p.suffix == ".app")
        if race == "staging_parent":
            saved = destination.parent.with_name("InterferenceParentAfterStaging")
            destination.parent.rename(saved)
            destination.parent.mkdir()
            shutil.copytree(saved / destination.name, destination)
            shutil.copytree(saved / staged.name, destination.parent / staged.name)
            staged = destination.parent / staged.name
        else:
            saved = staged.with_name("InterferenceStaged.app")
            staged.rename(saved)
            shutil.copytree(saved, staged)
        (staged / "version.txt").write_text("foreign-staging")
    if name == "mediainfo" and step == "destination" and race == "backup_cleanup":
        backup = next(destination.parent.glob(".*.backup-*.app"))
        saved = backup.with_name("InterferenceBackup.app")
        backup.rename(saved)
        shutil.copytree(saved, backup)
        (backup / "version.txt").write_text("foreign-backup")
    if name == "codesign" and step == "destination" and os.environ.get("HK_INSTALL_REPLACE_STEP") == "destination":
        replace_destination()
        sys.exit(27)
    if name == "mediainfo" and step == "destination" and race == "destination_before_commit":
        replace_destination()
    if name == "codesign" and step == "destination" and race == "destination_removed":
        destination.rename(destination.with_name("InterferenceDisplaced.app"))
        sys.exit(27)
    if os.environ.get("HK_INSTALL_FAIL") == name + ":" + step:
        sys.exit(27)
elif name == "ditto":
    if "-c" in args:
        Path(args[-1]).write_bytes(b"Controlled fixture archive")
    elif os.environ.get("HK_INSTALL_FAIL") == "copy":
        Path(args[-1]).mkdir(exist_ok=True)
        (Path(args[-1]) / "partial.txt").write_text("Unvollständige Kopie")
        sys.exit(28)
    else:
        os.execv(os.environ["HK_INSTALL_REAL_DITTO"], [name, *args])
elif name == "ps":
    pid = args[args.index("-p") + 1]
    if pid == os.environ.get("HK_INSTALL_CHANGED_PID"):
        count_file = Path(os.environ["HK_INSTALL_PS_COUNT"])
        count = int(count_file.read_text()) if count_file.exists() else 0
        count_file.write_text(str(count + 1))
        if count:
            print("Sun Aug 30 09:47:56 2026  /controlled/reused-process")
            sys.exit(0)
    os.execv(os.environ["HK_INSTALL_REAL_PS"], [name, *args])
elif name == "pgrep":
    os.execv(os.environ["HK_INSTALL_REAL_PGREP"], [name, *args])
else:
    raise RuntimeError("Unbekanntes Fixture-Werkzeug: " + name)
'''


def write_app(path, executable, version):
    main = path / "Contents/MacOS/Fixture"
    main.parent.mkdir(parents=True)
    shutil.copyfile(executable, main)
    main.chmod(0o755)
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "Fixture", "CFBundleShortVersionString": version,
    }))
    (path / "version.txt").write_text(version)
    resources = path / "Contents/Resources/HoerbuchkloepplerCore_HoerbuchkloepplerCore.bundle/Contents/Resources/bin"
    resources.mkdir(parents=True)
    for name in ("ffmpeg", "mediainfo"):
        tool = resources / name
        tool.write_text(WRAPPER)
        tool.chmod(0o755)


def run_case(root, executable, name, *, existing=True, arguments=(), failure=None,
             processes=False, changed_identity=False, race=None, expected_backup=False,
             initial_target="directory", preserved_staging=False, expected_backup_version="1.0"):
    case = root / name
    workspace = case / "workspace"
    workspace.mkdir(parents=True)
    wrappers = case / "wrappers"
    wrappers.mkdir()
    for script in ("install.sh", "script-helpers.sh", "notary-profile.sh"):
        shutil.copyfile(REPO / script, workspace / script)
    if not set(arguments).intersection({"--no-install", "--no-notarize"}):
        package = workspace / "tools/InstallBundle"
        package.parent.mkdir()
        package.symlink_to(root / "InstallBundle", target_is_directory=True)
    for tool in ("build.sh", "sign-bundle.sh"):
        path = workspace / tool
        path.write_text(WRAPPER)
        path.chmod(0o755)
    for tool in ("git", "xcrun", "codesign", "spctl", "ditto", "pgrep", "ps", "swift"):
        path = wrappers / tool
        path.write_text(WRAPPER)
        path.chmod(0o755)
    parent = case / "target"
    parent.mkdir()
    destination = parent / "Fixture.app"
    template = case / "template.app"
    write_app(template, executable, "2.0")
    if existing:
        if initial_target == "symlink":
            foreign = case / "SymlinkTarget.app"
            write_app(foreign, executable, "1.0")
            destination.symlink_to(foreign, target_is_directory=True)
        elif initial_target == "file":
            destination.write_text("untouched-file")
        else:
            write_app(destination, executable, "1.0")
    log = case / "calls.jsonl"
    env = dict(os.environ, PATH=str(wrappers) + os.pathsep + os.environ["PATH"],
               HOERBUCHKLOEPPLER_INSTALL_DEST=str(destination),
               HOERBUCHKLOEPPLER_SIGN_IDENTITY="Controlled Fixture Identity",
               NOTARY_PROFILE="controlled-fixture", HK_INSTALL_DEST=str(destination),
               HK_INSTALL_TEMPLATE=str(template), HK_INSTALL_LOG=str(log),
               **{"HK_INSTALL_REAL_" + key.upper(): value for key, value in REAL_TOOLS.items()})
    if failure:
        env["HK_INSTALL_FAIL"] = failure
    if race:
        env["HK_INSTALL_REPLACE_STEP"] = race
    owned_processes = []
    try:
        if processes:
            owned_processes.append(subprocess.Popen([str(destination / "Contents/MacOS/Fixture")]))
            foreign = case / "foreign.app"
            write_app(foreign, executable, "foreign")
            owned_processes.append(subprocess.Popen([str(foreign / "Contents/MacOS/Fixture")]))
            if changed_identity:
                env["HK_INSTALL_CHANGED_PID"] = str(owned_processes[0].pid)
                env["HK_INSTALL_PS_COUNT"] = str(case / "ps-count")
        command = ["bash", str(workspace / "install.sh"), *arguments]
        with subprocess.Popen(
            command,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        ) as installer:
            try:
                stdout, stderr = installer.communicate(timeout=90)
            except subprocess.TimeoutExpired as timeout:
                try:
                    os.killpg(installer.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    stdout, stderr = installer.communicate(timeout=5)
                    (case / "timeout.log").write_text(stdout + "\n" + stderr)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(installer.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    (case / "timeout.log").write_bytes(
                        (timeout.stdout or b"") + b"\n" + (timeout.stderr or b"")
                    )
                raise
            result = subprocess.CompletedProcess(
                command, installer.returncode, stdout, stderr
            )
        alive = [process.poll() is None for process in owned_processes]
    finally:
        for process in owned_processes:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
    calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    staging_entries = list(parent.glob(".*.install-*.app"))
    if preserved_staging:
        assert len(staging_entries) == 1 and (staging_entries[0] / "version.txt").read_text() == "foreign-staging", name
    else:
        assert not staging_entries, name
    backups = list(parent.glob(".*.backup-*.app"))
    if expected_backup:
        assert len(backups) == 1 and (backups[0] / "version.txt").read_text() == expected_backup_version, (name, backups)
    else:
        assert not backups, (name, backups)
    version = ((destination / "version.txt").read_text() if destination.is_dir() else
               destination.read_text() if destination.is_file() else None)
    return result, calls, version, alive


def main():
    with test_workspace("hk-install-fixtures-") as directory:
        root = Path(directory).resolve()
        assert not root.is_relative_to("/Applications")
        shutil.copytree(REPO / "tools/InstallBundle", root / "InstallBundle",
                        ignore=shutil.ignore_patterns(".build", ".swiftpm"))
        source = root / "fixture.c"
        source.write_text("#include <unistd.h>\nint main(void) { for (;;) sleep(1); }\n")
        executable = root / "Fixture"
        subprocess.run([REAL_TOOLS["clang"], str(source), "-o", str(executable)], check=True)
        for kind, expected in [("symlink", "1.0"), ("file", "untouched-file")]:
            result, calls, version, _ = run_case(root, executable, "initial_" + kind, initial_target=kind)
            assert result.returncode != 0 and version == expected and not calls, (kind, calls, result.stderr)
            print("PASS: ungeeignetes Ziel", kind, "vor Build zurückgewiesen und erhalten")
        result, calls, version, _ = run_case(root, executable, "unknown_option", arguments=["--unknown-fixture-option"])
        assert result.returncode == 64 and version == "1.0" and not calls
        print("PASS: unbekannte Option endet vor Build mit Usage-Fehler")
        for race, existing, expected in [
            ("helper_build_destination", True, "foreign"),
            ("helper_build_destination", False, "foreign"),
            ("helper_build_parent", True, "1.0"),
        ]:
            name = race + ("_existing" if existing else "_first")
            result, calls, version, _ = run_case(root, executable, name, existing=existing, race=race)
            assert result.returncode != 0 and version == expected, (name, version, result.stdout, result.stderr)
            assert [call["tool"] for call in calls] == ["xcrun", "git", "swift", "swift"], (name, calls)
            assert calls[0]["args"][:2] == ["notarytool", "history"], (name, calls)
            assert "wurde inzwischen verändert" in result.stderr, (name, result.stderr)
            print("PASS:", name, "Änderung während des Helfer-Builds vor App-Build erkannt")
        for name, existing in [("first_install", False), ("replacement", True)]:
            result, calls, version, _ = run_case(root, executable, name, existing=existing)
            assert result.returncode == 0 and version == "2.0", (name, result.stderr, result.stdout)
            assert "INSTALL OK:" in result.stdout
            for step in ("staging", "destination"):
                assert [call["tool"] for call in calls if call["step"] == step and call["tool"] != "ditto"] == [
                    "codesign", "xcrun", "spctl", "ffmpeg", "mediainfo",
                ]
                assert any(call["tool"] == "xcrun" and call["step"] == step
                           and call["args"][:2] == ["stapler", "validate"] for call in calls)
            print("PASS:", name, "wirklicher Swift-Dateiaustausch, Staging geprüft, Backup entfernt")

        for name, existing, failure in [
            ("source_rejected", True, "spctl:source"),
            ("runtime_rejected", True, "ffmpeg:source"),
            ("copy_failure", True, "copy"),
            ("stage_rejected", True, "codesign:staging"),
            ("rollback_existing", True, "codesign:destination"),
            ("rollback_first", False, "codesign:destination"),
            ("rollback_ticket", True, "stapler:destination"),
        ]:
            result, calls, version, _ = run_case(root, executable, name, existing=existing, failure=failure)
            assert result.returncode != 0 and "INSTALL OK:" not in result.stdout, name
            assert version == ("1.0" if existing else None), (name, version, result.stderr)
            if name in ("source_rejected", "runtime_rejected"):
                assert not any(call["tool"] == "pgrep" for call in calls), name
            print("PASS:", name, "vorheriger Zustand erhalten, keine Staging-/Backupreste")

        for name, arguments in [("no_install", ["--no-install"]), ("no_notarize", ["--no-notarize"])]:
            result, calls, version, alive = run_case(root, executable, name, arguments=arguments, processes=True)
            assert result.returncode == 0 and version == "1.0" and alive == [True, True], (name, result.stderr)
            assert not any(call["tool"] in ("pgrep", "swift") for call in calls)
            assert "INSTALL OK:" not in result.stdout
            print("PASS:", name, "fasst Ziel und laufende Prozesse nicht an")

        result, _, version, alive = run_case(root, executable, "process_ownership", processes=True)
        assert result.returncode == 0 and version == "2.0" and alive == [False, True], (result.stderr, alive)
        print("PASS: nur laufende Instanz des Zielbundles beendet; gleichnamige fremde Testkopie bleibt am Leben")
        result, _, version, alive = run_case(root, executable, "pid_changed", processes=True, changed_identity=True)
        assert result.returncode == 0 and version == "2.0" and alive == [True, True], (result.stderr, alive)
        print("PASS: geänderte Prozessidentität vor TERM schützt die PID")

        for step, existing, backup in [("build", True, False), ("parent", True, False), ("staging", True, False),
                                       ("destination", True, True), ("destination", False, False),
                                       ("destination_before_commit", True, True)]:
            name = "replacement_race_" + step + ("_existing" if existing else "_first")
            result, calls, version, _ = run_case(root, executable, name, existing=existing,
                                                race=step, expected_backup=backup)
            assert result.returncode != 0 and version == "foreign", (name, version, result.stdout, result.stderr)
            if step in ("build", "parent"):
                assert not any(call["tool"] == "pgrep" for call in calls)
            if step == "destination" and not existing:
                assert "Erstinstallation konnte nicht zurückgezogen werden" in result.stderr
                assert "Voriges Bundle" not in result.stderr
            print("PASS:", name, "zwischenzeitlich fremdes Ziel erhalten; nötiges altes Backup behalten")
        result, _, version, _ = run_case(root, executable, "destination_removed", race="destination_removed")
        assert result.returncode != 0 and version == "1.0", (version, result.stderr)
        assert "zurückgerollt" in result.stderr
        assert (root / "destination_removed/target/InterferenceDisplaced.app/version.txt").read_text() == "2.0"
        print("PASS: fehlendes Ziel aus eigenem Backup wiederhergestellt, verschobene Kopie erhalten")
        result, calls, version, _ = run_case(root, executable, "after_installed_check",
                                             race="after_installed_check", expected_backup=True)
        assert result.returncode != 0 and version is None, (version, result.stderr)
        assert [call["args"][1] for call in calls if call["tool"] == "install-bundle"][-2:] == [
            "require-installed", "cleanup",
        ]
        assert (root / "after_installed_check/target/InterferenceDisplaced.app/version.txt").read_text() == "2.0"
        print("PASS: Ziel nach Abschlussprüfung verschoben, kein Rückzug nach Freigabe der Bereinigung")

        for race in ["staging_parent", "staging_entry"]:
            result, _, version, _ = run_case(root, executable, race, race=race, preserved_staging=True)
            assert result.returncode != 0 and version == "1.0", (race, version, result.stderr)
            assert "bleibt erhalten" in result.stderr
            print("PASS:", race, "fremdes Staging bei Bereinigung erhalten")
        result, _, version, _ = run_case(root, executable, "backup_cleanup", race="backup_cleanup",
                                         expected_backup=True, expected_backup_version="foreign-backup")
        assert result.returncode == 0 and version == "2.0", (version, result.stderr)
        assert "Backup-/Staging-Rest" in result.stderr
        print("PASS: fremdes Backup nach erfolgreicher Installation erhalten")


if __name__ == "__main__":
    main()
