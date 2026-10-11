"""Haptic event policy (SPEC §7.3): edge-triggered, deduplicated, cooled down, prioritized.

Delivery is best effort. A sink that drops or raises never affects the control
loop; the Safety Gate does not depend on anyone feeling a buzz (SPEC §11.3).
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from dataclasses import dataclass, field

from .protocol import HAPTIC_PRIORITY, HapticEvent, HapticKind
from .safety import Condition

log = logging.getLogger(__name__)

_DISPLAY = {
    HapticKind.NEAR_LIMIT: "Approaching limit",
    HapticKind.LIMIT_HIT: "Movement limit",
    HapticKind.CONTACT_SUSPECTED: "Possible contact",
    HapticKind.GRASP_LIKELY: "Grasp likely",
    HapticKind.GRASP_LOST: "Grip may be lost",
    HapticKind.VLA_STARTED: "VLA controlling",
    HapticKind.VLA_FINISHED: "Double Tap to take over",
    HapticKind.FAULT: "Control unavailable",
    HapticKind.CONNECTION_LOST: "Control unavailable",
    HapticKind.CALIBRATION_OK: "Calibrated",
    HapticKind.CALIBRATION_FAILED: "Recalibrate",
}

_SEVERITY = {5: "critical", 4: "info", 3: "warning", 2: "info", 1: "info", 0: "info"}


@dataclass
class HapticConfig:
    event_ttl_ms: int = 500
    min_gap_ms: float = 300.0  # haptic engine recovery; lower/equal priority inside it -> UI only
    # Handoff/fault events are rare and must be felt: always flagged to play. The Watch
    # renderer queues them to respect the engine's recovery interval instead of dropping.
    always_play_priority: int = 4
    cooldown_ms: dict[HapticKind, float] = field(
        default_factory=lambda: {HapticKind.LIMIT_HIT: 1000.0, HapticKind.NEAR_LIMIT: 1000.0}
    )


@dataclass
class _Candidate:
    kind: HapticKind
    fields: dict


class HapticEmitter:
    def __init__(self, sink: Callable[[HapticEvent], None], config: HapticConfig, session_id: str) -> None:
        self.sink = sink
        self.cfg = config
        self.session_id = session_id
        self._active: set[Condition] = set()
        self._last_fire: dict[object, float] = {}
        self._last_haptic_at = float("-inf")
        self._last_haptic_prio = -1
        self._seq = 0
        self.delivery_failures = 0
        self.sent: list[HapticEvent] = []

    def update_conditions(self, conditions: set[Condition], now: float, epoch: int) -> None:
        """Level -> edge: only a condition that was absent last tick can fire."""
        rising = conditions - self._active
        self._active = set(conditions)
        out = []
        for kind, axis, boundary in sorted(rising, key=lambda c: (c[0].value, c[1], c[2])):
            key = (kind, axis, boundary)
            cooldown = self.cfg.cooldown_ms.get(kind, 0.0) / 1000.0
            if now - self._last_fire.get(key, float("-inf")) < cooldown:
                continue
            self._last_fire[key] = now
            limit_type = "soft_joint" if kind in (HapticKind.LIMIT_HIT, HapticKind.NEAR_LIMIT) else None
            out.append(_Candidate(kind, {"axis": axis, "limit_type": limit_type, "confidence": 1.0}))
        self._publish(out, now, epoch)

    def one_shot(self, kind: HapticKind, now: float, epoch: int, *, dedup_key: object = None, **fields) -> None:
        if dedup_key is not None:
            if dedup_key in self._last_fire:
                return
            self._last_fire[dedup_key] = now
        fields.setdefault("confidence", 1.0)
        self._publish([_Candidate(kind, fields)], now, epoch)

    def _publish(self, candidates: list[_Candidate], now: float, epoch: int) -> None:
        candidates.sort(key=lambda c: HAPTIC_PRIORITY[c.kind], reverse=True)
        for i, c in enumerate(candidates):
            prio = HAPTIC_PRIORITY[c.kind]
            gap_ok = (now - self._last_haptic_at) * 1000.0 >= self.cfg.min_gap_ms
            play = prio >= self.cfg.always_play_priority or (
                i == 0 and (gap_ok or prio > self._last_haptic_prio)
            )
            if play:
                self._last_haptic_at = now
                self._last_haptic_prio = prio
            self._seq += 1
            ev = HapticEvent(
                event_id=f"evt-{self._seq}",
                session_id=self.session_id,
                control_epoch=epoch,
                kind=c.kind,
                severity=_SEVERITY[prio],
                ttl_ms=self.cfg.event_ttl_ms,
                display=_DISPLAY[c.kind],
                created_mono_ns=int(now * 1e9),
                play_haptic=play,
                **c.fields,
            )
            self.sent.append(ev)
            try:
                self.sink(ev)
            except Exception:  # noqa: BLE001 - delivery must never break the control loop
                self.delivery_failures += 1
                log.warning("haptic delivery failed for %s", ev.event_id, exc_info=True)
