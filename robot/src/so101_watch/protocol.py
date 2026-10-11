"""Wire protocol v1 (SPEC §9): enums, message types and strict parsing.

Every inbound message is validated here. Anything malformed raises
ProtocolError and is never acted on.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, fields
from enum import Enum
from typing import Any, ClassVar

PROTOCOL_VERSION = 1


class Mode(str, Enum):
    DISCONNECTED = "DISCONNECTED"
    HOLD = "HOLD"
    MANUAL = "MANUAL"
    CALIBRATING = "CALIBRATING"
    LISTENING = "LISTENING"
    TASK_VALIDATING = "TASK_VALIDATING"
    VLA_RUNNING = "VLA_RUNNING"
    VLA_CANCELLING = "VLA_CANCELLING"
    AWAIT_RECALIBRATION = "AWAIT_RECALIBRATION"
    FAULT = "FAULT"
    ESTOP_LATCHED = "ESTOP_LATCHED"


class Owner(str, Enum):
    NONE = "NONE"
    MANUAL = "MANUAL"
    VLA = "VLA"


class Intent(str, Enum):
    DOUBLE_TAP = "DOUBLE_TAP"
    STOP = "STOP"
    RESET_FAULT = "RESET_FAULT"


class HapticKind(str, Enum):
    NEAR_LIMIT = "NEAR_LIMIT"
    LIMIT_HIT = "LIMIT_HIT"
    CONTACT_SUSPECTED = "CONTACT_SUSPECTED"
    GRASP_LIKELY = "GRASP_LIKELY"
    GRASP_LOST = "GRASP_LOST"
    VLA_STARTED = "VLA_STARTED"
    VLA_FINISHED = "VLA_FINISHED"
    FAULT = "FAULT"
    CONNECTION_LOST = "CONNECTION_LOST"
    CALIBRATION_OK = "CALIBRATION_OK"
    CALIBRATION_FAILED = "CALIBRATION_FAILED"


# SPEC §7.3: FAULT > CONTROL_HANDOFF > LIMIT_HIT > GRASP_LIKELY > NEAR_LIMIT
HAPTIC_PRIORITY: dict[HapticKind, int] = {
    HapticKind.FAULT: 5,
    HapticKind.CONNECTION_LOST: 5,
    HapticKind.VLA_STARTED: 4,
    HapticKind.VLA_FINISHED: 4,
    HapticKind.CALIBRATION_OK: 4,
    HapticKind.CALIBRATION_FAILED: 4,
    HapticKind.LIMIT_HIT: 3,
    HapticKind.GRASP_LIKELY: 2,
    HapticKind.GRASP_LOST: 2,
    HapticKind.CONTACT_SUSPECTED: 1,
    HapticKind.NEAR_LIMIT: 0,
}


class ProtocolError(ValueError):
    pass


def _field(d: dict[str, Any], key: str) -> Any:
    if key not in d:
        raise ProtocolError(f"missing field {key!r}")
    return d[key]


def _num(v: Any, key: str) -> float:
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
        raise ProtocolError(f"field {key!r} must be a finite number")
    return float(v)


def _int(d: dict[str, Any], key: str) -> int:
    v = _field(d, key)
    if isinstance(v, bool) or not isinstance(v, int):
        raise ProtocolError(f"field {key!r} must be an integer")
    return v


def _str(d: dict[str, Any], key: str) -> str:
    v = _field(d, key)
    if not isinstance(v, str) or not v:
        raise ProtocolError(f"field {key!r} must be a non-empty string")
    return v


def _vec(d: dict[str, Any], key: str, n: int) -> tuple[float, ...]:
    v = _field(d, key)
    if not isinstance(v, list) or len(v) != n:
        raise ProtocolError(f"field {key!r} must be a list of {n} numbers")
    return tuple(_num(x, key) for x in v)


def _enum(d: dict[str, Any], key: str, enum: type[Enum]) -> Any:
    v = _str(d, key)
    try:
        return enum(v)
    except ValueError:
        raise ProtocolError(f"field {key!r} has unknown value {v!r}") from None


# ---------------------------------------------------------------- inbound


@dataclass(frozen=True)
class WatchMotion:
    TYPE: ClassVar[str] = "watch.motion"
    session_id: str
    seq: int
    sample_mono_ns: int
    quaternion_wxyz: tuple[float, float, float, float]
    gyro_rad_s: tuple[float, float, float]
    gravity_g: tuple[float, float, float]
    control_epoch: int

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> WatchMotion:
        q = _vec(d, "quaternion_wxyz", 4)
        norm = math.sqrt(sum(c * c for c in q))
        if not 0.9 <= norm <= 1.1:
            raise ProtocolError(f"quaternion norm {norm:.3f} is not ~1")
        return cls(
            session_id=_str(d, "session_id"),
            seq=_int(d, "seq"),
            sample_mono_ns=_int(d, "sample_mono_ns"),
            quaternion_wxyz=q,  # type: ignore[arg-type]
            gyro_rad_s=_vec(d, "gyro_rad_s", 3),  # type: ignore[arg-type]
            gravity_g=_vec(d, "gravity_g", 3),  # type: ignore[arg-type]
            control_epoch=_int(d, "control_epoch"),
        )


@dataclass(frozen=True)
class WatchLifecycle:
    """Watch app foreground state; `inactive` disables live manual control (TC12)."""

    TYPE: ClassVar[str] = "watch.lifecycle"
    session_id: str
    seq: int
    state: str

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> WatchLifecycle:
        state = _str(d, "state")
        if state not in ("active", "inactive"):
            raise ProtocolError(f"unknown lifecycle state {state!r}")
        return cls(session_id=_str(d, "session_id"), seq=_int(d, "seq"), state=state)


@dataclass(frozen=True)
class ControlIntent:
    TYPE: ClassVar[str] = "control.intent"
    request_id: str
    session_id: str
    control_epoch: int
    intent: Intent
    source: str

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> ControlIntent:
        return cls(
            request_id=_str(d, "request_id"),
            session_id=_str(d, "session_id"),
            control_epoch=_int(d, "control_epoch"),
            intent=_enum(d, "intent", Intent),
            source=_str(d, "source"),
        )


@dataclass(frozen=True)
class VoiceTranscript:
    """STT result for a LISTENING window; text=None means nothing usable was heard."""

    TYPE: ClassVar[str] = "voice.transcript"
    request_id: str
    session_id: str
    control_epoch: int
    text: str | None

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> VoiceTranscript:
        text = _field(d, "text")
        if text is not None and not isinstance(text, str):
            raise ProtocolError("field 'text' must be a string or null")
        return cls(
            request_id=_str(d, "request_id"),
            session_id=_str(d, "session_id"),
            control_epoch=_int(d, "control_epoch"),
            text=text or None,
        )


InboundMessage = WatchMotion | WatchLifecycle | ControlIntent | VoiceTranscript

_INBOUND: dict[str, type] = {
    m.TYPE: m for m in (WatchMotion, WatchLifecycle, ControlIntent, VoiceTranscript)
}


def parse_message(d: Any) -> InboundMessage:
    if not isinstance(d, dict):
        raise ProtocolError("message must be a JSON object")
    if d.get("protocol_version") != PROTOCOL_VERSION:
        raise ProtocolError(f"unsupported protocol_version {d.get('protocol_version')!r}")
    cls = _INBOUND.get(d.get("type"))  # type: ignore[arg-type]
    if cls is None:
        raise ProtocolError(f"unknown message type {d.get('type')!r}")
    return cls.from_dict(d)


# ---------------------------------------------------------------- outbound


@dataclass(frozen=True)
class HapticEvent:
    TYPE: ClassVar[str] = "robot.haptic_event"
    event_id: str
    session_id: str
    control_epoch: int
    kind: HapticKind
    severity: str
    confidence: float
    ttl_ms: int
    display: str
    created_mono_ns: int
    play_haptic: bool = True  # False: update UI text only (cooldown / lower priority)
    axis: str | None = None
    limit_type: str | None = None
    transaction_id: int | None = None
    evidence: tuple[str, ...] = ()


@dataclass(frozen=True)
class RobotStatus:
    TYPE: ClassVar[str] = "robot.status"
    session_id: str
    control_epoch: int
    mode: Mode
    owner: Owner
    reason: str
    robot_holding: bool
    vla_task_id: str | None = None


@dataclass(frozen=True)
class ControlAck:
    TYPE: ClassVar[str] = "control.ack"
    request_id: str
    result: str  # accepted | duplicate | ignored | rejected
    reason: str
    mode: Mode
    control_epoch: int


def to_dict(msg: Any) -> dict[str, Any]:
    out: dict[str, Any] = {"protocol_version": PROTOCOL_VERSION, "type": msg.TYPE}
    for f in fields(msg):
        v = getattr(msg, f.name)
        if isinstance(v, Enum):
            v = v.value
        elif isinstance(v, tuple):
            v = list(v)
        out[f.name] = v
    return out
