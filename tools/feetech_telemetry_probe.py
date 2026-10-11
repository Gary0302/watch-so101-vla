"""READ-ONLY SO-101 telemetry probe (SPEC §7.2, §14).

Answers: does sync_read of Present_Current/Load work on these STS3215s, and how
much loop rate does reading them cost compared with Present_Position alone?

Safety:
  * Uses FeetechMotorsBus directly, never SO101Follower: follower.connect() runs
    configure(), which writes registers and toggles torque.
  * Only sync_read. No register is written.
  * disconnect(disable_torque=False). The LeRobot default (True) would cut torque
    and let the arm drop.
  * Refuses to start if anything else holds the serial port.

Usage: python tools/feetech_telemetry_probe.py --port /dev/ttyACM0 --seconds 10 --out runs/telemetry.csv
"""

from __future__ import annotations

import argparse
import csv
import statistics
import sys
import time
from pathlib import Path

from port_guard import assert_free

MOTORS = {  # SO-101 follower ids, LeRobot 0.6.1 so_follower.py
    "shoulder_pan": 1, "shoulder_lift": 2, "elbow_flex": 3,
    "wrist_flex": 4, "wrist_roll": 5, "gripper": 6,
}
TELEMETRY = ("Present_Position", "Present_Velocity", "Present_Load", "Present_Current")


def _loop(bus, registers: tuple[str, ...], seconds: float, writer=None) -> tuple[float, list[float], dict[str, str]]:
    errors: dict[str, str] = {}
    active = list(registers)
    periods: list[float] = []
    t_end = time.monotonic() + seconds
    last = time.monotonic()
    while time.monotonic() < t_end:
        row: dict[str, object] = {"t": time.monotonic()}
        for reg in list(active):
            try:
                vals = bus.sync_read(reg, normalize=False)
            except Exception as e:  # noqa: BLE001 - record which registers this firmware can't serve
                errors[reg] = repr(e)
                active.remove(reg)
                continue
            for motor, v in vals.items():
                row[f"{motor}.{reg}"] = v
        now = time.monotonic()
        periods.append(now - last)
        last = now
        if writer is not None:
            writer.writerow(row)
    hz = len(periods) / seconds if periods else 0.0
    return hz, periods, errors


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", required=True)
    ap.add_argument("--seconds", type=float, default=10.0)
    ap.add_argument("--out", type=Path, required=True)
    args = ap.parse_args()

    assert_free(args.port)

    from lerobot.motors import Motor, MotorNormMode
    from lerobot.motors.feetech import FeetechMotorsBus

    motors = {name: Motor(mid, "sts3215", MotorNormMode.RANGE_M100_100) for name, mid in MOTORS.items()}
    bus = FeetechMotorsBus(args.port, motors)
    bus.connect(handshake=True)  # pings every id, reads firmware versions: read-only
    try:
        half = args.seconds / 2
        hz_pos, _, _ = _loop(bus, ("Present_Position",), half)
        args.out.parent.mkdir(parents=True, exist_ok=True)
        fields = ["t"] + [f"{m}.{r}" for r in TELEMETRY for m in MOTORS]
        with args.out.open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=fields)
            w.writeheader()
            hz_all, periods, errors = _loop(bus, TELEMETRY, half, w)
    finally:
        bus.disconnect(disable_torque=False)

    print(f"position-only loop : {hz_pos:6.1f} Hz")
    print(f"full telemetry loop: {hz_all:6.1f} Hz  (p95 period {statistics.quantiles(periods, n=20)[-1] * 1000:.1f} ms)"
          if len(periods) >= 20 else f"full telemetry loop: {hz_all:6.1f} Hz")
    for reg, err in errors.items():
        print(f"UNREADABLE {reg}: {err}")
    print(f"csv: {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
