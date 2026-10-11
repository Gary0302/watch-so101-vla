"""Real SO-101 follower over LeRobot's FeetechMotorsBus (SPEC §9).

Same interface as MockRobot (connect / read / write / close), so RobotAgent stays the
single motor writer. Deliberately *not* SO101Follower.connect(): that may prompt for and
write calibration, and configure() rewrites PID/mode registers on a shared arm.

Rules this module keeps:
  * never writes calibration or configuration registers; mismatches refuse to start;
  * refuses a serial port another process holds (tools/port_guard semantics, never kills);
  * Goal_Position := Present_Position before torque on, so enabling torque cannot jump;
  * disconnect(disable_torque=False) always: dropping the arm is worse than holding it;
  * any bus error turns every later observation into ok=False, which the agent treats as FAULT.
    RESET_FAULT is then rejected (FAULT_CONDITION_PERSISTS) until the agent is restarted: a servo
    that browned out comes back with torque off, and the old hold target may be far from where the
    arm now is. Restarting re-syncs Goal_Position to Present_Position before torque on.

Units: body joints in degrees (MotorNormMode.DEGREES), gripper 0..100. If the friend's VLA
was trained with use_degrees=False (range -100..100), its actions need converting in vla_client.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from .mocks import Observation
from .safety import JOINTS

log = logging.getLogger(__name__)

MOTOR_IDS = {"shoulder_pan": 1, "shoulder_lift": 2, "elbow_flex": 3, "wrist_flex": 4, "wrist_roll": 5, "gripper": 6}
POSITION_MODE = 0


class RobotSetupError(RuntimeError):
    pass


class DeviceBusy(RobotSetupError):
    pass


def port_holders(path: str) -> list[str]:
    """`pid command` for processes holding `path` (same logic as tools/port_guard.py)."""
    if shutil.which("lsof"):
        r = subprocess.run(["lsof", "-F", "pc", path], capture_output=True, text=True)
        out, pid = [], None
        for line in r.stdout.splitlines():
            if line.startswith("p"):
                pid = line[1:]
            elif line.startswith("c") and pid:
                out.append(f"{pid} {line[1:]}")
        return out
    if shutil.which("fuser"):
        r = subprocess.run(["fuser", path], capture_output=True, text=True)
        return [f"{pid} ?" for pid in r.stdout.split()]
    raise DeviceBusy(f"cannot check whether {path} is in use: neither lsof nor fuser is installed")


def assert_port_free(path: str) -> None:
    # Inside docker, host processes are invisible; tools/aup_agent.sh checks on the host and
    # names exactly the device it checked. Any other device is still checked here.
    if os.environ.get("SO101_PORT_CHECKED_ON_HOST") == path:
        return
    held = port_holders(path)
    if held:
        raise DeviceBusy(f"{path} is in use by: {', '.join(held)}. Not touching it; coordinate first.")


@dataclass
class RobotConfig:
    port: str = "/dev/ttyACM0"
    calibration_path: str = ""  # LeRobot so101_follower/<id>.json; copy it, never edit the owner's
    expect_torque_off_at_start: bool = False  # True: refuse if someone else left torque on (arm in use)


def _lerobot_motors():
    try:
        import lerobot.motors as motors
        import lerobot.motors.feetech as feetech
    except ImportError as e:
        raise RobotSetupError(
            f"lerobot is not importable ({e}). On aup, install lerobot==0.6.1 with --no-deps plus its "
            "minimal deps (see tools/aup_probe.sh).") from e
    return motors, feetech


def load_calibration(path: str | Path) -> dict[str, Any]:
    """LeRobot calibration JSON -> {motor: MotorCalibration}. Validates ids against MOTOR_IDS."""
    MotorCalibration = _lerobot_motors()[0].MotorCalibration

    raw = json.loads(Path(path).read_text())
    missing = set(MOTOR_IDS) - set(raw)
    if missing:
        raise RobotSetupError(f"calibration {path} lacks motors: {sorted(missing)}")
    cal = {}
    for name, motor_id in MOTOR_IDS.items():
        c = raw[name]
        if c["id"] != motor_id:
            raise RobotSetupError(f"calibration {path}: {name} has id {c['id']}, expected {motor_id}")
        cal[name] = MotorCalibration(id=c["id"], drive_mode=c["drive_mode"], homing_offset=c["homing_offset"],
                                     range_min=c["range_min"], range_max=c["range_max"])
    return cal


def make_feetech_bus(port: str, calibration: dict[str, Any]) -> Any:
    motors_mod, feetech = _lerobot_motors()
    Motor, MotorNormMode, FeetechMotorsBus = motors_mod.Motor, motors_mod.MotorNormMode, feetech.FeetechMotorsBus

    motors = {
        name: Motor(motor_id, "sts3215", MotorNormMode.RANGE_0_100 if name == "gripper" else MotorNormMode.DEGREES)
        for name, motor_id in MOTOR_IDS.items()
    }
    return FeetechMotorsBus(port=port, motors=motors, calibration=calibration)


CameraSource = Callable[[], dict[str, object | None]]


def no_cameras() -> dict[str, object | None]:
    """Until camera_worker exists: cameras report missing, so VLA can never start (fails closed)."""
    return {"front": None, "wrist": None}


class SO101Robot:
    def __init__(
        self,
        cfg: RobotConfig,
        *,
        bus_factory: Callable[[str, dict[str, Any]], Any] = make_feetech_bus,
        calibration_loader: Callable[[str], dict[str, Any]] = load_calibration,
        cameras: CameraSource = no_cameras,
        port_guard: Callable[[str], None] = assert_port_free,
    ) -> None:
        self.cfg = cfg
        self._bus_factory = bus_factory
        self._load_calibration = calibration_loader
        self._cameras = cameras
        self._port_guard = port_guard
        self.bus: Any = None
        self.connected = False
        self._last_pos: dict[str, float] | None = None
        self._bus_error: str | None = None

    def connect(self) -> None:
        if not self.cfg.calibration_path:
            raise RobotSetupError("robot.calibration_path is required")
        self._port_guard(self.cfg.port)
        calibration = self._load_calibration(self.cfg.calibration_path)
        bus = self._bus_factory(self.cfg.port, calibration)
        bus.connect(handshake=True)
        try:
            self._check_setup(bus)
            present = bus.sync_read("Present_Position")
            bus.sync_write("Goal_Position", present)  # torque-on must not move anything
            bus.enable_torque(num_retry=2)
        except Exception:
            bus.disconnect(disable_torque=False)
            raise
        self.bus = bus
        self._last_pos = {j: float(present[j]) for j in JOINTS}
        self.connected = True
        log.info("SO-101 connected on %s, holding at %s", self.cfg.port, self._last_pos)

    def _check_setup(self, bus: Any) -> None:
        if not bus.is_calibrated:
            raise RobotSetupError(
                "motor calibration differs from the calibration file; refusing to write it. "
                "Ask the arm's owner which file is current.")
        modes = bus.sync_read("Operating_Mode", normalize=False)
        wrong = {m: v for m, v in modes.items() if v != POSITION_MODE}
        if wrong:
            raise RobotSetupError(f"motors not in position mode: {wrong}; not reconfiguring a shared arm")
        if self.cfg.expect_torque_off_at_start:
            torque = bus.sync_read("Torque_Enable", normalize=False)
            on = [m for m, v in torque.items() if v]
            if on:
                raise RobotSetupError(f"torque already on for {on}: someone may be using the arm")

    def read(self) -> Observation:
        assert self._last_pos is not None, "read before connect"
        images = self._cameras()
        if self._bus_error is not None:
            return self._failed(images)
        try:
            pos = self.bus.sync_read("Present_Position", num_retry=1)
            current = self.bus.sync_read("Present_Current", ["gripper"], normalize=False, num_retry=1)
        except (ConnectionError, RuntimeError, OSError) as e:
            self._bus_error = f"read: {e}"
            log.error("bus read failed: %s", e)
            return self._failed(images)
        positions = {j: float(pos[j]) for j in JOINTS}
        velocities = {j: positions[j] - self._last_pos[j] for j in JOINTS}  # per tick, like MockRobot
        self._last_pos = positions
        return Observation(positions, velocities, float(current["gripper"]), images)

    def _failed(self, images: dict[str, object | None]) -> Observation:
        assert self._last_pos is not None
        return Observation(dict(self._last_pos), {j: 0.0 for j in JOINTS}, 0.0, images, ok=False)

    def write(self, target: dict[str, float]) -> None:
        if not self.connected:
            raise RuntimeError("write before connect")
        if self._bus_error is not None:
            return  # the next read reports ok=False; no blind writes into a broken bus
        try:
            self.bus.sync_write("Goal_Position", {j: target[j] for j in JOINTS})
        except (ConnectionError, RuntimeError, OSError) as e:
            self._bus_error = f"write: {e}"
            log.error("bus write failed: %s", e)

    def close(self) -> None:
        if self.bus is not None:
            self.bus.disconnect(disable_torque=False)  # keep holding; never let the arm drop
            self.bus = None
        self.connected = False
