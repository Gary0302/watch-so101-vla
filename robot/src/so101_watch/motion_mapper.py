"""Relative wrist attitude -> commanded velocity (SPEC §6.2).

    q_rel = inverse(q0) * q_watch
    r     = log_SO3(q_rel)
    v     = clamp(K * deadzone(r), -vmax, +vmax), then slew-limited

Neutral wrist means zero velocity; the arm holds where it is and never
drifts back to a home pose.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from . import quat


@dataclass
class MotionConfig:
    deadzone_deg: float = 5.0
    gain_deg_s_per_rad: float = 60.0
    vmax_deg_s: float = 30.0
    max_accel_deg_s2: float = 120.0
    # Per-hand sign flips for (pitch, roll); see the settings page in SPEC §5.2.
    axis_sign: tuple[float, float] = (1.0, 1.0)


class MotionMapper:
    def __init__(self, config: MotionConfig) -> None:
        self.cfg = config
        self._v = (0.0, 0.0)

    def reset(self) -> None:
        """Called on every (re)calibration: the first control input is zero."""
        self._v = (0.0, 0.0)

    def velocity(self, q0: quat.Quat, q: quat.Quat, dt: float) -> tuple[float, float]:
        rx, ry, _yaw = quat.log_so3(quat.mul(quat.conj(q0), q))  # yaw drifts: unused in v1
        mag = math.hypot(rx, ry)
        dz = math.radians(self.cfg.deadzone_deg)
        if mag <= dz:
            want = (0.0, 0.0)
        else:
            scale = (mag - dz) / mag * self.cfg.gain_deg_s_per_rad
            sx, sy = self.cfg.axis_sign
            vmax = self.cfg.vmax_deg_s
            want = (
                max(-vmax, min(vmax, sx * rx * scale)),
                max(-vmax, min(vmax, sy * ry * scale)),
            )
        step = self.cfg.max_accel_deg_s2 * max(dt, 0.0)
        self._v = tuple(  # type: ignore[assignment]
            v + max(-step, min(step, w - v)) for v, w in zip(self._v, want)
        )
        return self._v


@dataclass
class PlaceholderKinematicsConfig:
    pitch_joint: str = "shoulder_lift"
    roll_joint: str = "shoulder_pan"


class PlaceholderJointMapper:
    """STAND-IN for LeRobot's EEReferenceAndDelta + InverseKinematicsEEToJoints (SPEC §6.2).

    Maps the two wrist-tilt velocities straight onto two joints so the
    supervisor/safety plumbing can be exercised against MockRobot. Replace
    with the IK processor pipeline before driving real hardware.
    """

    def __init__(self, config: PlaceholderKinematicsConfig) -> None:
        self.cfg = config

    def integrate(self, v: tuple[float, float], current: dict[str, float], dt: float) -> dict[str, float]:
        target = dict(current)
        target[self.cfg.pitch_joint] += v[0] * dt
        target[self.cfg.roll_joint] += v[1] * dt
        return target
