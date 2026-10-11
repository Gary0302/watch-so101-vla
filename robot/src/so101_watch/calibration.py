"""Wrist neutral-pose calibration (SPEC §5.2): capture q0 only from a still, palm-down wrist."""

from __future__ import annotations

import math
from dataclasses import dataclass

from . import quat
from .protocol import WatchMotion


@dataclass
class CalibrationConfig:
    still_ms: float = 400.0
    gyro_still_rad_s: float = 0.15
    # Watch face up (palm down, forearm level) puts gravity near -Z in the watch frame.
    gravity_z_max_g: float = -0.8


@dataclass(frozen=True)
class CalibrationResult:
    ok: bool
    reason: str
    q0: quat.Quat | None = None


class CalibrationTracker:
    """Accumulates a contiguous still window; any motion or bad posture restarts it.

    The window length is measured on the Watch's own sample clock, never by
    subtracting timestamps from different devices (SPEC §9).
    """

    def __init__(self, config: CalibrationConfig) -> None:
        self.cfg = config
        self._window: list[WatchMotion] = []
        self.last_reject: str | None = None

    def add(self, m: WatchMotion) -> None:
        if self._window and m.sample_mono_ns <= self._window[-1].sample_mono_ns:
            return  # duplicate or reordered sample
        gyro = math.sqrt(sum(c * c for c in m.gyro_rad_s))
        if gyro > self.cfg.gyro_still_rad_s:
            self._restart("wrist_moving")
        elif m.gravity_g[2] > self.cfg.gravity_z_max_g:
            self._restart("posture_not_palm_down")
        else:
            self._window.append(m)

    def _restart(self, reason: str) -> None:
        self._window.clear()
        self.last_reject = reason

    def result(self) -> CalibrationResult | None:
        """A result once the still window is long enough; None while still waiting.

        Giving up is the Supervisor's calibration timeout, not ours.
        """
        if len(self._window) < 2:
            return None
        span_ms = (self._window[-1].sample_mono_ns - self._window[0].sample_mono_ns) / 1e6
        if span_ms < self.cfg.still_ms:
            return None
        q0 = quat.average(m.quaternion_wxyz for m in self._window)
        return CalibrationResult(ok=True, reason="still", q0=q0)
