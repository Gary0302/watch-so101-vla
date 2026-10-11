"""Randomized event storms: invariants must hold no matter the ordering (SPEC §4.1)."""

from __future__ import annotations

import random

import pytest

from conftest import NEUTRAL, Harness, tilt
from so101_watch.mocks import ScriptedPolicy
from so101_watch.protocol import Mode, Owner

ACTIONS = ["tick", "tick", "tick", "tap", "tap_stale", "stop", "task", "junk_task", "silence",
           "inactive", "active", "tilt", "still", "cam_off", "cam_on", "late_chunk"]


@pytest.mark.parametrize("seed", range(40))
def test_invariants_under_random_events(seed: int):
    rng = random.Random(seed)
    chunks = [[{"shoulder_pan": rng.uniform(-100, 100), "gripper": rng.uniform(-10, 110)} for _ in range(8)]
              for _ in range(20)]
    h = Harness(ScriptedPolicy(chunks))
    q = NEUTRAL
    watch_on = True
    for _ in range(600):
        a = rng.choice(ACTIONS)
        if a == "tap":
            h.double_tap()
        elif a == "tap_stale":
            h.double_tap(epoch=h.epoch - rng.randint(1, 3))
        elif a == "stop":
            h.intent("STOP")
        elif a == "task":
            h.transcript("把紅色積木放進盒子")
        elif a == "junk_task":
            h.transcript("rm -rf the robot")
        elif a == "silence":
            watch_on = False
        elif a in ("inactive", "active"):
            h.send({"type": "watch.lifecycle", "seq": 1, "state": a})
            watch_on = True
        elif a == "tilt":
            q = tilt(rng.uniform(-60, 60), rng.uniform(-60, 60))
        elif a == "still":
            q = NEUTRAL
        elif a == "cam_off":
            h.robot.cameras["front"] = False
        elif a == "cam_on":
            h.robot.cameras["front"] = True
        elif a == "late_chunk":
            h.agent.policy_buffer.push(h.epoch - 1, [{"shoulder_pan": 999.0}])
        h.run(1 / 30, watch=watch_on, q=q)
        if rng.random() < 0.05:
            watch_on = True

    sup = h.agent.sup
    for prev, t in zip(sup.history, sup.history[1:]):
        assert t.epoch == prev.epoch + 1
    for t in sup.history:
        if t.dst is Mode.MANUAL:
            assert t.src is Mode.CALIBRATING
        if t.src in (Mode.VLA_RUNNING, Mode.VLA_CANCELLING):
            assert t.dst in (Mode.VLA_CANCELLING, Mode.AWAIT_RECALIBRATION, Mode.FAULT, Mode.ESTOP_LATCHED)
    lo, hi = h.agent.cfg.safety.soft_limits["shoulder_pan"]
    for r in h.agent.records:
        if r.source is Owner.VLA:
            assert r.mode is Mode.VLA_RUNNING
        if r.source is Owner.MANUAL:
            assert r.mode is Mode.MANUAL
        assert lo <= r.target["shoulder_pan"] <= hi
        assert r.target["shoulder_pan"] != 999.0
