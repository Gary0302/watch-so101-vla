# watch-so101-vla

Apple Watch × SO-101 × VLA。規格見 [docs/SPEC.md](docs/SPEC.md)（v1.2）。

## 目前進度

- `robot/`：Local Robot Agent 骨架，不需要硬體。內容有 protocol、Supervisor FSM、Safety Gate、Haptic policy、gripper 接觸推估、TaskRouter 和 policy buffer，以及 `MockRobot`。
- `apps/shared`（Swift Package）：
  - `SO101Protocol`：與 Python 共用的訊息定義，用 fixture 做格式對照測試。
  - `SO101Voice`：語音流程。Watch 收到 `LISTENING` 狀態後用 `AVAudioRecorder` 錄 5 秒 AAC，音檔分塊經 WCSession 傳給 iPhone 重組，iPhone 用 `SFSpeechRecognizer`（zh-TW，可在裝置上辨識）轉成文字，再送出 `voice.transcript`。文字代表什麼任務，由 agent 的 TaskRouter 判斷。
  - 測試：`cd apps/shared && swift test`。用 `xcodebuild -scheme SO101Protocol-Package -destination generic/platform=watchOS` 可以對真的 iOS / watchOS SDK 編譯。
- Watch 和 iPhone 的 App target 還沒建立。要裝到實機，必須在 Mac mini 上用新版 Xcode（見 SPEC §14）。

## 測試

```sh
cd robot && uv run pytest
```

TC01–TC12 在 `robot/tests/test_acceptance.py`；FSM 與隨機事件不變量測試在 `test_fsm.py`、`test_owner_epoch.py`。

## 尚未可上實機

- `PlaceholderJointMapper` 是 IK 的佔位，要換成 LeRobot 的 `EEReferenceAndDelta` + `InverseKinematicsEEToJoints`。
- `SafetyConfig.soft_limits` 與 `GripperConfig` 的門檻都是 Mock 用的假值。
- 還沒有 gateway（WSS）、`robot_worker`（真 SO-101）、`camera_worker`、`recorder`，也還沒接 async policy client。
