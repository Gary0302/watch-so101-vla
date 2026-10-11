"""Deterministic transcript -> task routing (SPEC §5.3). No free-form motor commands."""

from __future__ import annotations

import re
from dataclasses import dataclass, field


def _default_tasks() -> dict[str, tuple[str, ...]]:
    return {
        "pick_red_cube_into_box": (
            "把紅色積木放進盒子",
            "紅色積木放進盒子",
            "紅色方塊放進盒子",
            "pick red cube",
            "red cube into the box",
            "put the red cube in the box",
        ),
    }


@dataclass
class TaskRouterConfig:
    allowlist: dict[str, tuple[str, ...]] = field(default_factory=_default_tasks)
    stop_phrases: tuple[str, ...] = ("stop", "hold", "停", "停止", "暫停")


@dataclass(frozen=True)
class Route:
    kind: str  # "vla" | "stop" | "unknown"
    task_id: str | None = None
    reason: str = ""


_STRIP = re.compile(r"[\s\W_]+", re.UNICODE)


def _norm(text: str) -> str:
    return _STRIP.sub("", text.lower())


class TaskRouter:
    def __init__(self, config: TaskRouterConfig) -> None:
        self.cfg = config

    def route(self, text: str | None) -> Route:
        if not text or not _norm(text):
            return Route("unknown", reason="EMPTY_TRANSCRIPT")
        t = _norm(text)
        if t in {_norm(p) for p in self.cfg.stop_phrases}:
            return Route("stop", reason="STOP_PHRASE")
        for task_id, phrases in self.cfg.allowlist.items():
            if any(_norm(p) in t for p in phrases):
                return Route("vla", task_id=task_id)
        # Home / open / close gripper are listed in §5.3 but not wired in v1: treated as unknown.
        return Route("unknown", reason="NOT_IN_ALLOWLIST")
