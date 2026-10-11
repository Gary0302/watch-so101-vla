"""Safety Gate (SPEC §6.3): every MANUAL and VLA proposal passes through here before the motor.

Joint-space only for now: soft limits, per-tick step limit, non-finite rejection,
NEAR_LIMIT with hysteresis. Workspace box / IK convergence / singularity checks
land with the real kinematics.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

from .protocol import HapticKind

JOINTS = ("shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper")

# Condition = (kind, joint, boundary). Level-valued: present on every tick it holds.
Condition = tuple[HapticKind, str, str]


def _mock_limits() -> dict[str, tuple[float, float]]:
    # PLACEHOLDER values for MockRobot only. Real limits come from the SO-101
    # calibration and the bench setup and are not filled in here (SPEC §11.1).
    return {j: (-90.0, 90.0) for j in JOINTS[:-1]} | {"gripper": (0.0, 100.0)}


@dataclass
class SafetyConfig:
    soft_limits: dict[str, tuple[float, float]] = field(default_factory=_mock_limits)
    max_step_per_tick: float = 3.0
    near_margin: float = 5.0
    near_hysteresis: float = 2.0


class SafetyGate:
    def __init__(self, config: SafetyConfig) -> None:
        self.cfg = config
        self.target: dict[str, float] = {}
        self._near: set[tuple[str, str]] = set()
        self.rejected_proposals = 0
        self.gripper_floor: float | None = None

    def reset(self, positions: dict[str, float]) -> None:
        """Adopt measured positions as the hold target (no motion on startup)."""
        self.target = {j: float(positions[j]) for j in JOINTS}
        self._near.clear()

    def hold(self) -> dict[str, float]:
        """Keep commanding the last accepted target. Reading back measured positions
        instead would let gravity sag become the new target, tick after tick."""
        return dict(self.target)

    def near_conditions(self) -> set[Condition]:
        return {(HapticKind.NEAR_LIMIT, j, b) for j, b in self._near}

    def filter(self, proposed: dict[str, float]) -> tuple[dict[str, float], set[Condition]]:
        if any(not isinstance(v, (int, float)) or not math.isfinite(v) for v in proposed.values()):
            self.rejected_proposals += 1
            return self.hold(), self.near_conditions()

        conditions: set[Condition] = set()
        new: dict[str, float] = {}
        step = self.cfg.max_step_per_tick
        for j in JOINTS:
            cur = self.target[j]
            want = float(proposed.get(j, cur))
            if j == "gripper" and self.gripper_floor is not None:
                # Holding a likely grasp: relax to just past the contact point and
                # never squeeze harder; opening is still allowed (§7.2).
                want = max(want, self.gripper_floor)
            want = cur + max(-step, min(step, want - cur))
            lo, hi = self.cfg.soft_limits[j]
            # If we start outside a limit, allow moving back in but never further out.
            lo_eff, hi_eff = min(lo, cur), max(hi, cur)
            if want > hi_eff:
                want = hi_eff
                conditions.add((HapticKind.LIMIT_HIT, j, "max"))
            elif want < lo_eff:
                want = lo_eff
                conditions.add((HapticKind.LIMIT_HIT, j, "min"))
            self._update_near(j, "max", hi - want)
            self._update_near(j, "min", want - lo)
            new[j] = want
        self.target = new
        return dict(new), conditions | self.near_conditions()

    def _update_near(self, joint: str, boundary: str, distance: float) -> None:
        key = (joint, boundary)
        if distance < self.cfg.near_margin:
            self._near.add(key)
        elif distance > self.cfg.near_margin + self.cfg.near_hysteresis:
            self._near.discard(key)
