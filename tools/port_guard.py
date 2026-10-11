"""Refuse to open a device another process already holds. Never kills anything.

aup is shared and the SO-101 is shared with a friend, so every probe calls
`assert_free()` before touching a serial port or camera.
"""

from __future__ import annotations

import os
import shutil
import subprocess


class DeviceBusy(RuntimeError):
    pass


def holders(path: str) -> list[str]:
    """`pid command` for every visible process holding `path` open (same-user processes at least)."""
    if shutil.which("lsof"):
        r = subprocess.run(["lsof", "-F", "pc", path], capture_output=True, text=True)
        out, pid = [], None
        for line in r.stdout.splitlines():
            if line.startswith("p"):
                pid = line[1:]
            elif line.startswith("c") and pid:
                out.append(f"{pid} {line[1:]}")
        return out
    if shutil.which("fuser"):
        r = subprocess.run(["fuser", path], capture_output=True, text=True)
        return [f"{pid} ?" for pid in r.stdout.split()]
    raise DeviceBusy(f"cannot check whether {path} is in use: neither lsof nor fuser is installed")


def assert_free(path: str) -> None:
    # tools/aup_probe.sh checks on the HOST (lsof + running containers) before starting the
    # container; inside the container host processes are invisible anyway.
    if os.environ.get("SO101_DEVICE_CHECKED_ON_HOST") == "1":
        return
    held = holders(path)
    if held:
        raise DeviceBusy(f"{path} is in use by: {', '.join(held)}. Not touching it; coordinate first.")
