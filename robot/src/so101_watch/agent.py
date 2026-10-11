"""Local Robot Agent control loop (SPEC §10.2). `RobotAgent.tick` is the ONLY motor writer.

Time is passed in explicitly (`now`, monotonic seconds) so the whole loop runs
deterministically against MockRobot in tests.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from .calibration import CalibrationConfig, CalibrationTracker
from .gripper_estimator import GripperConfig, GripperEstimator
from .haptics import HapticConfig, HapticEmitter
from .motion_mapper import MotionConfig, MotionMapper, PlaceholderJointMapper, PlaceholderKinematicsConfig
from .protocol import (
    ControlIntent,
    HapticKind,
    Mode,
    Owner,
    RobotStatus,
    VoiceTranscript,
    WatchLifecycle,
    WatchMotion,
    parse_message,
    to_dict,
)
from .quat import Quat
from .safety import SafetyConfig, SafetyGate
from .supervisor import Supervisor, SupervisorConfig, Transition
from .task_router import TaskRouter, TaskRouterConfig
from .vla_client import PolicyBuffer, PolicyClient

_NO_WRITE_MODES = {Mode.DISCONNECTED, Mode.ESTOP_LATCHED}
_REQUIRED_CAMERAS = ("front", "wrist")


@dataclass
class AgentConfig:
    control_hz: float = 30.0
    motion_stale_ms: float = 250.0   # wrist pose this old: freeze in place (no motion proposed)
    motion_lost_ms: float = 1500.0   # this old: give up MANUAL / stop the VLA. WCSession on a real
                                     # watch stalls 300-600 ms now and then; dropping out of MANUAL
                                     # (and recalibrating) on every stall made it unusable.
    require_both_cameras: bool = True
    gripper_hold_squeeze: float = 2.0  # how far past the grasp point the target may sit
    supervisor: SupervisorConfig = field(default_factory=SupervisorConfig)
    calibration: CalibrationConfig = field(default_factory=CalibrationConfig)
    motion: MotionConfig = field(default_factory=MotionConfig)
    kinematics: PlaceholderKinematicsConfig = field(default_factory=PlaceholderKinematicsConfig)
    safety: SafetyConfig = field(default_factory=SafetyConfig)
    haptics: HapticConfig = field(default_factory=HapticConfig)
    gripper: GripperConfig = field(default_factory=GripperConfig)
    tasks: TaskRouterConfig = field(default_factory=TaskRouterConfig)


@dataclass(frozen=True)
class Proposal:
    source: Owner
    epoch: int
    target: dict[str, float]


@dataclass(frozen=True)
class TickRecord:
    at: float
    mode: Mode
    epoch: int
    source: Owner  # who produced the written target; NONE means hold
    target: dict[str, float]


class RobotAgent:
    def __init__(self, robot: Any, policy: PolicyClient, haptic_sink, config: AgentConfig | None = None,
                 session_id: str = "s-local") -> None:
        self.cfg = config or AgentConfig()
        self.robot = robot
        self.policy = policy
        self.session_id = session_id
        self.safety = SafetyGate(self.cfg.safety)
        self.haptics = HapticEmitter(haptic_sink, self.cfg.haptics, session_id)
        self.gripper = GripperEstimator(self.cfg.gripper)
        self.mapper = MotionMapper(self.cfg.motion)
        self.kinematics = PlaceholderJointMapper(self.cfg.kinematics)
        self.router = TaskRouter(self.cfg.tasks)
        self.policy_buffer = PolicyBuffer()
        self.sup = Supervisor(self.cfg.supervisor, on_transition=self._on_transition)

        self.status_out: list[dict] = []
        self.records: list[TickRecord] = []
        self._motion: WatchMotion | None = None
        self._motion_rx: float | None = None
        self._watch_active = True
        self._calibration: CalibrationTracker | None = None
        self._q0: Quat | None = None
        self._last_tick: float | None = None
        self._last_obs = None
        self._healthy = True

    # ------------------------------------------------------------ lifecycle

    def connect(self, now: float) -> None:
        self.robot.connect()
        obs = self.robot.read()
        self._last_obs = obs
        if not obs.ok:
            self.sup.on_fault("joint_read_error", now)
            return
        self.safety.reset(obs.positions)
        self.sup.on_ready(now)

    def physical_estop(self, now: float) -> None:
        self.sup.on_estop(now)

    def client_disconnected(self, now: float) -> None:
        """Phone link dropped: forget the last wrist sample so nothing keeps steering.

        MANUAL goes to HOLD now; a running VLA is stopped by the watchdog on the next tick.
        """
        self._motion, self._motion_rx = None, None
        self.sup.on_manual_lost("client_disconnected", now)

    def status(self) -> dict:
        s = self.sup
        return to_dict(RobotStatus(
            session_id=self.session_id, control_epoch=s.epoch, mode=s.mode, owner=s.owner,
            reason="snapshot", robot_holding=s.mode not in (Mode.MANUAL, Mode.VLA_RUNNING),
            vla_task_id=s.task_id,
        ))

    def drain_status(self) -> list[dict]:
        out, self.status_out = self.status_out, []
        return out

    # ------------------------------------------------------------ inbound

    def handle_message(self, raw: dict, now: float) -> dict | None:
        """Raises ProtocolError on malformed input; the gateway turns that into an error reply."""
        msg = parse_message(raw)
        if isinstance(msg, WatchMotion):
            self._motion, self._motion_rx = msg, now  # latest-only (SPEC §9.4)
            if self.sup.mode is Mode.CALIBRATING and self._calibration is not None:
                self._calibration.add(msg)
            return None
        if isinstance(msg, WatchLifecycle):
            self._watch_active = msg.state == "active"
            if not self._watch_active:
                self.sup.on_manual_lost("watch_inactive", now)
            return None
        if isinstance(msg, ControlIntent):
            return to_dict(self.sup.handle_intent(msg, now, healthy=self._healthy))
        if isinstance(msg, VoiceTranscript):
            self._on_transcript(msg, now)
            return None
        return None  # pragma: no cover

    def _on_transcript(self, msg: VoiceTranscript, now: float) -> None:
        if msg.control_epoch != self.sup.epoch or not self.sup.on_transcript(now):
            return
        route = self.router.route(msg.text)
        if route.kind == "stop":
            self.sup.request_stop("voice_stop", now)
        elif route.kind == "vla" and route.task_id and self._vla_ready(route.task_id):
            self.sup.on_task_accepted(route.task_id, now)
        else:
            self.sup.on_task_rejected(route.reason or "VLA_NOT_READY", now)

    def _vla_ready(self, task_id: str) -> bool:
        obs = self._last_obs
        cams = obs is not None and (not self.cfg.require_both_cameras or obs.cameras_ok(_REQUIRED_CAMERAS))
        return cams and bool(obs.ok) and self.policy.ready(task_id)

    # ------------------------------------------------------------ transitions

    def _on_transition(self, t: Transition) -> None:
        if t.dst is Mode.CALIBRATING:
            self._calibration = CalibrationTracker(self.cfg.calibration)
            self._q0 = None
            self.mapper.reset()
        if Mode.VLA_RUNNING in (t.src, t.dst):
            self.policy_buffer.clear()
        if t.dst is Mode.VLA_RUNNING:
            self.haptics.one_shot(HapticKind.VLA_STARTED, t.at, t.epoch)
        if t.dst is Mode.AWAIT_RECALIBRATION:
            self.haptics.one_shot(HapticKind.VLA_FINISHED, t.at, t.epoch)
        if t.dst is Mode.FAULT:
            self.haptics.one_shot(HapticKind.FAULT, t.at, t.epoch)
        if t.src is Mode.CALIBRATING:
            ok = t.dst in (Mode.MANUAL, Mode.LISTENING)
            self.haptics.one_shot(HapticKind.CALIBRATION_OK if ok else HapticKind.CALIBRATION_FAILED, t.at, t.epoch)
        status = RobotStatus(
            session_id=self.session_id,
            control_epoch=t.epoch,
            mode=t.dst,
            owner=self.sup.owner,
            reason=t.reason,
            robot_holding=t.dst not in (Mode.MANUAL, Mode.VLA_RUNNING, Mode.DISCONNECTED, Mode.ESTOP_LATCHED),
            vla_task_id=self.sup.task_id,
        )
        self.status_out.append(to_dict(status))

    # ------------------------------------------------------------ loop

    def tick(self, now: float) -> None:
        dt = 0.0 if self._last_tick is None else min(max(now - self._last_tick, 0.0), 2.0 / self.cfg.control_hz)
        self._last_tick = now

        obs = self.robot.read()
        self._last_obs = obs
        self._healthy = bool(obs.ok)
        if not obs.ok and self.sup.mode not in _NO_WRITE_MODES:
            self.sup.on_fault("joint_read_error", now)

        self.sup.check_timeouts(now)
        self._check_watchdogs(now)
        self._advance_calibration(obs, now)
        proposal = self._propose(obs, now, dt)

        mode = self.sup.mode
        if mode in _NO_WRITE_MODES:
            self.haptics.update_conditions(set(), now, self.sup.epoch)
            return

        if proposal is not None and self._admissible(proposal):
            target, conditions = self.safety.filter(proposal.target)
            source = proposal.source
        else:
            target, conditions = self.safety.hold(), self.safety.near_conditions()
            source = Owner.NONE
        self.haptics.update_conditions(conditions, now, self.sup.epoch)
        self._update_gripper(obs, target, now)

        self.robot.write(target)
        self.records.append(TickRecord(now, mode, self.sup.epoch, source, target))
        if mode is Mode.VLA_CANCELLING:
            self.sup.on_hold_confirmed(now)

    def _motion_age_ms(self, now: float) -> float:
        return float("inf") if self._motion_rx is None else (now - self._motion_rx) * 1000.0

    def _motion_fresh(self, now: float) -> bool:
        return self._motion_age_ms(now) <= self.cfg.motion_stale_ms

    def _check_watchdogs(self, now: float) -> None:
        # Between stale and lost, MANUAL proposes nothing (see _propose): the arm holds still.
        if self._motion_age_ms(now) <= self.cfg.motion_lost_ms:
            return
        if self.sup.mode is Mode.MANUAL:
            self.haptics.one_shot(HapticKind.CONNECTION_LOST, now, self.sup.epoch)
            self.sup.on_manual_lost("motion_stale", now)
        elif self.sup.mode is Mode.VLA_RUNNING:
            # Without the Watch link nobody can Double Tap to interrupt, so the VLA stops too.
            self.haptics.one_shot(HapticKind.CONNECTION_LOST, now, self.sup.epoch)
            self.sup.request_stop("watch_link_lost", now)

    def _advance_calibration(self, obs, now: float) -> None:
        if self.sup.mode is not Mode.CALIBRATING or self._calibration is None:
            return
        if not self._watch_active:
            return self._calibration_failed("watch_inactive", now)
        result = self._calibration.result()
        if result is None:
            return
        if not (obs.ok and self._motion_fresh(now)):
            return self._calibration_failed("preconditions", now)
        self._q0 = result.q0
        self.mapper.reset()
        self.sup.on_calibration_result(True, result.reason, now)

    def _calibration_failed(self, reason: str, now: float) -> None:
        self.sup.on_calibration_result(False, reason, now)

    def _propose(self, obs, now: float, dt: float) -> Proposal | None:
        epoch = self.sup.epoch
        if self.sup.mode is Mode.MANUAL:
            m = self._motion
            if m is None or self._q0 is None or m.control_epoch != epoch or not self._motion_fresh(now):
                return None  # hold still; a stale pose must never keep driving a velocity
            v = self.mapper.velocity(self._q0, m.quaternion_wxyz, dt)
            return Proposal(Owner.MANUAL, epoch, self.kinematics.integrate(v, self.safety.target, dt))

        if self.sup.mode is Mode.VLA_RUNNING:
            if self.cfg.require_both_cameras and not obs.cameras_ok(_REQUIRED_CAMERAS):
                self.sup.on_vla_finished("camera_lost", now)
                return None
            action = self.policy_buffer.next_action_for_epoch(epoch)
            if action is None:
                result = self.policy.infer(obs, self.sup.task_id or "", epoch)
                if result.done:
                    self.sup.on_vla_finished("done", now)
                    return None
                self.policy_buffer.push(result.epoch, result.actions)
                action = self.policy_buffer.next_action_for_epoch(epoch)
            return None if action is None else Proposal(Owner.VLA, epoch, action)
        return None

    def _admissible(self, p: Proposal) -> bool:
        """Re-checked at write time: the mode may have changed since the proposal was made."""
        if p.epoch != self.sup.epoch:
            return False
        return (p.source is Owner.MANUAL and self.sup.mode is Mode.MANUAL) or (
            p.source is Owner.VLA and self.sup.mode is Mode.VLA_RUNNING
        )

    def _update_gripper(self, obs, target: dict[str, float], now: float) -> None:
        g = "gripper"
        events = self.gripper.update(obs.positions[g], obs.velocities[g], obs.gripper_current, target[g])
        for ev in events:
            if ev.kind is HapticKind.GRASP_LIKELY:
                self.safety.gripper_floor = obs.positions[g] - self.cfg.gripper_hold_squeeze
            self.haptics.one_shot(
                ev.kind, now, self.sup.epoch,
                dedup_key=(ev.kind, ev.transaction_id),
                transaction_id=ev.transaction_id, confidence=ev.confidence, evidence=ev.evidence,
            )
        if not self.gripper.active:
            self.safety.gripper_floor = None
