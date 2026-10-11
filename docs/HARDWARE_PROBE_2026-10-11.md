# aup hardware probe, 2026-10-11 (read-only)

Done after ruhai stopped `ruhai-smolvla-c`, with Gary's OK. Only sync_read was used: no register writes, no torque change.

## Serial (both STS3215 ×6, ids 1–6, all ping OK)

| port | Torque_Enable | Present_Load at rest | role (guess, unconfirmed) |
|---|---|---|---|
| /dev/ttyACM0 | all 0 | −23…−44 | follower? |
| /dev/ttyACM1 | all 0 | 0 | leader? |

- Loop rate: Present_Position only 1000 Hz; Position+Velocity+Load+Current 250 Hz (p95 4.1 ms). A 50–100 Hz control loop has plenty of headroom.
- `Present_Current` read 0 on every motor at rest, torque off. Contact detection still needs a measurement with torque on and the gripper squeezing something.
- Position limits (raw), ACM0: pan 747–3295, lift 1203–3424, elbow 697–2719, wrist_flex 932–3030, roll 0–4095, gripper 1750–3270.
- Position limits (raw), ACM1: pan 727–3306, lift 826–3195, elbow 957–3155, wrist_flex 848–3072, roll 0–4095, gripper 1620–2857.
- **ACM0 rests OUTSIDE its own limits** (lift 1200 < 1203, wrist_flex 3140 > 3030). Enabling torque with goal = present there makes the servo clamp the goal to the limit, so the arm jumps. robot_worker must refuse to enable torque, or clamp and ramp, when present is outside the limits.

## Cameras (640×480, 20.8 fps each, pair skew median 0.2 ms / max 47 ms)

- /dev/video0 = by-id `icspring_camera_202404160005` = **wrist** (gripper jaws in frame)
- /dev/video2 = by-id `icspring_camera` = **table** (sees the arm from the side)
- Use the /dev/v4l/by-id paths: video numbers can change after a replug.
