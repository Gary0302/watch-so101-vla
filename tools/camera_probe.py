"""READ-ONLY camera probe (SPEC §8.1, §14): resolution, real FPS, and whether both open at once.

Refuses any /dev/video* node another process holds. Saves one frame per camera
so the front vs wrist assignment can be checked by eye.

Usage: python tools/camera_probe.py --devices /dev/video0 /dev/video2 --out runs/cameras
"""

from __future__ import annotations

import argparse
import glob
import statistics
import sys
import time
from pathlib import Path

from port_guard import DeviceBusy, assert_free


def _open(cv2, dev: str, w: int, h: int, fps: int):
    cap = cv2.VideoCapture(dev, cv2.CAP_V4L2)
    if not cap.isOpened():
        return None
    cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, w)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, h)
    cap.set(cv2.CAP_PROP_FPS, fps)
    ok, _ = cap.read()
    if not ok:  # e.g. the metadata node most UVC cameras also expose
        cap.release()
        return None
    return cap


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--devices", nargs="*", help="default: every /dev/video*")
    ap.add_argument("--seconds", type=float, default=5.0)
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--height", type=int, default=480)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    import cv2

    devices = args.devices or sorted(glob.glob("/dev/video*"))
    args.out.mkdir(parents=True, exist_ok=True)
    caps = {}
    for dev in devices:
        try:
            assert_free(dev)
        except DeviceBusy as e:
            print(f"SKIP {e}")
            continue
        cap = _open(cv2, dev, args.width, args.height, args.fps)
        if cap is None:
            print(f"SKIP {dev}: not a capture node")
            continue
        caps[dev] = cap

    try:
        if not caps:
            print("no usable cameras")
            return 1
        # Read all cameras round-robin, the way the agent will, to expose USB bandwidth limits.
        stamps: dict[str, list[float]] = {d: [] for d in caps}
        skews: list[float] = []
        t_end = time.monotonic() + args.seconds
        while time.monotonic() < t_end:
            round_t = []
            for dev, cap in caps.items():
                ok, frame = cap.read()
                if ok:
                    t = time.monotonic()
                    stamps[dev].append(t)
                    round_t.append(t)
                    if len(stamps[dev]) == 1:
                        name = dev.replace("/dev/", "")
                        cv2.imwrite(str(args.out / f"{name}.jpg"), frame)
                        print(f"{dev}: {frame.shape[1]}x{frame.shape[0]}")
            if len(round_t) == len(caps) > 1:
                skews.append(max(round_t) - min(round_t))
        for dev, ts in stamps.items():
            print(f"{dev}: {len(ts) / args.seconds:5.1f} fps measured ({len(ts)} frames)")
        if skews:
            print(f"pair skew: median {statistics.median(skews) * 1000:.1f} ms, max {max(skews) * 1000:.1f} ms")
        print(f"frames saved under {args.out}")
    finally:
        for cap in caps.values():
            cap.release()
    return 0


if __name__ == "__main__":
    sys.exit(main())
