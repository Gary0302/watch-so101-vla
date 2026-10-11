# watch-so101-vla

Apple Watch × SO-101 × VLA。規格見 [docs/SPEC.md](docs/SPEC.md)（v1.2）。

## 目前進度

- `robot/`：Local Robot Agent。內容有 protocol、Supervisor FSM、Safety Gate、Haptic policy、gripper 接觸推估、TaskRouter 和 policy buffer，以及 `MockRobot`。
  - `robot_worker.py`：真正的 SO-101，直接用 LeRobot `FeetechMotorsBus`。它不寫 calibration 或設定暫存器；開 torque 前先設 goal = present；斷線時一律用 `disable_torque=False`；bus 出錯會 latch 成 FAULT，要重啟 agent 才能恢復。用假 bus 測過，也對真 lerobot 0.6.1 的 API 驗證過，**還沒在手臂上跑過**。
  - `config.py` + `config/so101.example.toml`：TOML 設定，打錯的 key 會直接報錯。範例裡的數值都是佔位，必須換成實測值。
  - gateway：`--mock` 或 `--config so101.toml`（真手臂）。真手臂模式目前用 `NoPolicy`，VLA 一律拒絕；因為還沒有 camera_worker，相機也會回報缺失。
- `apps/shared`（Swift Package）：
  - `SO101Protocol`：與 Python 共用的訊息定義，用 fixture 做格式對照測試。
  - `SO101Voice`：語音流程。Watch 收到 `LISTENING` 狀態後用 `AVAudioRecorder` 錄 5 秒 AAC，音檔分塊經 WCSession 傳給 iPhone 重組，iPhone 用 `SFSpeechRecognizer`（zh-TW，可在裝置上辨識）轉成文字，再送出 `voice.transcript`。文字代表什麼任務，由 agent 的 TaskRouter 判斷。
  - 測試：`cd apps/shared && swift test`。用 `xcodebuild -scheme SO101Protocol-Package -destination generic/platform=watchOS` 可以對真的 iOS / watchOS SDK 編譯。
  - `SO101Link`：iPhone 中繼。WCSession 封包格式、`AgentConnection`（WebSocket＋Bearer token，可選擇 pin 自簽憑證的 SHA-256）、intent 重送、Watch 重新連上時補送最新狀態。
  - `SO101WatchKit`：Watch 端邏輯（`WatchController`），以及 haptic 排程和 Core Motion / WCSession 轉接層。
- `apps/project.yml`（XcodeGen）：產生 `SO101Relay`（iPhone）、`SO101Watch`（watchOS，嵌在 iPhone App 裡）和 `SO101WatchUITests`。
  - 產生專案：`cd apps && xcodegen generate`（`.xcodeproj` 不進 git）。
  - 要裝到實機，必須在 Mac mini 上用新版 Xcode，並填入 `DEVELOPMENT_TEAM`（見 SPEC §14）。

## 測試

```sh
cd robot && uv run pytest
```

Swift：`cd apps/shared && swift test`。加上 `SO101_E2E=1` 會啟動真的 mock gateway，跑 WebSocket 和 pinned-TLS 測試。

### 模擬器端到端（Watch → iPhone → gateway）

```sh
# 1. mock gateway
cd robot && SO101_GATEWAY_TOKEN=sim-token-0123456789 uv run python -m so101_watch.gateway --mock --allow-insecure --host 127.0.0.1 --port 18770
# 2. 建立一組配對的模擬器（iOS 18.3 iPhone + watchOS 11.2 Watch），裝上 App，然後啟動 iPhone App：
SIMCTL_CHILD_SO101_SKIP_PERMISSION_PROMPTS=1 SIMCTL_CHILD_SO101_AGENT_URL=ws://127.0.0.1:18770 \
  SIMCTL_CHILD_SO101_TOKEN=sim-token-0123456789 xcrun simctl launch <iphone> com.garyyang.so101.relay
# 3. Watch UI test：按主按鈕 → CALIBRATING → 按 STOP → HOLD
cd apps && xcodebuild -project SO101.xcodeproj -scheme SO101Watch -destination id=<watch> test
```

只有 DEBUG build 會讀 `SO101_*` 環境變數，Release build 會忽略。模擬器沒有 device motion，所以校準一定會逾時失敗。

TC01–TC12 在 `robot/tests/test_acceptance.py`；FSM 與隨機事件不變量測試在 `test_fsm.py`、`test_owner_epoch.py`。

## 實機測試（Mac mini + iPhone + Series 11）

- Mac mini：macOS 27.0.1、Xcode 27.1 RC、Team `98527N34D6`（寫在 `project.yml`）。Repo 在 `~/code/VLA/main/watch-so101-vla`。
- **安裝**：在 Mac mini 的 Xcode 選 `SO101Relay` → iPhone，按 ⌘R。手錶 App 透過 iPhone 的 Watch App 安裝或更新（「可安裝的 App」）。ResWiFi 會隔離裝置、擋掉 Bonjour，所以 Xcode 沒辦法直接連手錶。
- **透過 SSH 簽章會失敗**（`errSecInternalComponent`），因為 SSH session 裡登入鑰匙圈是鎖住的。可以在 GUI 按 ⌘R，或改建一個專用的建置鑰匙圈。
- **測試用 gateway**：在 Mac mini 上跑 `wss://100.64.8.15:8765`（mock，不碰硬體）。token、憑證和 log 都在 `~/so101-mock/`。
- **除錯畫面**：手錶往下轉數位錶冠，iPhone 在最下方的「Debug」。`TX` 是送出，`RX` 是收到，失敗或被丟掉的顯示成橘色。gateway 的 log 會記錄每一筆收到的指令和送出的回覆，手腕資料則整理成每秒幾筆。
- **震動**：每次點按或 Double Tap 一定會震。`click` 代表有送出，`retry`（連震兩下）代表被忽略，原因寫在除錯畫面。按鈕永遠不會被停用，因為停用的按鈕會讓系統直接吞掉 Double Tap。

### 實測後跟 SPEC 不同的地方（要回寫 SPEC）

| 項目 | SPEC | 現在 | 原因 |
|---|---|---|---|
| 手腕資料逾時 | 250 ms 就回 HOLD | 250 ms 先原地停住，1.5 s 才離開 MANUAL 或停 VLA | 實機上 WCSession 偶爾會卡 300 到 600 ms，每卡一次就要重新校準，沒辦法用 |
| LISTENING 逾時 | 8 s | 15 s | 錄音 5 s，加上傳到 iPhone 和語音轉文字，實測要 8.2 s |
| 手錶 inactive | scenePhase 不是 active 就算 | workout 在跑時都不算；沒有 workout 時，進入背景才算 | 手腕放下時 App 會變 inactive，甚至進入背景，但 workout 讓它照樣在跑、繼續送資料。資料一斷，agent 照樣會停住並回 HOLD |
| 背景執行 | 沒有規定 | `HKWorkoutSession`（不存任何資料） | extended runtime session 不會讓 App 維持 reachable（Apple 論壇 thread 723158） |

## 尚未可上實機

- `PlaceholderJointMapper` 是 IK 的佔位，要換成 LeRobot 的 `EEReferenceAndDelta` + `InverseKinematicsEEToJoints`。
- `SafetyConfig.soft_limits` 與 `GripperConfig` 的門檻都是 Mock 用的假值。
- 還沒有 `camera_worker` 和 `recorder`，也還沒接朋友的 VLA（`vla_client`，要等 /home/ruhai 有讀取權限）。
- Gripper 電流門檻（`Present_Current` raw 單位）要用 `tools/feetech_telemetry_probe.py` 實測。
- control loop 在 asyncio 裡同步讀 serial，每個 tick 會卡住網路幾毫秒，要等 probe 量完 Hz 再決定是否改成獨立 thread。

## 在 aup 上跑（等手臂和相機確定沒人用時）

```sh
tools/make_cert.sh ~/gary/certs 169.233.72.12   # 印出 pin，貼到 iPhone App
tools/aup_agent.sh /dev/ttyACM0                 # 先在 host 檢查 port 有沒有人用，再起 gary-agent-* container
```
