from __future__ import annotations

import json

import pytest

from so101_watch.protocol import (
    ControlAck,
    Intent,
    Mode,
    ProtocolError,
    WatchMotion,
    parse_message,
    to_dict,
)

MOTION = {
    "protocol_version": 1,
    "type": "watch.motion",
    "session_id": "s-1021",
    "seq": 912,
    "sample_mono_ns": 18391239123,
    "quaternion_wxyz": [0.99, 0.01, -0.12, 0.04],
    "gyro_rad_s": [0.02, 0.01, -0.03],
    "gravity_g": [0.03, -0.04, -0.998],
    "control_epoch": 14,
}


def test_spec_example_motion_parses():
    m = parse_message(MOTION)
    assert isinstance(m, WatchMotion) and m.control_epoch == 14


def test_spec_example_intent_parses():
    m = parse_message({"protocol_version": 1, "type": "control.intent", "request_id": "c-5394",
                       "session_id": "s-1021", "control_epoch": 14, "intent": "DOUBLE_TAP",
                       "source": "watch-primary-action"})
    assert m.intent is Intent.DOUBLE_TAP


@pytest.mark.parametrize("patch", [
    {"protocol_version": 2},
    {"type": "robot.motor_raw"},
    {"quaternion_wxyz": [1, 0, 0]},
    {"quaternion_wxyz": [2.0, 0, 0, 0]},
    {"gyro_rad_s": [float("nan"), 0, 0]},
    {"seq": "912"},
    {"control_epoch": True},
    {"session_id": ""},
])
def test_malformed_messages_are_rejected(patch):
    with pytest.raises(ProtocolError):
        parse_message({**MOTION, **patch})


def test_unknown_intent_rejected():
    with pytest.raises(ProtocolError):
        parse_message({"protocol_version": 1, "type": "control.intent", "request_id": "c",
                       "session_id": "s", "control_epoch": 1, "intent": "MOVE_MOTOR_3", "source": "x"})


def test_outbound_round_trips_through_json():
    d = to_dict(ControlAck("c-1", "accepted", "OK", Mode.MANUAL, 7))
    assert json.loads(json.dumps(d)) == {
        "protocol_version": 1, "type": "control.ack", "request_id": "c-1", "result": "accepted",
        "reason": "OK", "mode": "MANUAL", "control_epoch": 7,
    }
