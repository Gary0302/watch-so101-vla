"""Control Supervisor (SPEC §4): sole owner of mode, control owner and control_epoch.

Invariants enforced in `_go` (raise IllegalTransition, never silently allowed):
  * owner is derived from mode, so there is exactly one owner at a time (§4.1-1).
  * MANUAL is entered only from a successful CALIBRATING whose target is MANUAL.
    No other path (listen timeout, rejected task, VLA end, fault reset) can
    hand the arm back to the wrist without a fresh q0 and a neutral check.
  * VLA_RUNNING is entered only from TASK_VALIDATING, and leaves only to
    VLA_CANCELLING / AWAIT_RECALIBRATION / FAULT / ESTOP_LATCHED (§4.1-5).
  * Every transition bumps control_epoch; stale packets and chunks die (§4.1-4).
  * ESTOP_LATCHED is cleared only by a local operator (§4.1-7).
"""

from __future__ import annotations

from collections import OrderedDict
from collections.abc import Callable
from dataclasses import dataclass, replace

from .protocol import ControlAck, ControlIntent, Intent, Mode, Owner

OWNER_BY_MODE = {Mode.MANUAL: Owner.MANUAL, Mode.VLA_RUNNING: Owner.VLA}

_VLA_EXITS = {Mode.VLA_CANCELLING, Mode.AWAIT_RECALIBRATION, Mode.FAULT, Mode.ESTOP_LATCHED}
_CANCEL_EXITS = {Mode.AWAIT_RECALIBRATION, Mode.FAULT, Mode.ESTOP_LATCHED}
_ESTOP_RELEASE_REASON = "estop_released_local"


class IllegalTransition(RuntimeError):
    pass


@dataclass(frozen=True)
class Transition:
    at: float
    src: Mode
    dst: Mode
    reason: str
    epoch: int


@dataclass
class SupervisorConfig:
    listen_timeout_s: float = 8.0  # 5 s recording window + STT margin (SPEC §5.3)
    validate_timeout_s: float = 3.0
    calibration_timeout_s: float = 3.0
    vla_timeout_s: float = 120.0
    cancel_timeout_s: float = 1.0
    request_id_memory: int = 1024


class Supervisor:
    def __init__(
        self,
        config: SupervisorConfig | None = None,
        on_transition: Callable[[Transition], None] | None = None,
    ) -> None:
        self.cfg = config or SupervisorConfig()
        self.mode = Mode.DISCONNECTED
        self.epoch = 0
        self.mode_since = 0.0
        self.calibration_next: Mode | None = None
        self.task_id: str | None = None
        self.history: list[Transition] = []
        self._on_transition = on_transition
        self._acks: OrderedDict[str, ControlAck] = OrderedDict()

    @property
    def owner(self) -> Owner:
        return OWNER_BY_MODE.get(self.mode, Owner.NONE)

    # ------------------------------------------------------------ core

    def _go(self, dst: Mode, reason: str, now: float, *, calibration_next: Mode | None = None) -> None:
        src = self.mode
        if src is Mode.ESTOP_LATCHED and reason != _ESTOP_RELEASE_REASON:
            raise IllegalTransition(f"ESTOP_LATCHED -> {dst.value} needs a local operator release")
        if dst is Mode.MANUAL and not (src is Mode.CALIBRATING and self.calibration_next is Mode.MANUAL):
            raise IllegalTransition(f"MANUAL may only follow a completed CALIBRATING, not {src.value}")
        if dst is Mode.VLA_RUNNING and src is not Mode.TASK_VALIDATING:
            raise IllegalTransition(f"VLA_RUNNING may only follow TASK_VALIDATING, not {src.value}")
        if src is Mode.VLA_RUNNING and dst not in _VLA_EXITS:
            raise IllegalTransition(f"VLA_RUNNING may not exit to {dst.value}")
        if src is Mode.VLA_CANCELLING and dst not in _CANCEL_EXITS:
            raise IllegalTransition(f"VLA_CANCELLING may not exit to {dst.value}")
        if dst is Mode.CALIBRATING and calibration_next not in (Mode.MANUAL, Mode.LISTENING):
            raise IllegalTransition("CALIBRATING needs a target of MANUAL or LISTENING")

        self.mode = dst
        self.epoch += 1
        self.mode_since = now
        self.calibration_next = calibration_next if dst is Mode.CALIBRATING else None
        if dst is Mode.CALIBRATING:
            self.task_id = None
        t = Transition(at=now, src=src, dst=dst, reason=reason, epoch=self.epoch)
        self.history.append(t)
        if self._on_transition is not None:
            self._on_transition(t)

    def _ack(self, req: ControlIntent, result: str, reason: str) -> ControlAck:
        return ControlAck(req.request_id, result, reason, self.mode, self.epoch)

    # ------------------------------------------------------------ intents

    def handle_intent(self, req: ControlIntent, now: float, *, healthy: bool = True) -> ControlAck:
        """Idempotent on request_id (SPEC §9.2): a re-delivered intent is never re-executed."""
        if req.request_id in self._acks:
            first = self._acks[req.request_id]
            return replace(first, result="duplicate", reason=first.result)
        ack = self._dispatch(req, now, healthy)
        self._acks[req.request_id] = ack
        while len(self._acks) > self.cfg.request_id_memory:
            self._acks.popitem(last=False)
        return ack

    def _dispatch(self, req: ControlIntent, now: float, healthy: bool) -> ControlAck:
        # STOP only ever moves toward HOLD, so it is honoured even with a stale epoch.
        if req.intent is Intent.STOP:
            return self._ack(req, *self._stop_result(self.request_stop("stop_intent", now)))

        # Anything else from an old epoch was decided against a mode that no longer exists,
        # e.g. an "Interrupt VLA" tap that lands after the VLA already finished.
        if req.control_epoch != self.epoch:
            return self._ack(req, "rejected", "STALE_EPOCH")

        if req.intent is Intent.DOUBLE_TAP:
            m = self.mode
            if m in (Mode.HOLD, Mode.AWAIT_RECALIBRATION):
                self._go(Mode.CALIBRATING, "double_tap_take_over", now, calibration_next=Mode.MANUAL)
            elif m is Mode.MANUAL:
                self._go(Mode.CALIBRATING, "double_tap_voice", now, calibration_next=Mode.LISTENING)
            elif m is Mode.VLA_RUNNING:
                self._go(Mode.VLA_CANCELLING, "double_tap_interrupt", now)
            else:
                return self._ack(req, "ignored", f"DOUBLE_TAP_NOOP_IN_{m.value}")
            return self._ack(req, "accepted", "OK")

        if req.intent is Intent.RESET_FAULT:
            if self.mode is not Mode.FAULT:
                return self._ack(req, "ignored", "NOT_IN_FAULT")
            if not healthy:
                return self._ack(req, "rejected", "FAULT_CONDITION_PERSISTS")
            self._go(Mode.HOLD, "fault_reset", now)
            return self._ack(req, "accepted", "OK")

        return self._ack(req, "rejected", "UNKNOWN_INTENT")  # pragma: no cover

    @staticmethod
    def _stop_result(changed: bool) -> tuple[str, str]:
        return ("accepted", "OK") if changed else ("ignored", "ALREADY_HOLDING")

    def request_stop(self, reason: str, now: float) -> bool:
        if self.mode is Mode.VLA_RUNNING:
            self._go(Mode.VLA_CANCELLING, reason, now)
            return True
        if self.mode in (Mode.MANUAL, Mode.CALIBRATING, Mode.LISTENING, Mode.TASK_VALIDATING):
            self._go(Mode.HOLD, reason, now)
            return True
        return False

    # ------------------------------------------------------------ agent events

    def on_ready(self, now: float) -> bool:
        if self.mode is not Mode.DISCONNECTED:
            return False
        self._go(Mode.HOLD, "ready", now)
        return True

    def on_calibration_result(self, ok: bool, reason: str, now: float) -> bool:
        if self.mode is not Mode.CALIBRATING:
            return False
        if ok:
            assert self.calibration_next is not None
            self._go(self.calibration_next, f"calibrated:{reason}", now)
        else:
            self._go(Mode.HOLD, f"calibration_failed:{reason}", now)
        return True

    def on_transcript(self, now: float) -> bool:
        if self.mode is not Mode.LISTENING:
            return False
        self._go(Mode.TASK_VALIDATING, "transcript", now)
        return True

    def on_task_accepted(self, task_id: str, now: float) -> bool:
        if self.mode is not Mode.TASK_VALIDATING:
            return False
        self.task_id = task_id
        self._go(Mode.VLA_RUNNING, f"task:{task_id}", now)
        return True

    def on_task_rejected(self, reason: str, now: float) -> bool:
        """Unknown / unsupported task: back toward MANUAL, but only through recalibration."""
        if self.mode is not Mode.TASK_VALIDATING:
            return False
        self._go(Mode.CALIBRATING, f"task_rejected:{reason}", now, calibration_next=Mode.MANUAL)
        return True

    def on_vla_finished(self, outcome: str, now: float) -> bool:
        if self.mode is not Mode.VLA_RUNNING:
            return False
        self._go(Mode.AWAIT_RECALIBRATION, f"vla_{outcome}", now)
        return True

    def on_hold_confirmed(self, now: float) -> bool:
        if self.mode is not Mode.VLA_CANCELLING:
            return False
        self._go(Mode.AWAIT_RECALIBRATION, "vla_cancelled", now)
        return True

    def on_manual_lost(self, reason: str, now: float) -> bool:
        if self.mode is not Mode.MANUAL:
            return False
        self._go(Mode.HOLD, reason, now)
        return True

    def on_fault(self, reason: str, now: float) -> bool:
        if self.mode in (Mode.FAULT, Mode.ESTOP_LATCHED):
            return False
        self._go(Mode.FAULT, reason, now)
        return True

    def on_estop(self, now: float) -> bool:
        if self.mode is Mode.ESTOP_LATCHED:
            return False
        self._go(Mode.ESTOP_LATCHED, "physical_estop", now)
        return True

    def on_estop_released(self, source: str, now: float) -> bool:
        """Only a person at the robot clears the latch; speech/VLA/network cannot (§4.1-7)."""
        if self.mode is not Mode.ESTOP_LATCHED or source != "local_operator":
            return False
        self._go(Mode.DISCONNECTED, _ESTOP_RELEASE_REASON, now)
        return True

    def check_timeouts(self, now: float) -> None:
        age = now - self.mode_since
        c = self.cfg
        if self.mode is Mode.LISTENING and age > c.listen_timeout_s:
            self._go(Mode.CALIBRATING, "listen_timeout", now, calibration_next=Mode.MANUAL)
        elif self.mode is Mode.TASK_VALIDATING and age > c.validate_timeout_s:
            self._go(Mode.CALIBRATING, "validate_timeout", now, calibration_next=Mode.MANUAL)
        elif self.mode is Mode.CALIBRATING and age > c.calibration_timeout_s:
            self._go(Mode.HOLD, "calibration_failed:timeout", now)
        elif self.mode is Mode.VLA_RUNNING and age > c.vla_timeout_s:
            self._go(Mode.AWAIT_RECALIBRATION, "vla_timeout", now)
        elif self.mode is Mode.VLA_CANCELLING and age > c.cancel_timeout_s:
            self._go(Mode.FAULT, "cancel_timeout", now)
