"""Hardware-free stand-ins (SPEC §13 step 2): run every acceptance test with no motor attached."""

from __future__ import annotations

from dataclasses import dataclass, field

from .protocol import HapticEvent
from .safety import JOINTS
from .vla_client import PolicyResult


@dataclass
class Observation:
    positions: dict[str, float]
    velocities: dict[str, float]  # position units per write (mock has no wall clock)
    gripper_current: float
    images: dict[str, object | None]
    ok: bool = True

    def cameras_ok(self, names: tuple[str, ...]) -> bool:
        return all(self.images.get(n) is not None for n in names)


class MockRobot:
    """Ideal position servo with a gripper end-stop and an optional object between the jaws.

    The empty-gripper end-stop sits *above* the gripper soft limit, so commanding a
    full close stalls at the end-stop with high current. That is exactly the
    situation that must not be reported as a grasp (TC04).
    """

    def __init__(
        self,
        initial: dict[str, float] | None = None,
        gripper_endstop: float = 2.0,
        baseline_current: float = 50.0,
        stall_current: float = 400.0,
    ) -> None:
        self.positions = dict(initial or {j: 0.0 for j in JOINTS[:-1]} | {"gripper": 50.0})
        self.velocities = {j: 0.0 for j in JOINTS}
        self.gripper_endstop = gripper_endstop
        self.object_at: float | None = None  # jaw position where an object blocks closing
        self.baseline_current = baseline_current
        self.stall_current = stall_current
        self.connected = False
        self.read_ok = True
        self.cameras: dict[str, bool] = {"front": True, "wrist": True}
        self.writes: list[dict[str, float]] = []
        self._gripper_blocked = False

    def connect(self) -> None:
        self.connected = True

    def read(self) -> Observation:
        current = self.stall_current if self._gripper_blocked else self.baseline_current
        return Observation(
            positions=dict(self.positions),
            velocities=dict(self.velocities),
            gripper_current=current,
            images={n: (object() if on else None) for n, on in self.cameras.items()},
            ok=self.read_ok,
        )

    def write(self, target: dict[str, float]) -> None:
        if not self.connected:
            raise RuntimeError("write before connect")
        self.writes.append(dict(target))
        for j in JOINTS:
            want = target[j]
            if j == "gripper":
                floor = max(self.gripper_endstop, self.object_at if self.object_at is not None else float("-inf"))
                self._gripper_blocked = want < floor - 1e-6
                want = max(want, floor)
            self.velocities[j] = want - self.positions[j]
            self.positions[j] = want


class ScriptedPolicy:
    """Returns pre-baked chunks in order, then reports done."""

    def __init__(self, chunks: list[list[dict[str, float]]] | None = None, ready_tasks=("pick_red_cube_into_box",)):
        self.chunks = list(chunks or [])
        self.ready_tasks = set(ready_tasks)
        self.calls: list[tuple[str, int]] = []

    def ready(self, task_id: str) -> bool:
        return task_id in self.ready_tasks

    def infer(self, obs: Observation, task_id: str, epoch: int) -> PolicyResult:
        self.calls.append((task_id, epoch))
        if self.chunks:
            return PolicyResult(epoch, self.chunks.pop(0))
        return PolicyResult(epoch, [], done=True)


@dataclass
class RecordingSink:
    events: list[HapticEvent] = field(default_factory=list)
    fail: bool = False

    def __call__(self, ev: HapticEvent) -> None:
        if self.fail:
            raise ConnectionError("watch unreachable")
        self.events.append(ev)

    def played(self, kind=None) -> list[HapticEvent]:
        return [e for e in self.events if e.play_haptic and (kind is None or e.kind is kind)]
