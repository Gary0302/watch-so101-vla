"""SPEC §12 acceptance tests TC01-TC12, run entirely against MockRobot."""

from __future__ import annotations

import pytest

from conftest import NEUTRAL, Harness, tilt
from so101_watch.mocks import ScriptedPolicy
from so101_watch.protocol import HapticKind, Mode, Owner


def _gripper_close_chunks(start=50.0, step=3.0, hold_ticks=30):
    closing = [{"gripper": max(0.0, start - step * i)} for i in range(1, int(start / step) + 2)]
    return [closing + [{"gripper": 0.0}] * hold_ticks]


def test_tc01_unsteady_calibration_never_enables_manual(h: Harness):
    start = dict(h.robot.positions)
    h.double_tap()
    assert h.mode is Mode.CALIBRATING
    h.run(4.0, gyro=(0.6, 0.0, 0.0))  # wrist never still
    assert h.mode is Mode.HOLD
    assert all(t.dst is not Mode.MANUAL for t in h.agent.sup.history)
    assert all(w == start for w in h.robot.writes)
    assert h.sink.played(HapticKind.CALIBRATION_FAILED)


def test_tc01_bad_posture_never_enables_manual(h: Harness):
    h.double_tap()
    h.run(4.0, gravity=(0.0, -1.0, 0.0))  # watch face sideways, not palm down
    assert h.mode is Mode.HOLD


def test_tc02_neutral_wrist_means_zero_velocity_and_no_home(h: Harness):
    start = dict(h.robot.positions)
    h.take_manual()
    h.run(2.0, q=NEUTRAL)
    h.run(1.0, q=tilt(pitch_deg=3.0))  # inside the 5 deg dead-zone
    assert h.target == start

    h.run(1.0, q=tilt(pitch_deg=30.0))
    moved = h.target["shoulder_lift"]
    assert moved > 5.0
    h.run(2.0, q=NEUTRAL)
    # Back to neutral: the arm stops where it is (after the accel ramp) and never returns home.
    settled = h.target["shoulder_lift"]
    assert settled >= moved
    h.run(1.0, q=NEUTRAL)
    assert h.target["shoulder_lift"] == settled


def test_tc03_limit_clamps_outward_once_and_inward_still_works(h: Harness):
    h.take_manual()
    h.run(5.0, q=tilt(pitch_deg=40.0))  # keeps pushing past the +90 soft limit
    assert h.target["shoulder_lift"] == pytest.approx(90.0)
    hits = [e for e in h.sink.played(HapticKind.LIMIT_HIT) if e.axis == "shoulder_lift"]
    assert len(hits) == 1 and hits[0].limit_type == "soft_joint"
    assert len([e for e in h.sink.played(HapticKind.NEAR_LIMIT) if e.axis == "shoulder_lift"]) == 1

    h.run(1.0, q=tilt(pitch_deg=-40.0))
    assert h.target["shoulder_lift"] < 80.0


def test_tc04_empty_gripper_endstop_is_not_a_grasp():
    h = Harness(ScriptedPolicy(_gripper_close_chunks()))
    h.start_vla()
    h.run(3.0)
    assert h.robot.positions["gripper"] == pytest.approx(h.robot.gripper_endstop)
    kinds = {e.kind for e in h.sink.events}
    assert HapticKind.GRASP_LIKELY not in kinds
    assert HapticKind.CONTACT_SUSPECTED not in kinds


def test_tc05_grasp_mid_close_buzzes_once_and_stops_squeezing():
    h = Harness(ScriptedPolicy(_gripper_close_chunks()))
    h.robot.object_at = 30.0
    h.start_vla()
    h.run(3.0)
    assert len(h.sink.played(HapticKind.GRASP_LIKELY)) == 1
    assert len([e for e in h.sink.events if e.kind is HapticKind.CONTACT_SUSPECTED]) <= 1
    grasp = [e for e in h.sink.events if e.kind is HapticKind.GRASP_LIKELY][0]
    assert grasp.confidence < 1.0 and grasp.transaction_id == 1
    # Target relaxed to just past the contact point instead of driving to 0.
    assert h.target["gripper"] == pytest.approx(30.0 - h.agent.cfg.gripper_hold_squeeze)


def test_tc06_vla_finish_goes_to_await_recalibration_and_ignores_wrist():
    h = Harness(ScriptedPolicy([[{"shoulder_pan": 1.0}, {"shoulder_pan": 2.0}]]))
    h.start_vla()
    h.run(0.5)
    assert h.mode is Mode.AWAIT_RECALIBRATION
    assert h.sink.played(HapticKind.VLA_FINISHED)
    frozen = dict(h.target)
    h.run(2.0, q=tilt(pitch_deg=40.0, roll_deg=-30.0))
    assert h.mode is Mode.AWAIT_RECALIBRATION
    assert h.target == frozen


def test_tc07_only_double_tap_and_recalibration_restore_manual():
    h = Harness(ScriptedPolicy([[{"shoulder_pan": 1.0}]]))
    h.start_vla()
    h.run(0.5)
    assert h.mode is Mode.AWAIT_RECALIBRATION
    h.run(1.0)
    assert h.mode is Mode.AWAIT_RECALIBRATION

    h.double_tap()
    assert h.mode is Mode.CALIBRATING
    h.run(0.6)
    assert h.mode is Mode.MANUAL
    assert h.agent.sup.history[-2].dst is Mode.CALIBRATING
    before = h.target["shoulder_lift"]
    h.run(1.0, q=tilt(pitch_deg=30.0))
    assert h.target["shoulder_lift"] > before


def test_tc08_interrupt_drops_old_chunk_and_late_replies():
    chunk = [{"shoulder_pan": float(i)} for i in range(1, 21)]
    h = Harness(ScriptedPolicy([chunk, chunk]))
    h.start_vla()
    h.run(3 * (1 / 30))
    vla_epoch = h.epoch
    assert h.target["shoulder_pan"] == pytest.approx(3.0)

    h.double_tap()
    assert h.mode is Mode.VLA_CANCELLING
    h.run(1 / 30)
    assert h.mode is Mode.AWAIT_RECALIBRATION
    frozen = dict(h.target)

    # A reply from the GPU that was in flight for the old epoch arrives late.
    h.agent.policy_buffer.push(vla_epoch, [{"shoulder_pan": 50.0}] * 5)
    h.run(1.0)
    assert h.target == frozen
    after_tap = [r for r in h.agent.records if r.epoch > vla_epoch]
    assert after_tap and all(r.source is not Owner.VLA for r in after_tap)


def test_tc09_watch_link_loss_holds_the_arm(h: Harness):
    h.take_manual()
    h.run(0.5, q=tilt(pitch_deg=30.0))
    h.run(0.5, watch=False)  # Watch/Phone silent past the 250 ms watchdog
    assert h.mode is Mode.HOLD
    frozen = dict(h.target)
    h.run(1.0, watch=False)
    assert h.target == frozen
    assert any(e.kind is HapticKind.CONNECTION_LOST for e in h.sink.events)


def test_tc09_watch_link_loss_also_stops_vla():
    h = Harness(ScriptedPolicy([[{"shoulder_pan": float(i)} for i in range(100)]]))
    h.start_vla()
    h.run(0.2)
    h.run(0.5, watch=False)
    assert h.mode is Mode.AWAIT_RECALIBRATION
    assert any(t.reason == "watch_link_lost" for t in h.agent.sup.history)


def test_tc10_undeliverable_haptics_do_not_affect_limit_clamp(h: Harness):
    h.sink.fail = True
    h.take_manual()
    h.run(5.0, q=tilt(pitch_deg=40.0))
    assert h.target["shoulder_lift"] == pytest.approx(90.0)
    assert h.agent.haptics.delivery_failures > 0
    assert h.mode is Mode.MANUAL


@pytest.mark.parametrize("text", ["跳一支舞", "open the door", None, "   "])
def test_tc11_unsupported_or_empty_transcript_never_reaches_vla(text):
    h = Harness()
    h.take_manual()
    h.double_tap()
    h.run(0.6)
    assert h.mode is Mode.LISTENING
    h.transcript(text)
    assert h.mode is Mode.CALIBRATING  # back toward MANUAL, but only via recalibration
    h.run(0.6)
    assert h.mode is Mode.MANUAL
    assert h.policy.calls == []
    assert all(r.source is not Owner.VLA for r in h.agent.records)


def test_tc11_known_task_without_ready_policy_is_rejected():
    h = Harness(ScriptedPolicy(ready_tasks=()))
    h.take_manual()
    h.double_tap()
    h.run(0.6)
    h.transcript("把紅色積木放進盒子")
    assert h.mode is Mode.CALIBRATING
    assert h.policy.calls == []


def test_tc12_watch_leaving_foreground_disables_manual(h: Harness):
    h.take_manual()
    h.send({"type": "watch.lifecycle", "seq": 1, "state": "inactive"})
    assert h.mode is Mode.HOLD
    frozen = dict(h.robot.positions)
    h.run(1.0, q=tilt(pitch_deg=40.0))  # samples keep arriving but control is gone
    assert h.target == frozen

    h.double_tap()  # still inactive: calibration must refuse
    h.run(0.6)
    assert h.mode is Mode.HOLD
    assert h.sink.played(HapticKind.CALIBRATION_FAILED)
