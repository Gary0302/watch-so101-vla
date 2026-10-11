"""Gripper contact inference from Feetech telemetry (SPEC §7.2).

Present_Current / Present_Load are not calibrated force sensors. This only
estimates contact, and it must never mistake the empty-gripper mechanical
end-stop for a grasp. All thresholds are placeholders to be replaced by the
labelled ROC/PR calibration described in §7.2.
"""

from __future__ import annotations

from dataclasses import dataclass

from .protocol import HapticKind


@dataclass
class GripperConfig:
    endstop_position: float = 2.0  # where an empty gripper physically stops closing
    endstop_margin: float = 5.0
    position_error_min: float = 3.0
    velocity_small: float = 0.5  # position units per tick
    baseline_current: float = 50.0  # TODO: baseline_current(position, velocity) from calibration
    current_delta_min: float = 100.0
    contact_ticks: int = 2
    grasp_ticks: int = 6
    slip_distance: float = 8.0


@dataclass(frozen=True)
class GripperEvent:
    kind: HapticKind
    transaction_id: int
    confidence: float
    evidence: tuple[str, ...]


class GripperEstimator:
    """One close->open cycle is a transaction; each event fires at most once per transaction."""

    def __init__(self, config: GripperConfig) -> None:
        self.cfg = config
        self.transaction_id = 0
        self.active = False
        self.at_endstop = False
        self._evidence_ticks = 0
        self._emitted: set[HapticKind] = set()
        self._grasp_position: float | None = None

    def update(self, actual: float, velocity: float, current: float, goal: float) -> list[GripperEvent]:
        c = self.cfg
        closing = goal < actual - c.position_error_min
        opening = goal > actual + c.position_error_min

        if opening and self.active:
            self.active = False
        if closing and not self.active:
            self.active = True
            self.transaction_id += 1
            self._evidence_ticks = 0
            self._emitted.clear()
            self._grasp_position = None
        if not self.active:
            self.at_endstop = False
            return []

        events: list[GripperEvent] = []
        stalled = closing and abs(velocity) < c.velocity_small
        loaded = current - c.baseline_current > c.current_delta_min
        self.at_endstop = actual <= c.endstop_position + c.endstop_margin

        if stalled and loaded and not self.at_endstop:
            self._evidence_ticks += 1
        else:
            self._evidence_ticks = 0

        evidence = ("position_stall", "current_delta")
        if self._evidence_ticks >= c.contact_ticks:
            events += self._once(HapticKind.CONTACT_SUSPECTED, 0.5, evidence)
        if self._evidence_ticks >= c.grasp_ticks:
            if HapticKind.GRASP_LIKELY not in self._emitted:
                self._grasp_position = actual
            events += self._once(HapticKind.GRASP_LIKELY, 0.8, evidence)

        # Slip: after a likely grasp the jaws keep closing well past where the object was.
        if self._grasp_position is not None and actual < self._grasp_position - c.slip_distance:
            events += self._once(HapticKind.GRASP_LOST, 0.6, ("position_drop",))
        return events

    def _once(self, kind: HapticKind, confidence: float, evidence: tuple[str, ...]) -> list[GripperEvent]:
        if kind in self._emitted:
            return []
        self._emitted.add(kind)
        return [GripperEvent(kind, self.transaction_id, confidence, evidence)]
