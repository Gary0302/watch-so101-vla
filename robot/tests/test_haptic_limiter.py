from __future__ import annotations

from so101_watch.haptics import HapticConfig, HapticEmitter
from so101_watch.mocks import RecordingSink
from so101_watch.protocol import HapticKind

LIMIT = (HapticKind.LIMIT_HIT, "shoulder_pan", "max")
NEAR = (HapticKind.NEAR_LIMIT, "shoulder_pan", "max")


def _emitter():
    sink = RecordingSink()
    return HapticEmitter(sink, HapticConfig(), "s"), sink


def test_level_condition_fires_once_while_held():
    em, sink = _emitter()
    for i in range(60):
        em.update_conditions({LIMIT}, i / 30, 1)
    assert len(sink.events) == 1


def test_cooldown_blocks_rapid_re_entry_then_allows():
    em, sink = _emitter()
    em.update_conditions({LIMIT}, 0.0, 1)
    em.update_conditions(set(), 0.1, 1)
    em.update_conditions({LIMIT}, 0.2, 1)  # inside 1 s cooldown
    assert len(sink.events) == 1
    em.update_conditions(set(), 1.1, 1)
    em.update_conditions({LIMIT}, 1.2, 1)
    assert len(sink.events) == 2


def test_higher_priority_wins_simultaneous_events():
    em, sink = _emitter()
    em.update_conditions({LIMIT, NEAR}, 0.0, 1)
    played = sink.played()
    assert [e.kind for e in played] == [HapticKind.LIMIT_HIT]
    assert len(sink.events) == 2  # NEAR still goes to the UI, just silently


def test_min_gap_mutes_lower_priority_but_not_higher():
    em, sink = _emitter()
    em.one_shot(HapticKind.LIMIT_HIT, 0.0, 1)
    em.one_shot(HapticKind.NEAR_LIMIT, 0.1, 1)
    em.one_shot(HapticKind.FAULT, 0.15, 1)
    assert [e.kind for e in sink.played()] == [HapticKind.LIMIT_HIT, HapticKind.FAULT]


def test_dedup_key_suppresses_repeat_one_shots():
    em, sink = _emitter()
    em.one_shot(HapticKind.GRASP_LIKELY, 0.0, 1, dedup_key=("g", 1))
    em.one_shot(HapticKind.GRASP_LIKELY, 2.0, 1, dedup_key=("g", 1))
    em.one_shot(HapticKind.GRASP_LIKELY, 4.0, 1, dedup_key=("g", 2))
    assert len(sink.events) == 2


def test_failing_sink_is_counted_not_raised():
    sink = RecordingSink(fail=True)
    em = HapticEmitter(sink, HapticConfig(), "s")
    em.one_shot(HapticKind.FAULT, 0.0, 1)
    assert em.delivery_failures == 1
