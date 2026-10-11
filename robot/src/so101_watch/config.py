"""TOML config -> AgentConfig + RobotConfig. Unknown keys are errors, not silently ignored."""

from __future__ import annotations

import dataclasses
import tomllib
from pathlib import Path
from typing import Any

from .agent import AgentConfig
from .robot_worker import RobotConfig


class ConfigError(ValueError):
    pass


def _apply(obj: Any, data: dict[str, Any], where: str) -> None:
    fields = {f.name: f for f in dataclasses.fields(obj)}
    for key, value in data.items():
        if key not in fields:
            raise ConfigError(f"unknown key {where}{key}")
        current = getattr(obj, key)
        if dataclasses.is_dataclass(current):
            if not isinstance(value, dict):
                raise ConfigError(f"{where}{key} must be a table")
            _apply(current, value, f"{where}{key}.")
        elif key == "soft_limits":
            setattr(obj, key, _soft_limits(current, value, f"{where}{key}"))
        elif isinstance(current, tuple):
            setattr(obj, key, tuple(value))
        elif isinstance(current, bool) and not isinstance(value, bool):
            raise ConfigError(f"{where}{key} must be true/false")
        elif isinstance(current, float) and isinstance(value, int) and not isinstance(value, bool):
            setattr(obj, key, float(value))
        elif isinstance(current, dict) and isinstance(value, dict):
            setattr(obj, key, current | value)
        elif current is not None and not isinstance(value, type(current)):
            raise ConfigError(f"{where}{key}: expected {type(current).__name__}, got {type(value).__name__}")
        else:
            setattr(obj, key, value)


def _soft_limits(current: dict[str, tuple[float, float]], value: dict[str, Any], where: str):
    out = dict(current)
    for joint, lim in value.items():
        if joint not in current:
            raise ConfigError(f"{where}: unknown joint {joint}")
        lo, hi = (float(x) for x in lim)
        if not lo < hi:
            raise ConfigError(f"{where}.{joint}: lower limit must be below upper")
        out[joint] = (lo, hi)
    return out


def load_config(path: str | Path) -> tuple[AgentConfig, RobotConfig]:
    data = tomllib.loads(Path(path).read_text())
    robot = RobotConfig()
    _apply(robot, data.pop("robot", {}), "robot.")
    agent = AgentConfig()
    _apply(agent, data, "")
    return agent, robot
