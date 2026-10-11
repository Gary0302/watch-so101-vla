from __future__ import annotations

import itertools
import math

import pytest

from so101_watch.agent import AgentConfig, RobotAgent
from so101_watch.mocks import MockRobot, RecordingSink, ScriptedPolicy
from so101_watch.protocol import PROTOCOL_VERSION, Mode
from so101_watch.quat import Quat, from_rotvec

DT = 1 / 30
PALM_DOWN = (0.0, 0.0, -1.0)
NEUTRAL: Quat = (1.0, 0.0, 0.0, 0.0)


def tilt(pitch_deg: float = 0.0, roll_deg: float = 0.0) -> Quat:
    return from_rotvec((math.radians(pitch_deg), math.radians(roll_deg), 0.0))


class Harness:
    """Drives a RobotAgent with a simulated Watch at the control rate."""

    def __init__(self, policy: ScriptedPolicy | None = None, config: AgentConfig | None = None):
        self.robot = MockRobot()
        self.sink = RecordingSink()
        self.policy = policy or ScriptedPolicy()
        self.agent = RobotAgent(self.robot, self.policy, self.sink, config)
        self.now = 0.0
        self._seq = itertools.count(1)
        self._req = itertools.count(1)
        self.acks: list[dict] = []
        self.agent.connect(self.now)

    @property
    def mode(self) -> Mode:
        return self.agent.sup.mode

    @property
    def epoch(self) -> int:
        return self.agent.sup.epoch

    def send(self, msg: dict) -> dict | None:
        return self.agent.handle_message({"protocol_version": PROTOCOL_VERSION, "session_id": "s-test", **msg}, self.now)

    def motion(self, q: Quat = NEUTRAL, gyro=(0.0, 0.0, 0.0), gravity=PALM_DOWN, epoch: int | None = None) -> None:
        self.send({
            "type": "watch.motion",
            "seq": next(self._seq),
            "sample_mono_ns": int(self.now * 1e9),
            "quaternion_wxyz": list(q),
            "gyro_rad_s": list(gyro),
            "gravity_g": list(gravity),
            "control_epoch": self.epoch if epoch is None else epoch,
        })

    def intent(self, intent: str, epoch: int | None = None, request_id: str | None = None) -> dict:
        ack = self.send({
            "type": "control.intent",
            "request_id": request_id or f"c-{next(self._req)}",
            "control_epoch": self.epoch if epoch is None else epoch,
            "intent": intent,
            "source": "watch-primary-action",
        })
        self.acks.append(ack)
        return ack

    def double_tap(self, **kw) -> dict:
        return self.intent("DOUBLE_TAP", **kw)

    def transcript(self, text: str | None) -> None:
        self.send({"type": "voice.transcript", "request_id": f"v-{next(self._req)}",
                   "control_epoch": self.epoch, "text": text})

    def run(self, seconds: float, *, watch: bool = True, **motion_kw) -> None:
        for _ in range(max(1, round(seconds / DT))):
            self.now += DT
            if watch:
                self.motion(**motion_kw)
            self.agent.tick(self.now)

    def take_manual(self) -> None:
        """HOLD/AWAIT_RECALIBRATION -> Double Tap -> still wrist -> MANUAL."""
        assert self.double_tap()["result"] == "accepted"
        self.run(0.6)
        assert self.mode is Mode.MANUAL, self.agent.sup.history[-1]

    def start_vla(self) -> None:
        self.take_manual()
        self.double_tap()
        self.run(0.6)
        assert self.mode is Mode.LISTENING
        self.transcript("把紅色積木放進盒子")
        assert self.mode is Mode.VLA_RUNNING

    @property
    def target(self) -> dict[str, float]:
        return self.robot.writes[-1]


@pytest.fixture
def h() -> Harness:
    return Harness()
