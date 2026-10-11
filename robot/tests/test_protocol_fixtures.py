"""Golden JSON shared with the Swift package (apps/shared). Both sides test against these files.

Regenerate after an intentional protocol change:  UPDATE_FIXTURES=1 uv run pytest tests/test_protocol_fixtures.py
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from so101_watch.protocol import (
    PROTOCOL_VERSION,
    ControlAck,
    ControlIntent,
    HapticEvent,
    HapticKind,
    Intent,
    Mode,
    Owner,
    RobotStatus,
    VoiceTranscript,
    WatchLifecycle,
    WatchMotion,
    parse_message,
    to_dict,
)

FIXTURES = Path(__file__).resolve().parents[2] / "apps/shared/Tests/SO101ProtocolTests/Fixtures"

TO_AGENT = {
    "watch_motion": WatchMotion("s-1021", 912, 18391239123, (0.99, 0.01, -0.12, 0.04),
                                (0.02, 0.01, -0.03), (0.03, -0.04, -0.998), 14),
    "watch_lifecycle": WatchLifecycle("s-1021", 3, "inactive"),
    "control_intent": ControlIntent("c-5394", "s-1021", 14, Intent.DOUBLE_TAP, "watch-primary-action"),
    "voice_transcript": VoiceTranscript("v-77", "s-1021", 16, "把紅色積木放進盒子"),
    "voice_transcript_null": VoiceTranscript("v-78", "s-1021", 16, None),
}

FROM_AGENT = {
    "haptic_event": HapticEvent("evt-10315", "s-1021", 14, HapticKind.LIMIT_HIT, "warning", 1.0, 500,
                                "Joint limit reached", 18391239999, True, "shoulder_pan", "soft_joint"),
    "haptic_event_grasp": HapticEvent("evt-10316", "s-1021", 14, HapticKind.GRASP_LIKELY, "info", 0.8, 500,
                                      "Grasp likely", 18391240000, False, transaction_id=3,
                                      evidence=("position_stall", "current_delta")),
    "robot_status": RobotStatus("s-1021", 15, Mode.AWAIT_RECALIBRATION, Owner.NONE, "VLA_FINISHED", True,
                                "pick_red_cube_into_box"),
    "control_ack": ControlAck("c-5394", "rejected", "STALE_EPOCH", Mode.MANUAL, 14),
}

ERROR = {"protocol_version": PROTOCOL_VERSION, "type": "error", "reason": "unknown message type 'x'"}


def _expected() -> dict[str, dict]:
    out = {name: to_dict(m) for name, m in {**TO_AGENT, **FROM_AGENT}.items()}
    out["error"] = ERROR
    return out


@pytest.mark.parametrize("name", sorted(_expected()))
def test_fixture_matches_python_protocol(name: str):
    expected = _expected()[name]
    path = FIXTURES / f"{name}.json"
    if os.environ.get("UPDATE_FIXTURES"):
        FIXTURES.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(expected, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    assert json.loads(path.read_text()) == expected


@pytest.mark.parametrize("name", sorted(TO_AGENT))
def test_phone_to_agent_fixtures_parse_back(name: str):
    assert parse_message(json.loads((FIXTURES / f"{name}.json").read_text())) == TO_AGENT[name]
