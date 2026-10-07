"""Echte Ad-hoc-Signaturen und kontrollierte Fehler von sign-bundle.sh prüfen."""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


REPO = Path(__file__).resolve().parents[1]
REAL_TOOLS = {name: shutil.which(name) for name in ("codesign", "file", "find", "strip", "clang")}
assert all(REAL_TOOLS.values()), REAL_TOOLS

WRAPPER = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
target = Path(args[-1]) if args else Path(".")
root = Path(os.environ["HK_SIGN_CASE"])
record = {"tool": name, "args": args,
          "modules_absent": not (root / "Fixture.app/Contents/Frameworks/HoerbuchkloepplerCore.framework/Versions/A/Modules").exists()}
with open(os.environ["HK_SIGN_LOG"], "a") as handle:
    handle.write(json.dumps(record) + "\n")
if name == "find" and os.environ.get("HK_SIGN_FAIL_FIND") == "1":
    sys.exit(19)
if name == "file" and target.name == os.environ.get("HK_SIGN_FAIL_FILE"):
    sys.exit(17)
if name == "codesign" and target.name == os.environ.get("HK_SIGN_FAIL_TARGET"):
    sys.exit(42)
if name == "codesign" and "--verify" in args and os.environ.get("HK_SIGN_FAIL_VERIFY") == "1":
    sys.exit(43)
if name == "strip" and os.environ.get("HK_SIGN_FAIL_STRIP") == "1":
    sys.exit(18)
os.execv(os.environ["HK_SIGN_REAL_" + name.upper()], [name, *args])
'''


def write_plist(path, values):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(values))


def fixture(root, executable, library, with_framework):
    app = root / "Fixture.app"
    main = app / "Contents/MacOS/Fixture"
    main.parent.mkdir(parents=True)
    shutil.copyfile(executable, main)
    main.chmod(0o755)
    write_plist(app / "Contents/Info.plist", {
        "CFBundleIdentifier": "org.hoerbuchkloeppler.signfixture",
        "CFBundleExecutable": "Fixture", "CFBundleName": "Fixture", "CFBundlePackageType": "APPL",
    })
    resources = app / "Contents/Resources/Tools.bundle/bin"
    resources.mkdir(parents=True)
    for name in ("ffmpeg", "mediainfo"):
        shutil.copyfile(executable, resources / name)
        (resources / name).chmod(0o755)
    (resources / "ordinary.txt").write_text("Kein Programm.\n")
    if not with_framework:
        return app
    framework = app / "Contents/Frameworks/HoerbuchkloepplerCore.framework"
    version = framework / "Versions/A"
    (version / "Modules").mkdir(parents=True)
    (version / "Modules/Fixture.swiftmodule").write_text("Nur für den Compile-Zeitpunkt.\n")
    shutil.copyfile(library, version / "HoerbuchkloepplerCore")
    (version / "HoerbuchkloepplerCore").chmod(0o755)
    write_plist(version / "Resources/Info.plist", {
        "CFBundleIdentifier": "org.hoerbuchkloeppler.corefixture",
        "CFBundleExecutable": "HoerbuchkloepplerCore", "CFBundlePackageType": "FMWK",
    })
    (framework / "Versions/Current").symlink_to("A")
    for name in ("Resources", "Modules", "HoerbuchkloepplerCore"):
        (framework / name).symlink_to("Versions/Current/" + name)
    return app


def run_case(root, wrappers, executable, library, name, *, identity="-", failure=None, with_framework=True):
    case = root / name
    case.mkdir()
    app = fixture(case, executable, library, with_framework)
    log = case / "calls.jsonl"
    env = dict(os.environ, PATH=str(wrappers) + os.pathsep + os.environ["PATH"],
               HK_SIGN_CASE=str(case), HK_SIGN_LOG=str(log),
               **{"HK_SIGN_REAL_" + key.upper(): value for key, value in REAL_TOOLS.items()})
    if failure:
        env.update(failure)
    result = subprocess.run(["bash", str(REPO / "sign-bundle.sh"), str(app), identity],
                            env=env, capture_output=True, text=True, timeout=30)
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    return app, result, calls


def outer_signs(app, calls):
    return [call for call in calls if call["tool"] == "codesign"
            and "--verify" not in call["args"] and call["args"][-1] == str(app)]


def main():
    with tempfile.TemporaryDirectory(prefix="hk-sign-fixtures-") as directory:
        root = Path(directory)
        assert not root.is_relative_to("/Applications")
        wrappers = root / "wrappers"
        wrappers.mkdir()
        for name in ("codesign", "file", "find", "strip"):
            path = wrappers / name
            path.write_text(WRAPPER)
            path.chmod(0o755)
        source = root / "fixture.c"
        source.write_text("int main(void) { return 0; }\n")
        executable = root / "fixture"
        subprocess.run([REAL_TOOLS["clang"], "-g", str(source), "-o", str(executable)], check=True)
        library_source = root / "library.c"
        library_source.write_text("int fixture_value(void) { return 7; }\n")
        library = root / "library.dylib"
        subprocess.run([REAL_TOOLS["clang"], "-g", "-dynamiclib", str(library_source), "-o", str(library)], check=True)

        app, result, calls = run_case(root, wrappers, executable, library, "success")
        assert result.returncode == 0, result.stderr
        sign_calls = [call for call in calls if call["tool"] == "codesign" and "--verify" not in call["args"]]
        targets = [Path(call["args"][-1]) for call in sign_calls]
        assert {path.name for path in targets[:2]} == {"ffmpeg", "mediainfo"}, targets
        assert targets[2].name == "HoerbuchkloepplerCore.framework" and targets[3] == app, targets
        assert all(call["modules_absent"] for call in sign_calls)
        assert all("--timestamp" not in call["args"] and "--options" not in call["args"] for call in sign_calls)
        first_sign = next(index for index, call in enumerate(calls) if call["tool"] == "codesign")
        strips = [call for call in calls[:first_sign] if call["tool"] == "strip"]
        assert len(strips) == 2
        assert {Path(call["args"][-1]).name for call in strips} == {"Fixture", "HoerbuchkloepplerCore"}
        assert calls[-1]["tool"] == "codesign" and "--verify" in calls[-1]["args"]
        for path in [*targets, app / "Contents/MacOS/Fixture"]:
            subprocess.run([REAL_TOOLS["codesign"], "--verify", "--deep", "--strict", str(path)],
                           check=True, capture_output=True)
        subprocess.run([str(app / "Contents/MacOS/Fixture")], check=True, timeout=5)
        print("PASS: echte Ad-hoc-Signaturen, ausführbares Hauptprogramm, innen vor außen, Strip/Module vor Signierung")

        app, result, calls = run_case(root, wrappers, executable, library, "static_success", with_framework=False)
        assert result.returncode == 0, result.stderr
        signing = [call for call in calls if call["tool"] == "codesign" and "--verify" not in call["args"]]
        assert len(signing) == 3 and Path(signing[-1]["args"][-1]) == app
        subprocess.run([REAL_TOOLS["codesign"], "--verify", "--deep", "--strict", str(app)],
                       capture_output=True, check=True)
        print("PASS: aktueller statischer Core ohne Framework ebenfalls gültig signiert")

        for name, failure in [
            ("inner_failure", {"HK_SIGN_FAIL_TARGET": "ffmpeg"}),
            ("find_failure", {"HK_SIGN_FAIL_FIND": "1"}),
            ("file_failure", {"HK_SIGN_FAIL_FILE": "ffmpeg"}),
            ("own_file_failure", {"HK_SIGN_FAIL_FILE": "Fixture"}),
            ("strip_failure", {"HK_SIGN_FAIL_STRIP": "1"}),
        ]:
            app, result, calls = run_case(root, wrappers, executable, library, name, failure=failure)
            assert result.returncode != 0, (name, "Fehler wurde verschluckt")
            assert not outer_signs(app, calls), (name, "Äußeres Bundle wurde trotz Fehler signiert")
            print("PASS:", name, "stoppt vor äußerer Signatur")

        app, result, calls = run_case(root, wrappers, executable, library, "developer_flags",
                                     identity="Developer ID Application: Controlled Fixture",
                                     failure={"HK_SIGN_FAIL_TARGET": "ffmpeg"})
        assert result.returncode != 0 and not outer_signs(app, calls)
        signing = [call for call in calls if call["tool"] == "codesign"]
        assert signing and all("--timestamp" in call["args"] and "--options" in call["args"]
                               and "runtime" in call["args"] for call in signing)
        print("PASS: Developer-ID-Aufrufe verlangen Hardened Runtime und Zeitstempel; kontrolliert vor echtem Signieren abgebrochen")

        app, result, calls = run_case(root, wrappers, executable, library, "verify_failure",
                                     failure={"HK_SIGN_FAIL_VERIFY": "1"})
        assert result.returncode != 0 and outer_signs(app, calls)
        assert calls[-1]["tool"] == "codesign" and "--verify" in calls[-1]["args"]
        print("PASS: fehlgeschlagene Tiefenprüfung meldet den signierten Build nicht als erfolgreich")

        empty = root / "Empty.app"
        empty.mkdir()
        for arguments, expected in [([], 2), ([str(root / "Missing.app"), "-"], 1), ([str(empty), "-"], 1)]:
            result = subprocess.run(["bash", str(REPO / "sign-bundle.sh"), *arguments],
                                    capture_output=True, text=True, timeout=5)
            assert result.returncode == expected, (arguments, result.returncode, result.stderr)
        print("PASS: falsche Argumentzahl, fehlendes Bundle und fehlende Ressourcen zurückgewiesen")


if __name__ == "__main__":
    main()
