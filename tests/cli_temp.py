"""Testarbeitsordner anlegen und eigene Core-Arbeitsordner beobachten."""

import shutil
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path


@contextmanager
def test_workspace(prefix, keep=False):
    directory = Path(tempfile.mkdtemp(prefix=prefix))
    try:
        yield directory
    except BaseException:
        print(f"Diagnosedaten: {directory}", file=sys.stderr)
        raise
    else:
        if keep:
            print(f"Testdaten erhalten: {directory}")
        else:
            shutil.rmtree(directory)


def system_temporary_directory():
    return Path(
        subprocess.check_output(
            ["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], text=True
        ).strip()
    )


def owned_temp_directories(directory, pid):
    result = set()
    for pattern in ("HB_Temp_*", "HB_Loudness_*", ".HB_Cleanup_*"):
        for candidate in directory.glob(pattern):
            try:
                with (candidate / ".owner-pid").open("rb") as handle:
                    owner = handle.read(33).strip()
            except (FileNotFoundError, NotADirectoryError, PermissionError):
                continue
            if owner == str(pid).encode("ascii"):
                result.add(candidate)
    return result
