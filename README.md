# watch-so101-vla

Apple Watch × SO-101 × VLA。規格見 [docs/SPEC.md](docs/SPEC.md)（v1.2）。

## 目前進度

- `robot/`：Local Robot Agent 骨架，不需要硬體。內容有 protocol、Supervisor FSM、Safety Gate、Haptic policy、gripper 接觸推估、TaskRouter 和 policy buffer，以及 `MockRobot`。
- `apps/`：尚未開始。開發 Mac 需先升級 Xcode，見 SPEC §14。

## 測試

```sh
cd robot && uv run pytest
```

TC01–TC12 在 `robot/tests/test_acceptance.py`；FSM 與隨機事件不變量測試在 `test_fsm.py`、`test_owner_epoch.py`。

## 尚未可上實機

- `PlaceholderJointMapper` 是 IK 的佔位，要換成 LeRobot 的 `EEReferenceAndDelta` + `InverseKinematicsEEToJoints`。
- `SafetyConfig.soft_limits` 與 `GripperConfig` 的門檻都是 Mock 用的假值。
- 還沒有 gateway（WSS）、`robot_worker`（真 SO-101）、`camera_worker`、`recorder`，也還沒接 async policy client。
