"""Policy-server adapter boundary (SPEC §8.2). The policy only *suggests* actions.

Every chunk is tagged with the control_epoch it was requested under. A chunk
from any other epoch is discarded on read, so a late reply from the GPU after
an interrupt can never reach the motor.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field
from typing import Any, Protocol


@dataclass(frozen=True)
class PolicyResult:
    epoch: int
    actions: list[dict[str, float]] = field(default_factory=list)
    done: bool = False  # policy reports task finished (success or give-up)


class PolicyClient(Protocol):
    def ready(self, task_id: str) -> bool: ...

    def infer(self, obs: Any, task_id: str, epoch: int) -> PolicyResult: ...


class PolicyBuffer:
    def __init__(self) -> None:
        self._epoch: int | None = None
        self._queue: deque[dict[str, float]] = deque()
        self.dropped_actions = 0

    def push(self, epoch: int, actions: list[dict[str, float]]) -> None:
        if self._epoch != epoch:
            self.dropped_actions += len(self._queue)
            self._queue.clear()
            self._epoch = epoch
        self._queue.extend(actions)

    def next_action_for_epoch(self, epoch: int) -> dict[str, float] | None:
        if self._epoch != epoch:
            self.clear()
            return None
        return self._queue.popleft() if self._queue else None

    def clear(self) -> None:
        self.dropped_actions += len(self._queue)
        self._queue.clear()
        self._epoch = None

    def __len__(self) -> int:
        return len(self._queue)
