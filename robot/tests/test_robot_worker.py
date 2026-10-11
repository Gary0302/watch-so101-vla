"""SO101Robot against a fake FeetechMotorsBus: the safety rules, without an arm."""

import pytest

from so101_watch.agent import RobotAgent
from so101_watch.mocks import RecordingSink, ScriptedPolicy
from so101_watch.protocol import ControlIntent, Intent, Mode
from so101_watch.robot_worker import DeviceBusy, RobotConfig, RobotSetupError, SO101Robot
from so101_watch.safety import JOINTS


class FakeBus:
    def __init__(self, calibrated=True, modes=None, torque_on=False):
        self.calls: list[tuple] = []
        self.is_calibrated = calibrated
        self.pos = {j: 10.0 for j in JOINTS} | {"gripper": 40.0}
        self.modes = modes or {j: 0 for j in JOINTS}
        self.torque = {j: int(torque_on) for j in JOINTS}
        self.fail_reads = False
        self.fail_writes = False
        self.raw = {j: 2000 for j in JOINTS}
        self.limits = ({j: 1000 for j in JOINTS}, {j: 3000 for j in JOINTS})

    def connect(self, handshake=True):
        self.calls.append(("connect",))

    def disconnect(self, disable_torque=True):
        self.calls.append(("disconnect", disable_torque))

    def sync_read(self, reg, motors=None, *, normalize=True, num_retry=0):
        self.calls.append(("read", reg))
        if self.fail_reads:
            raise ConnectionError("no status packet")
        if reg == "Present_Position":
            return dict(self.raw) if not normalize else dict(self.pos)
        if reg == "Min_Position_Limit":
            return dict(self.limits[0])
        if reg == "Max_Position_Limit":
            return dict(self.limits[1])
        if reg == "Present_Current":
            return {"gripper": 12}
        if reg == "Operating_Mode":
            return dict(self.modes)
        if reg == "Torque_Enable":
            return dict(self.torque)
        raise KeyError(reg)

    def sync_write(self, reg, values, *, normalize=True, num_retry=0):
        self.calls.append(("write", reg, dict(values)))
        if self.fail_writes:
            raise ConnectionError("port closed")
        if reg == "Goal_Position":
            self.pos = dict(values)  # ideal servo

    def enable_torque(self, motors=None, num_retry=0):
        self.calls.append(("enable_torque",))

    def disable_torque(self, motors=None, num_retry=0):  # pragma: no cover - must never be called
        self.calls.append(("disable_torque",))


def make(bus, **cfg):
    guarded = []
    robot = SO101Robot(RobotConfig(port="/dev/fake", calibration_path="/x.json", **cfg),
                       bus_factory=lambda port, cal: bus, calibration_loader=lambda p: {},
                       port_guard=guarded.append)
    return robot, guarded


def test_connect_syncs_goal_before_torque_and_checks_port():
    bus = FakeBus()
    robot, guarded = make(bus)
    robot.connect()
    assert guarded == ["/dev/fake"]
    names = [c[0] if c[0] != "write" else f"write:{c[1]}" for c in bus.calls]
    assert names.index("write:Goal_Position") < names.index("enable_torque")
    goal = next(c for c in bus.calls if c[:2] == ("write", "Goal_Position"))
    assert goal[2] == bus.pos


def test_never_writes_calibration_or_config_and_never_drops_the_arm():
    bus = FakeBus()
    robot, _ = make(bus)
    robot.connect()
    robot.write({j: 11.0 for j in JOINTS})
    robot.close()
    written = {c[1] for c in bus.calls if c[0] == "write"}
    assert written == {"Goal_Position"}
    assert ("disable_torque",) not in bus.calls
    assert ("disconnect", False) in bus.calls and ("disconnect", True) not in bus.calls


@pytest.mark.parametrize("bus,cfg,msg", [
    (FakeBus(calibrated=False), {}, "calibration"),
    (FakeBus(modes={j: 0 for j in JOINTS} | {"elbow_flex": 3}), {}, "position mode"),
    (FakeBus(torque_on=True), {"expect_torque_off_at_start": True}, "torque already on"),
])
def test_refuses_to_start_without_touching_motors(bus, cfg, msg):
    robot, _ = make(bus, **cfg)
    with pytest.raises(RobotSetupError, match=msg):
        robot.connect()
    assert not any(c[0] in ("write", "enable_torque") for c in bus.calls)
    assert bus.calls[-1] == ("disconnect", False)


def test_busy_port_stops_before_opening_bus():
    bus = FakeBus()

    def busy(path):
        raise DeviceBusy(f"{path} in use")

    robot = SO101Robot(RobotConfig(port="/dev/fake", calibration_path="/x.json"),
                       bus_factory=lambda p, c: bus, calibration_loader=lambda p: {}, port_guard=busy)
    with pytest.raises(DeviceBusy):
        robot.connect()
    assert bus.calls == []


def test_read_reports_positions_velocity_and_raw_current():
    bus = FakeBus()
    robot, _ = make(bus)
    robot.connect()
    bus.pos["gripper"] = 37.0
    obs = robot.read()
    assert obs.ok and obs.positions["gripper"] == 37.0
    assert obs.velocities["gripper"] == pytest.approx(-3.0)
    assert obs.gripper_current == 12.0
    assert not obs.cameras_ok(("front", "wrist"))  # no camera_worker yet -> VLA cannot start


def test_bus_error_latches_ok_false_and_stops_writes():
    bus = FakeBus()
    robot, _ = make(bus)
    robot.connect()
    bus.fail_reads = True
    assert robot.read().ok is False
    bus.fail_reads = False
    n = len(bus.calls)
    robot.write({j: 0.0 for j in JOINTS})
    assert robot.read().ok is False  # still latched: restart the agent to re-sync
    assert len(bus.calls) == n


def test_agent_on_real_worker_faults_on_bus_error_and_refuses_reset():
    bus = FakeBus()
    robot, _ = make(bus)
    agent = RobotAgent(robot, ScriptedPolicy(), RecordingSink())
    agent.connect(0.0)
    assert agent.sup.mode is Mode.HOLD
    agent.tick(0.033)
    bus.fail_writes = True
    robot.write({j: 0.0 for j in JOINTS})
    agent.tick(0.066)
    assert agent.sup.mode is Mode.FAULT
    ack = agent.sup.handle_intent(ControlIntent("r", "s", agent.sup.epoch, Intent.RESET_FAULT, "local_operator"),
                                  0.1, healthy=agent._healthy)
    assert ack.reason == "FAULT_CONDITION_PERSISTS"


def test_host_checked_port_skips_only_that_device(monkeypatch):
    from so101_watch import robot_worker

    monkeypatch.setenv("SO101_PORT_CHECKED_ON_HOST", "/dev/ttyACM0")
    monkeypatch.setattr(robot_worker, "port_holders", lambda p: ["123 python"])
    robot_worker.assert_port_free("/dev/ttyACM0")
    with pytest.raises(DeviceBusy):
        robot_worker.assert_port_free("/dev/ttyACM1")


def test_refuses_torque_on_when_a_joint_rests_past_its_servo_limit():
    bus = FakeBus()
    bus.raw["wrist_flex"] = 3140  # max 3000: torque-on would snap it to the limit
    robot = SO101Robot(RobotConfig(port="/dev/fake", calibration_path="cal.json"),
                       bus_factory=lambda port, cal: bus, calibration_loader=lambda p: {},
                       port_guard=lambda p: None)
    with pytest.raises(RobotSetupError, match="wrist_flex"):
        robot.connect()
    assert not any(c[0] in ("write", "enable_torque") for c in bus.calls)
    assert ("disconnect", False) in bus.calls
