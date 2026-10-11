"""Supervisor transitions, with emphasis on every path back to MANUAL (SPEC §4.2 v1.2)."""

from __future__ import annotations

import pytest

from conftest import Harness, tilt
from so101_watch.protocol import ControlIntent, Intent, Mode
from so101_watch.supervisor import IllegalTransition, Supervisor


def _intent(sup: Supervisor, intent: Intent, rid: str, epoch: int | None = None) -> ControlIntent:
    return ControlIntent(rid, "s", sup.epoch if epoch is None else epoch, intent, "test")


def test_listen_timeout_goes_through_calibrating_before_manual(h: Harness):
    h.take_manual()
    h.double_tap()
    h.run(0.6)
    assert h.mode is Mode.LISTENING
    h.run(h.agent.cfg.supervisor.listen_timeout_s + 0.1)
    assert h.mode is Mode.CALIBRATING
    h.run(0.6)
    path = [t.dst for t in h.agent.sup.history]
    i = len(path) - 1 - path[::-1].index(Mode.LISTENING)
    assert path[i + 1] is Mode.CALIBRATING
    assert path[i + 2] is Mode.MANUAL


def test_listen_timeout_with_moving_wrist_ends_in_hold(h: Harness):
    h.take_manual()
    h.double_tap()
    h.run(0.6)
    h.run(h.agent.cfg.supervisor.listen_timeout_s + 0.1, gyro=(0.0, 0.8, 0.0))
    h.run(h.agent.cfg.supervisor.calibration_timeout_s + 0.1, gyro=(0.0, 0.8, 0.0))
    assert h.mode is Mode.HOLD


def test_validate_timeout_goes_through_calibrating():
    sup = Supervisor()
    sup.on_ready(0)
    sup.handle_intent(_intent(sup, Intent.DOUBLE_TAP, "a"), 0)
    sup.on_calibration_result(True, "still", 0)
    sup.handle_intent(_intent(sup, Intent.DOUBLE_TAP, "b"), 0)
    sup.on_calibration_result(True, "still", 0)
    sup.on_transcript(1)
    assert sup.mode is Mode.TASK_VALIDATING
    sup.check_timeouts(1 + sup.cfg.validate_timeout_s + 0.01)
    assert sup.mode is Mode.CALIBRATING and sup.calibration_next is Mode.MANUAL


@pytest.mark.parametrize("src", [m for m in Mode if m is not Mode.CALIBRATING])
def test_manual_is_unreachable_except_from_calibrating(src: Mode):
    sup = Supervisor()
    sup.mode = src
    with pytest.raises(IllegalTransition):
        sup._go(Mode.MANUAL, "sneaky", 0)


def test_calibrating_toward_listening_cannot_land_in_manual():
    sup = Supervisor()
    sup.mode, sup.calibration_next = Mode.CALIBRATING, Mode.LISTENING
    with pytest.raises(IllegalTransition):
        sup._go(Mode.MANUAL, "sneaky", 0)


@pytest.mark.parametrize("dst", [Mode.HOLD, Mode.MANUAL, Mode.LISTENING, Mode.CALIBRATING])
def test_vla_running_cannot_exit_except_to_await_cancel_fault(dst: Mode):
    sup = Supervisor()
    sup.mode = Mode.VLA_RUNNING
    with pytest.raises(IllegalTransition):
        sup._go(dst, "x", 0, calibration_next=Mode.MANUAL)


def test_every_transition_bumps_epoch(h: Harness):
    h.take_manual()
    epochs = [t.epoch for t in h.agent.sup.history]
    assert epochs == list(range(1, len(epochs) + 1))


def test_stale_double_tap_is_rejected_but_stale_stop_is_honoured(h: Harness):
    h.take_manual()
    old = h.epoch - 1
    ack = h.double_tap(epoch=old)
    assert ack["result"] == "rejected" and ack["reason"] == "STALE_EPOCH"
    assert h.mode is Mode.MANUAL
    ack = h.intent("STOP", epoch=old)
    assert ack["result"] == "accepted"
    assert h.mode is Mode.HOLD


def test_late_interrupt_tap_does_not_start_calibration():
    """'Interrupt VLA' sent just before the VLA finished must not become 'take over'."""
    from so101_watch.mocks import ScriptedPolicy

    h = Harness(ScriptedPolicy([[{"shoulder_pan": 1.0}]]))
    h.start_vla()
    tapped_at = h.epoch
    h.run(0.3)
    assert h.mode is Mode.AWAIT_RECALIBRATION
    ack = h.double_tap(epoch=tapped_at)
    assert ack["result"] == "rejected"
    assert h.mode is Mode.AWAIT_RECALIBRATION


def test_duplicate_request_id_is_not_executed_twice(h: Harness):
    first = h.double_tap(request_id="c-dup")
    assert first["result"] == "accepted" and h.mode is Mode.CALIBRATING
    h.run(0.6)
    assert h.mode is Mode.MANUAL
    again = h.double_tap(request_id="c-dup")
    assert again["result"] == "duplicate"
    assert h.mode is Mode.MANUAL


def test_estop_latch_only_cleared_locally(h: Harness):
    h.take_manual()
    h.agent.physical_estop(h.now)
    assert h.mode is Mode.ESTOP_LATCHED
    writes = len(h.robot.writes)
    h.run(1.0, q=tilt(pitch_deg=40.0))
    assert len(h.robot.writes) == writes  # no motor writes while latched
    assert h.intent("RESET_FAULT")["result"] == "ignored"
    assert h.double_tap()["result"] == "ignored"
    assert not h.agent.sup.on_estop_released("voice", h.now)
    assert h.mode is Mode.ESTOP_LATCHED
    assert h.agent.sup.on_estop_released("local_operator", h.now)
    assert h.mode is Mode.DISCONNECTED


def test_joint_read_error_faults_and_reset_needs_health(h: Harness):
    h.take_manual()
    h.robot.read_ok = False
    h.run(0.1)
    assert h.mode is Mode.FAULT
    assert h.intent("RESET_FAULT")["reason"] == "FAULT_CONDITION_PERSISTS"
    h.robot.read_ok = True
    h.run(0.1)
    assert h.intent("RESET_FAULT")["result"] == "accepted"
    assert h.mode is Mode.HOLD


def test_voice_stop_phrase_holds(h: Harness):
    h.take_manual()
    h.double_tap()
    h.run(0.6)
    h.transcript("停止")
    assert h.mode is Mode.HOLD


def test_camera_loss_ends_vla_in_await():
    from so101_watch.mocks import ScriptedPolicy

    h = Harness(ScriptedPolicy([[{"shoulder_pan": float(i)} for i in range(100)]]))
    h.start_vla()
    h.run(0.2)
    h.robot.cameras["wrist"] = False
    h.run(0.1)
    assert h.mode is Mode.AWAIT_RECALIBRATION
