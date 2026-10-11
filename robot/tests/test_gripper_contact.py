from __future__ import annotations

from so101_watch.gripper_estimator import GripperConfig, GripperEstimator
from so101_watch.protocol import HapticKind


def _run(est: GripperEstimator, frames):
    out = []
    for actual, vel, current, goal in frames:
        out += est.update(actual, vel, current, goal)
    return [e.kind for e in out]


def test_endstop_stall_with_high_current_is_not_contact():
    est = GripperEstimator(GripperConfig())
    closing = [(50.0 - 4 * i, -4.0, 50.0, 0.0) for i in range(12)]
    kinds = _run(est, closing + [(2.0, 0.0, 400.0, 0.0)] * 30)
    assert kinds == []
    assert est.active
    assert est.at_endstop


def test_hard_object_contact_then_grasp_once():
    est = GripperEstimator(GripperConfig())
    kinds = _run(est, [(30.0, 0.0, 400.0, 0.0)] * 30)
    assert kinds == [HapticKind.CONTACT_SUSPECTED, HapticKind.GRASP_LIKELY]


def test_soft_object_low_current_stays_uncertain():
    est = GripperEstimator(GripperConfig())
    kinds = _run(est, [(30.0, 0.0, 90.0, 0.0)] * 30)
    assert kinds == []


def test_evidence_must_be_sustained():
    est = GripperEstimator(GripperConfig())
    frames = [(30.0, 0.0, 400.0, 0.0), (30.0, 0.0, 50.0, 0.0)] * 15
    assert HapticKind.GRASP_LIKELY not in _run(est, frames)


def test_new_transaction_after_reopen_can_fire_again():
    est = GripperEstimator(GripperConfig())
    grasp = [(30.0, 0.0, 400.0, 0.0)] * 10
    reopen = [(30.0, 1.0, 50.0, 60.0)]
    kinds = _run(est, grasp + reopen + grasp)
    assert kinds.count(HapticKind.GRASP_LIKELY) == 2
    assert est.transaction_id == 2


def test_slip_after_grasp_reports_lost_once():
    est = GripperEstimator(GripperConfig())
    grasp = [(30.0, 0.0, 400.0, 0.0)] * 10
    slip = [(20.0, -10.0, 50.0, 0.0), (15.0, -5.0, 50.0, 0.0), (10.0, -5.0, 50.0, 0.0)]
    kinds = _run(est, grasp + slip)
    assert kinds.count(HapticKind.GRASP_LOST) == 1
