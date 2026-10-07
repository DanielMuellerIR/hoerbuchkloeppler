"""Eigene Core-Arbeitsordner beobachten, auch wenn Foundation TMPDIR ignoriert."""

from pathlib import Path
import subprocess


def system_temporary_directory():
    return Path(subprocess.check_output(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip())


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
