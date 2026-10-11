from pathlib import Path

import pytest

from so101_watch.config import ConfigError, load_config

EXAMPLE = Path(__file__).resolve().parents[1] / "config" / "so101.example.toml"


def test_example_config_loads():
    agent, robot = load_config(EXAMPLE)
    assert robot.port == "/dev/ttyACM0" and robot.expect_torque_off_at_start
    assert agent.safety.soft_limits["gripper"] == (5.0, 95.0)
    assert agent.safety.max_step_per_tick == 2.0
    assert agent.motion.vmax_deg_s == 20.0


@pytest.mark.parametrize("text,msg", [
    ("contrl_hz = 30", "unknown key contrl_hz"),
    ("[safety.soft_limits]\nelbow = [0, 1]", "unknown joint"),
    ("[safety.soft_limits]\ngripper = [50, 10]", "below upper"),
    ("[robot]\nexpect_torque_off_at_start = 1", "true/false"),
    ("[safety]\nmax_step_per_tick = 'fast'", "expected float"),
])
def test_bad_config_is_rejected(tmp_path, text, msg):
    p = tmp_path / "c.toml"
    p.write_text(text)
    with pytest.raises(ConfigError, match=msg):
        load_config(p)
