# Apple Watch × SO-101 × VLA
## Detailed Engineering Specification — v1.2

**狀態**：Implementation-ready draft（尚未實機驗證）  
**日期**：2026-10-10  
**語言**：繁體中文（API 與變數使用英文）  
**架構**：Apple Watch Series 11 → iPhone 13 Pro → Local Robot Agent → SO-101；VLA 可在獨立推論 Server  
**主要特點**：手腕遙控、Double Tap 姿態校正／語音入口、VLA 控制權交接、雙攝影機、Watch 限位與夾爪事件震動回饋、LeRobot 資料收集

> **文件規則**：本文區分 `CONFIRMED`（官方文件或原始碼已證實）、`DESIGN`（本專案預定實作）與 `VERIFY`（需使用實機與鎖定版本確認）。所有數值（延遲、取樣頻率、門檻、速度）是初始工程參數，不是硬體保證、測試結果或安全認證。

---

## 0. Executive summary

核心原則：**只允許 Local Robot Agent 對 SO-101 下達真正的馬達命令**。Watch、人類語音、VLA 都是控制請求的來源；所有請求必須通過同一個 Control Supervisor、Safety Gate 和命令佇列。人工與 VLA 不能同時擁有控制權。

**固定的使用者互動規格**：

1. 使用者在 `MANUAL` 中以 Watch 姿態控制手臂。
2. Double Tap → Robot `HOLD` → 擷取手腕新中立姿態 → 進入限時語音聆聽。
3. 語音命令描述任務，例如「把紅色積木放進盒子」。文字命令由任務路由處理，符合已訓練且允許的任務才啟動 VLA。
4. `VLA_RUNNING` 期間人類 Watch 姿態**完全不能發出動作命令**；Double Tap 可請求中斷 VLA。
5. VLA 成功、失敗、中斷或逾時後都進入 **`AWAIT_RECALIBRATION`** 並維持安全 HOLD，**不能自動交還 Watch**。
6. 使用者再次 Double Tap，重新校正、確認中立區與安全狀態，才重新取得 `MANUAL` 權限；**此次 Double Tap 不開啟語音**。
7. 觸及關節或工作空間限位、疑似夾爪接觸、任務完成或異常時，Watch 以不同系統 Haptic 類型提示。回饋傳遞不是安全關鍵控制通路。

### 非目標（v1）

- 不能把 IMU 加速度雙重積分當作可靠絕對手部 3D 定位。
- 不做未公開 Apple Double Tap 原始手勢事件或持續背景全域監聽。
- 不宣稱 STS3215 的 `Present_Load` / `Present_Current` 是已校準的夾取力（N）。
- 不允許 LLM/VLA 直接繞過 Supervisor 操作馬達。
- 不假設沒有微調的 SmolVLA 能在任意新場景可靠 Pick-and-Place。
- 不用 `robot.disconnect()` 當作「保持姿態」的操作；失去扭矩可能讓手臂下垂。

---

## 1. 現有設備與待確認事項

| Item | 已知狀態 | 需要確認 |
|---|---|---|
| Watch | Apple Watch Series 11 | watchOS 版本、Double Tap 系統設定、App 前景狀態 |
| Phone | iPhone 13 Pro，使用者報告 iOS 27.2 | Xcode SDK/實機版本配對、App 前景延遲 |
| Robot | SO-101 follower（5 手臂關節 + 夾爪） | 校正、USB 連接埠、固定方式、供電 |
| Cameras | Front + wrist/gripper 共兩台 | USB 路徑、解析度/FPS、安裝位置與視角 |
| Server | 使用者有 Server | 是否為本機連著 SO-101、OS/GPU/網路、模型可用記憶體 |
| Developer | Paid Apple Developer Account | Xcode signing / microphone privacy 權限 |
| Safety | 未知 | 工作空間、實體斷電／急停、負載、周遭人員 |

**AMD UCSC Workshop PDF**：第 23–24 頁將 VLA 定義為影像 + 機器人狀態 + 語言任務產生 Action；第 26–31 頁討論 SO-101、校正、USB port 與電源；第 32 頁容許先 Teleoperation 作為 Hackathon 備案。這份簡報不是 Apple Watch API 或夾爪力覺感測器的證據。

---

## 2. 避免重新造輪子：Dependency / Reuse matrix

| 功能 | 現成工具 / 原始碼 | 類型 | 工作 |
|---|---|---|---|
| IMU | Apple `CoreMotion`, `CMMotionManager`, `CMDeviceMotion`, `CMAttitude` | CONFIRMED | 用標準 API 讀取 quaternion/gravity/gyro；實測頻率 |
| 原生 Double Tap | SwiftUI `.handGestureShortcut(.primaryAction)` | CONFIRMED | 可見 Button 主操作；定義狀態專屬意義 |
| Watch Haptics | `WKInterfaceDevice.current().play(_:)`, `WKHapticType` | CONFIRMED | 限位、接觸、接管、故障事件 |
| Watch ↔ iPhone | `WCSession.sendMessageData` / `sendMessage` | CONFIRMED | 即時可達時控制封包與 Haptic Event；不可達即降級 |
| Watch Audio | watchOS Audio Recording APIs / `AVAudioEngine` 可行性 | VERIFY | PoC 證明能直接從指定手勢啟動錄音 |
| Speech | iOS `Speech` / `SpeechAnalyzer` 相容性 | VERIFY | 首選 iPhone 轉錄；雲端 STT 可替代 |
| iPhone ↔ Local Agent | `URLSessionWebSocketTask` | CONFIRMED | 即時雙向可靠傳輸與 ACK |
| SO-101 Motor | LeRobot `SO101Follower` | CONFIRMED | `.connect()`, `.get_observation()`, `.send_action()` |
| Camera | LeRobot OpenCV camera integration | CONFIRMED | `front`, `wrist`；記錄時間戳 |
| Teleop API | `lerobot.teleoperators.Teleoperator`、plugin naming | CONFIRMED | 自訂 Apple Watch Adapter，不修改核心 |
| 手動姿態映射與 IK | LeRobot Phone Teleop processors | CONFIRMED | 借用 `EEReferenceAndDelta`, `EEBoundsAndSafety`, `InverseKinematicsEEToJoints`, `GripperVelocityToJoint` |
| 重新設定來源姿態 | LeRobot Isaac Teleop Clutch/rebase | CONFIRMED | 參考其中「重新接管不瞬移」的設計 |
| VLA | LeRobot SmolVLA | CONFIRMED | 從可訓練 checkpoint 起步，兩台攝影機輸入 |
| VLA 遠端運算 | LeRobot Async Policy Server / Robot Client | CONFIRMED | 重用推論，增加 Epoch/Queue invalidation 閘門 |
| Dataset & Training | LeRobot dataset, `lerobot-record`, `lerobot-train` | CONFIRMED | 錄製雙視角 + joints + actions + task + 操控者 |
| 人類介入學習 | LeRobot HIL data collection / HIL-SERL docs | CONFIRMED | 借用介入事件 metadata，需配合 Watch Clutch 改造 |
| Gripper telemetry | LeRobot Feetech motor control table | CONFIRMED | 有 `Present_Position`, `Present_Load`, `Present_Current` registers；效力需實測 |
| Control Supervisor | 專案自訂 | DESIGN | Control owner / safety arbitration / HOLD / epoch |
| Haptic Event Classifier | 專案自訂 | DESIGN | 限位檢測、接觸信心、去抖與節流 |

**相容性策略**：優先使用已發布版本（查詢時最新為 LeRobot v0.6.1）；把固定 commit hash 記入 lockfile。`main` 文件常含尚未發布的功能，因此每個接口需在**所選版本**跑 contract test。若 v0.6.1 缺少特定 Processor/Telemetry 整合才評估固定 Git commit，不要混用 main 文件與 stable API。

### 主要來源

- Apple Double Tap: https://developer.apple.com/documentation/watchos-apps/enabling-double-tap
- Core Motion: https://developer.apple.com/documentation/coremotion/cmmotionmanager
- Apple haptics: https://developer.apple.com/documentation/watchkit/wkinterfacedevice/play(_:)
- WatchConnectivity: https://developer.apple.com/documentation/watchconnectivity/wcsession
- watchOS network restrictions: https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos
- watchOS background limits: https://developer.apple.com/documentation/watchkit/background-execution
- LeRobot releases: https://github.com/huggingface/lerobot/releases
- LeRobot plugin documentation: https://huggingface.co/docs/lerobot/main/third_party_robots
- LeRobot Teleoperator API: https://huggingface.co/docs/lerobot/main/en/api/teleoperators
- Phone Teleop: https://huggingface.co/docs/lerobot/main/en/phone_teleop
- Isaac Teleop Clutch: https://huggingface.co/docs/lerobot/main/isaac_teleop
- SmolVLA: https://huggingface.co/docs/lerobot/main/smolvla
- Async inference: https://huggingface.co/docs/lerobot/async
- HIL: https://github.com/huggingface/lerobot/blob/main/docs/source/hil_data_collection.mdx
- Feetech registers: https://github.com/huggingface/lerobot/blob/main/src/lerobot/motors/feetech/tables.py
- SO-101 driver: https://github.com/huggingface/lerobot/blob/main/src/lerobot/robots/so_follower/so_follower.py

---

## 3. System architecture / Deployment

```text
  ┌─────────────────────────────┐
  │ Apple Watch Series 11       │
  │ CMMotionManager  |  UI      │
  │ Double Tap       |  Mic     │
  │ Haptic Renderer  |  Status  │
  └──────────────┬──────────────┘
                 │ WCSession (foreground/reachable)
  ┌──────────────▼──────────────┐
  │ iPhone 13 Pro               │
  │ Session/Relay + STT         │
  │ Event/ACK + Reconnect       │
  └──────────────┬──────────────┘
                 │ WSS (TLS + auth), timestamps + seq
  ┌──────────────▼──────────────────────────────┐
  │ Local Robot Agent (USB-attached)           │
  │   API Gateway                              │
  │     ├── Control Supervisor/Owner Epoch     │
  │     ├── Teleop Adapter + Motion Mapping    │
  │     ├── Safety Gate + IK                   │
  │     ├── Grip/Limit Event Detector          │
  │     ├── Camera capture: front + wrist      │
  │     └── Single Motor Writer               │
  └────────────┬──────────────────┬─────────────┘
               │                  │
   USB/Serial  │                  │ gRPC/LeRobot Async policy protocol
     ┌─────────▼────────┐  ┌──────▼──────────────┐
     │ SO-101 Follower  │  │ Policy Server (GPU)│
     │ 6 motor axes     │  │ SmolVLA checkpoint  │
     └──────────────────┘  └─────────────────────┘
```

**嚴格責任界線**：VLA Server 只能回傳 *建議* Action，Local Agent 才有權驗證並執行。若 LeRobot 原始 `RobotClient` 直接寫馬達，必須以 wrapper/adapter 封裝它的 action sink，確保單一 Writer；不能同時執行獨立的 LeRobot teleop/rollout CLI 與我們的 Robot Agent 寫同一條 bus。

**網路**：Watch 不依賴直接 WebSocket；watchOS 對 WebSocket/TCP/UDP 有特定用途限制。iPhone App 的 WSS 應保持前景運行作為 v1 要求。若任一鏈路不可達，Local Agent 自行 HOLD；失聯時不得靠 Watch Haptic 才能保證安全。

---

## 4. Control modes / State machine

狀態列舉：

```text
DISCONNECTED
HOLD
MANUAL
CALIBRATING
LISTENING
TASK_VALIDATING
VLA_RUNNING
VLA_CANCELLING
AWAIT_RECALIBRATION
FAULT
ESTOP_LATCHED
```

### 4.1 關鍵不變量（Machine-checkable invariants）

1. `owner ∈ {NONE, MANUAL, VLA}`；任一時刻只有一個 owner。
2. `mode != MANUAL` 時任何 Watch Motion Command 都被丟棄或回 `NOT_OWNER`。
3. `mode != VLA_RUNNING` 時所有 VLA action 均禁止送至 Motor Writer。
4. 每次 owner 改變或進入 HOLD/FAULT：`control_epoch += 1`。epoch 舊的封包與 chunk 永不執行。
5. 任務終止（success, fail, timeout, cancelled）**一律**轉入 `AWAIT_RECALIBRATION`，不自行恢復 Manual。
6. Manual 啟用時須存在新鮮、已確認的姿態參考 `q0`、Watch/Phone reachability、關節／工作空間驗證，以及人手回到 neutral dead-zone。
7. Speech / VLA 不可直接解除 `ESTOP_LATCHED`。實體急停復原需明確人工現場操作。
8. 安全覆蓋優先級 `ESTOP > FAULT > HOLD > VLA/MANUAL`。
9. **（v1.2）`MANUAL` 唯一入口**：只能由「校正成功且目標為 MANUAL 的 `CALIBRATING`」進入。聆聽逾時、任務被拒、驗證逾時、VLA 結束、Fault 重置都不能直接回 `MANUAL`。程式中違反即丟 `IllegalTransition`。
10. **（v1.2）過期 intent 拒收**：`STOP` 以外的 Control Intent，其 `control_epoch` 必須等於目前 epoch，否則回 `STALE_EPOCH`。例：VLA 剛結束時才抵達的「Interrupt VLA」不能被解讀成「Recalibrate to Take Over」。`STOP` 只會往 HOLD 方向，故不檢查 epoch。

### 4.2 State transition table

| Current | Event | Next | Robot behavior |
|---|---|---|---|
| DISCONNECTED | 通訊、Motor ready、檢查通過 | HOLD | 保持控制器持有的安全目標 |
| HOLD / AWAIT_RECALIBRATION | Double Tap | CALIBRATING | 不開語音；量測新的 Watch q0 |
| CALIBRATING(target=MANUAL) | 校正通過且 neutral stable | MANUAL | owner=MANUAL，初始速度=0 |
| CALIBRATING(target=LISTENING) | 校正通過 | LISTENING | Robot 繼續 HOLD，開啟錄音視窗 |
| CALIBRATING | 手腕不穩 / 姿勢不對 / 逾時 / Watch 非前景 | HOLD | `CALIBRATION_FAILED`，需再次 Double Tap |
| MANUAL | Double Tap | CALIBRATING(target=LISTENING) | 立即 HOLD，重新定義 q0，之後聆聽語音 |
| MANUAL | Motion stale / Watch inactive | HOLD | 停止人工控制，需 Double Tap 重新校正 |
| LISTENING | 錄音完成有任務 | TASK_VALIDATING | Robot 繼續 HOLD |
| LISTENING | Timeout / Cancel / 無任務 | **CALIBRATING(target=MANUAL)**（v1.2） | Robot 繼續 HOLD；須重新取得靜止 q0 才回人工 |
| TASK_VALIDATING | 未知/無效任務、policy 未就緒、驗證逾時 | **CALIBRATING(target=MANUAL)**（v1.2） | 不執行任何猜測動作 |
| TASK_VALIDATING | Stop / Hold 語音 | HOLD | 需 Double Tap 重新校正 |
| TASK_VALIDATING | 已允許 task + model ready + 雙攝影機正常 | VLA_RUNNING | owner=VLA，啟用唯一馬達出口 |
| VLA_RUNNING | Watch link 中斷（無人能 Double Tap 中斷） | VLA_CANCELLING | 同 Double Tap 中斷 |
| VLA_RUNNING | 任一攝影機失效 | AWAIT_RECALIBRATION | 停止 VLA |
| VLA_CANCELLING | Hold 未在時限內確認 | FAULT | 安全 HOLD |
| FAULT | `RESET_FAULT` 且 feedback 健康 | HOLD | 仍需 Double Tap 才回人工 |
| VLA_RUNNING | Double Tap / Stop request | VLA_CANCELLING | 本機立刻遮斷新的 Action，失效舊 epoch |
| VLA_CANCELLING | Motor hold confirmed | AWAIT_RECALIBRATION | VLA 不再控制，等待 Double Tap |
| VLA_RUNNING | Success / failure / policy timeout | AWAIT_RECALIBRATION | 同上；**不得自動 Manual** |
| Any | Controller disconnected / invalid feedback | FAULT | 安全 HOLD 或硬體安全策略 |
| Any | Physical ESTOP | ESTOP_LATCHED | 立即硬體層停止；不得靠 App 清除 |

**Double Tap 不能作為唯一 E-Stop**：只有 Watch App 可見且前景可互動時才可觸發指定 Primary Action；真正的急停需獨立硬體途徑。

### 4.3 交接保護

- VLA 中斷不等待 GPU 推論完成才停止：Local Agent **先失效 owner epoch**，再緩停。
- 丟棄舊 epoch 的 Action Chunk、排隊 motor target、舊 IMU packet。
- 若末端夾著物體，HOLD 對夾爪應保留安全夾持目標，不可自動鬆開，也不可盲目加壓。
- 原先 Watch 的姿態零點不可延續至 VLA 結束後的人工重新接管；必須由 Double Tap 再次校正。
- 校正時不要自動移動 Robot Home Pose；本專案預設 **重設 Watch 對應原點，Robot 原地 HOLD**。Home Pose 作為獨立明確語音／UI 指令，需路徑安全驗證。

---

## 5. Apple Watch interaction and UX

### 5.1 基本 UI

單一 Screen 包含：中央 Primary Action Button（可視、套用 `.handGestureShortcut(.primaryAction)`）、模式文字、連線狀態、Motor arm/disarm 顯示、Control Magnitude、Gripper status、最近一次 haptic event、明顯的 STOP/HOLD 觸控鍵。

**主按鈕依模式改變文字但保持同一個 Primary Action**：`Calibrate & Talk` / `Finish Voice` / `Interrupt VLA` / `Recalibrate to Take Over`；每次按下只送出操作請求，待 Server ACK 才確認狀態。

### 5.2 姿態校正

- 使用者手掌向下、前臂接近水平；**Apple Watch 不能感知指尖是否伸直或掌心朝向**，只能估計裝置自身姿態。
- 取連續 `CMDeviceMotion` 樣本，檢查 gravity 對應 Watch 正常姿態範圍，gyro 低於閾值持續一段時間（初始約 300–500ms）。
- 平均姿態必須採用 quaternion 穩定平均或近似球面插值，避免 Euler wrap。
- 設 `q0 = q_watch(t_calibrate)`；首個控制輸入設零。
- Watch 對腕上方向可左右手不同；增加可選左／右手與 axis sign 的設定頁。
- 失敗需留在 HOLD，Watch 顯示 `Hold wrist steady / Retry`，可透過再次 Double Tap 重新嘗試。

### 5.3 Voice 行為

- 在 `MANUAL` Double Tap 後，Server 立即 HOLD；校正成功後開啟 5 秒錄音視窗（可配置）。
- 用 Watch Audio API 錄製有限時長音訊；首版優先採短語音 clip，而非 20Hz audio streaming。
- 若 watchOS 系統 recorder UI 會覆蓋 Primary Action、權限或音訊路由受到限制，v1 可採 Apple 原生 Dictation / iPhone STT fallback。**需實機 Spike 驗證能否做到「Double Tap → 直接開始錄音」**。
- `WCSession.sendMessageData` 用於小型即時 control/message；檔案長音訊使用 `transferFile` 可能排隊、無低延遲保證，不可用於急停或即時控制。根據實測語音大小，選短 clip 分塊 + ACK 或讓 iPhone 錄音（需要清楚顯示採用何設備麥克風）。
- 語音轉文字後先經 deterministic `TaskRouter`：`Stop`, `Hold`, `Home`, `Open gripper`, `Close gripper`, `Pick-and-place`。未知或高風險任務要求使用者明確確認，不允許自由產生馬達命令。

---

## 6. Watch IMU → Teleoperation mapping

### 6.1 Motion inputs

`CMDeviceMotion.attitude.quaternion`, `gravity`, `rotationRate`, `userAcceleration`, `timestamp`。先取樣約 50 Hz（實際依設備測得），向 iPhone 降採樣約 20 Hz（依延遲和耗電調整）。真實取樣間隔必須依 `CMDeviceMotion.timestamp` 計算，不能以設定 interval 當成實際頻率。

### 6.2 相對姿態與安全速度映射

```text
q_rel(t) = inverse(q0) ⊗ q_watch(t)
rotvec = log_SO3(q_rel)
v_cmd  = clamp(K * deadzone(rotvec), -vmax, +vmax)
```

**設計決定**：第一版採 **手腕相對姿態 → 末端速度**，不是手腕 3D 位置絕對追蹤。Watch 手放回中立位置時速度歸零，**Robot 保持當前位置，不自動回起點**。

- `pitch` / `roll` 控制平面內兩個軸；Z 軸初版交給 Digital Crown 或雙模式 UI。Yaw 易受漂移影響，預設不啟用。
- Neutral dead-zone 建議起始 5° 左右（實測調整）；加入 low-pass / hysteresis / max acceleration / speed ramp。
- 使用 `EEReferenceAndDelta` + `EEBoundsAndSafety` + `InverseKinematicsEEToJoints` 轉換控制命令。若 Processor 假設 action 是 delta 而不是速度，必須用真實 `dt` 換算，避免控制迴圈頻率改變使速度改變。
- SO-101 5 DoF 不足以任意控制完整 6 DoF 末端姿態；先用有限 orientation target 或位置權重較高的 IK 解算。

### 6.3 工作空間碰撞與限制

`SafetyGate` 至少檢查關節軟限位、末端工作空間盒/凸多面體、每次動作變化、速度/加速度、IK 是否收斂、奇異點附近異常跳動；若後續有實物 obstacle model，再增加碰撞距離。

限位時拒絕/裁切朝非法方向的速度分量，但保留離開限位方向的合法速度。限制原因同步回 Watch 的 Haptic Event Channel。

---

## 7. New feature — Bidirectional haptic feedback（這次新增核心需求）

### 7.1 功能與分級

我們不只把 Watch 當成控制器，也讓它變成 **機械手臂狀態的觸覺回饋終端**。Watch 內建 `WKInterfaceDevice.current().play(WKHapticType)`；`WKHapticType` 提供 `.click`, `.directionUp`, `.success`, `.failure`, `.retry`, `.start`, `.stop` 等**固定**樣式，無法假設可連續精細調整震動波形和力度。

| Event | 判斷來源 | Haptic 建議 | UI 文字 | 行為 |
|---|---|---|---|---|
| `NEAR_LIMIT` | 到軟限位距離 < soft margin | `.click`，**第一次進入時一次** | Approaching limit | 持續降速 |
| `LIMIT_HIT` | 命令被 joint/workspace limit 截斷 | `.directionUp` 或 `.failure`（一次） | Movement limit | 裁切朝外速度，允許往內 |
| `CONTACT_SUSPECTED` | 夾爪電流/負載變化 + 位置誤差 | `.click`（一次） | Possible contact | 可暫停收夾或降速；不可宣稱已抓穩 |
| `GRASP_LIKELY` | 多個證據持續成立；可選視覺佐證 | `.success`（一次） | Grasp likely | 停止繼續加壓；保留安全夾持 |
| `GRASP_LOST` | 開合異常或視覺推斷滑落 | `.failure`（一次） | Grip may be lost | 按模式 HOLD / 通知；不可憑單一樣本判斷 |
| `VLA_STARTED` | Supervisor 的 owner ACK | `.start` | VLA controlling | Watch IMU 停止控制 |
| `VLA_FINISHED` | Supervisor 已進 `AWAIT_RECALIBRATION` | `.success` | Double Tap to take over | 繼續 HOLD，**不恢復 Manual** |
| `FAULT/CONNECTION_LOST` | Local fault / network watchdog | `.failure`（一次） | Control unavailable | Local Agent 已自行 HOLD |
| `CALIBRATION_OK` | Server ACK + neutral stable | `.success` | Manual enabled | 允許 Manual |
| `CALIBRATION_FAILED` | 參考姿態不穩或安全前提不滿足 | `.retry` | Recalibrate | 保持 HOLD |

**語意注意**：`.success` 是 Apple 內建樣式，並不代表已做物理接觸確認；UI 必須用 `Grasp likely`，只有經過獨立確認才可顯示 `Grasp confirmed`。

### 7.2 夾爪「抓到東西」判斷 — 不能把限位誤認成夾物

STS3215 的 LeRobot Feetech control table 有：`Present_Position`、`Present_Velocity`、`Present_Load`、`Present_Current`，可用 `robot.bus.sync_read` 讀取（依馬達韌體、傳輸量、鎖定版本實測）。**這些不是校準的指尖力感測器**，不等於確定抓到物體，也不保證物體沒有滑落。

候選訊號：

```text
position_error = abs(gripper_goal - gripper_actual)
current_delta  = filtered_current - baseline_current(position,velocity)
load_delta     = filtered_load - baseline_load(position,velocity)
stalled_like   = commanded_closing && abs(velocity) < v_small && position_error > e_small
contact_score  = calibrated weighted evidence above
```

必要區分：

1. **夾爪空夾到底**：可能電流上升／位置誤差，也可能只是機械 end-stop → `GRIPPER_ENDSTOP`，**不得回報已抓物**。
2. **夾住柔軟物體**：Position/Current 特徵可能不明顯 → 回報 `UNCERTAIN`，不要補償式過度加壓。
3. **抓住硬物**：中途停止收合、位置未達空夾終點、電流/負載異常且持續 → `CONTACT_SUSPECTED` / `GRASP_LIKELY`。
4. **物品滑落**：Watch 無力感知；若有視覺判斷也只是在模型信心足夠時回報。

**第一版資料驅動校準**：每種空夾開合與 2–3 種安全物體，各錄 20–30 次（至少包含空夾、碰觸、成功抓取、失敗抓取），記錄 `goal/actual position`, `velocity`, `current`, `load`, `front/wrist video`；以 labelled ROC/PR 調整門檻，評估 false positive。門檻是每台機器實測值，不硬寫成通用 N 或電流毫安數。

**物理保護**：即使 `GRASP_LIKELY` 不等於已知安全握力；限制馬達目標、用保守速度與電流／過載條件監控，必要時增加指尖 FSR/load cell 作為 v2 可靠力感測。

### 7.3 Haptic event policy（邊緣觸發，不連續狂震）

Watch 的 Haptic API 在 App background/inactive 時通常**無效果**；Apple 不建議短時間反覆發動，系統 haptic engine 有最短恢復間隔，濫用會耗電。參考官方說明。因而設計：

- `NEAR_LIMIT` → 進入預警區只震一次；離開預警區超過 hysteresis 才能再次觸發。
- `LIMIT_HIT` → 同一 axis、同一個限位邊界只震一次，至少 1 秒 cooldown（可配置）。
- `GRASP_LIKELY` → 每次「開 → 關」抓取 transaction 只震一次，不能每 20 Hz 震。
- 區分 `event_id`, `transaction_id`, `axis`, `severity`, `confidence`, `created_at`; Watch 以 event_id 去重。
- 優先級 `FAULT > CONTROL_HANDOFF > LIMIT_HIT > GRASP_LIKELY > NEAR_LIMIT`；高優先事件覆蓋低優先事件，避免 haptic 衝突。
- 事件過期（例 500ms 以上）可只更新 UI 不播放 Haptic；**不播放 haptic 不代表 Robot 沒偵測到事件**。
- haptic 弱或使用者關閉時以 Watch UI 顯示文字狀態作 fallback；不把 haptic 當成實時安全回饋保證。

### 7.4 Swift API（可直接套用）

```swift
import WatchKit

func handleHapticEvent(_ event: HapticEvent) {
    guard event.isFresh && event.isNew else { return }
    let device = WKInterfaceDevice.current()
    switch event.kind {
    case .nearLimit, .contactSuspected:
        device.play(.click)
    case .limitHit:
        device.play(.directionUp)
    case .graspLikely, .calibrationOK, .vlaFinished:
        device.play(.success)
    case .fault, .connectionLost, .graspLost:
        device.play(.failure)
    case .calibrationFailed:
        device.play(.retry)
    case .vlaStarted:
        device.play(.start)
    }
}
```

上例 `HapticEvent`、`isFresh`、`isNew` 是**專案自訂型別／功能**；必須實作去重、冷卻、相容 App 前景檢查。`play` 和 enum 是 Apple 公開 API。

---

## 8. VLA / two-camera inference

### 8.1 Observation schema

```text
observation.images.front    : RGB image (initial 640×480 @ 30fps)
observation.images.wrist    : RGB image (initial 640×480 @ 30fps)
observation.state           : 6 joint positions, order identical to training
observation.timestamp      : robot-local monotonic timestamp
task_text                  : accepted task instruction
control_epoch              : current session ownership version
```

兩個畫面需要取樣時間接近（初始最大錯位 100ms，以實測調整），相機 FPS 真正數值須量測。模型訓練、validation、rollout 的 camera keys、影像 shape、joint order、度數／弧度與 gripper normalization 必須一致。

### 8.2 VLA 推論步驟

1. 語音轉錄與 task validation；任務必須在允許清單且 policy 有相應資料。
2. Local Agent HOLD，確認影像兩路均正常、關節狀態新鮮、policy server ready。
3. Supervisor 更改 `owner=VLA`, `control_epoch++`。
4. 送 `front/wrist/state/task` 至 Policy Server，收到 Action Chunk。
5. 每一步都檢查 `epoch == current_epoch`, action timestamp、joint limits、workspace and speed bounds；Motor Writer 執行。
6. 保持最新觀測、定期重推論，記錄推論時間與 chunk queue depth。
7. 任務結束時：停止 VLA 動作、清空 chunk、HOLD、轉 `AWAIT_RECALIBRATION`，Watch 顯示「Double Tap to take over」。

### 8.3 模型訓練

推薦先使用 SmolVLA 微調一個 **Pick red cube → Drop in box** 任務；官方建議約 50 episodes 作為初始資料量（不是成功率保證）。必須固定觀測命名和 preprocessing。若效能不足，先在同一任務測試訓練資料品質，再考慮更大的模型。兩視角與語言輸入已由官方支援。

### 8.4 Watch 介入與示範資料

- `MANUAL` 中紀錄 front/wrist、實際關節位置、**實際送出的** joint action、task label、操控來源、時間戳。
- `VLA_RUNNING` 中斷後進入 `AWAIT_RECALIBRATION`；Watch Double Tap 校正成功才可操作修正。
- 將人類修正段記錄成 `is_intervention=true`，保留來源、VLA checkpoint、policy confidence、reason_code；但**不要假設原本 Leader Arm 專用 HIL pipeline 能直接兼容 Watch**。
- 若要訓練，不只記 Watch quaternion：至少要保存 policy 需要的 target action + robot observation + synchronized images。對 latency、丟幀與截斷 episode 做篩檢。

---

## 9. Wire protocol / Contracts（v1 draft）

所有跨 Phone/Agent 訊息必須包含：`protocol_version`, `session_id`, `seq`, `sent_mono_ns`（同機相對時間），以及 server 提供的 `control_epoch`。不能把不同裝置 monotonic time 相減當延遲；用往返 ACK 及時鐘偏移估測。

### 9.1 Watch → iPhone motion

```json
{
  "protocol_version": 1,
  "type": "watch.motion",
  "session_id": "s-1021",
  "seq": 912,
  "sample_mono_ns": 18391239123,
  "quaternion_wxyz": [0.99, 0.01, -0.12, 0.04],
  "gyro_rad_s": [0.02, 0.01, -0.03],
  "gravity_g": [0.03, -0.04, -0.998],
  "control_epoch": 14
}
```

Watch 發送 raw pose，Local Agent 才計算控制；Watch 本地也保留 q0 與 UI 估計供顯示，但 Server 的 session reference 為最終真值。

### 9.2 iPhone → Agent command

```json
{
  "protocol_version": 1,
  "type": "control.intent",
  "request_id": "c-5394",
  "session_id": "s-1021",
  "control_epoch": 14,
  "intent": "DOUBLE_TAP",
  "source": "watch-primary-action"
}
```

`DOUBLE_TAP` 的狀態語意**由 Supervisor 決定**，不要信任 Watch 端 UI 自行判斷。`request_id` 幂等；重複送達不可重複執行。

### 9.3 Agent → iPhone → Watch haptic event

```json
{
  "protocol_version": 1,
  "type": "robot.haptic_event",
  "event_id": "evt-10315",
  "session_id": "s-1021",
  "control_epoch": 14,
  "kind": "LIMIT_HIT",
  "severity": "warning",
  "axis": "shoulder_pan",
  "limit_type": "soft_joint",
  "confidence": 1.0,
  "ttl_ms": 500,
  "display": "Joint limit reached"
}
```

`GRASP_LIKELY` 可加 `transaction_id`, `confidence`, `evidence=["current_delta","position_stall"]`。已知 limit detection 可確定（confidence=1 代表 detector 規則確定命令被 clamp，**不是硬體安全認證**），接觸推估則需用低於 1 的經校準信心。

### 9.4 Agent → Clients system status

```json
{
  "protocol_version": 1,
  "type": "robot.status",
  "session_id": "s-1021",
  "control_epoch": 15,
  "mode": "AWAIT_RECALIBRATION",
  "owner": "NONE",
  "reason": "VLA_FINISHED",
  "robot_holding": true,
  "vla_task_id": "task-123"
}
```

**傳輸規則**：Motion frame 使用 latest-only queue（最多一筆未處理）；Control Intent/Haptic Event/Status 使用可靠訊息和 ACK、重試／去重。沒有到達 ACK，Watch 只能顯示「request pending」。別把關節命令放進持久 background transfer queue。

---

## 10. Local Agent API and internal modules

### 10.1 Services

| Python module | Responsibility |
|---|---|
| `gateway.py` | WSS authentication, sessions, heartbeat, schema validation |
| `supervisor.py` | Finite State Machine, owner token, epoch, ACK |
| `watch_teleop.py` | Watch Teleoperator plugin, relative quaternion mapping |
| `safety.py` | joint/workspace/speed/accel constraints; alarm escalation |
| `robot_worker.py` | single USB/motor writer; hold references, watchdog |
| `camera_worker.py` | front/wrist acquisition and synchronization |
| `vla_client.py` | LeRobot Policy Server adapter, chunk cancellation |
| `haptics.py` | event classifier, priority, dedup, cooldown |
| `gripper_estimator.py` | position/current/load filtered contact inference |
| `task_router.py` | allowlisted task → policy checkpoint / manual action |
| `recorder.py` | LeRobot dataset + intervention metadata + logs |

### 10.2 Internal control loop skeleton（架構示意，不可直接控制實機）

```python
while robot_agent.running:
    obs = robot_agent.read_joint_feedback()
    supervisor.check_watchdogs(obs)
    proposed = None

    if supervisor.mode == 'MANUAL':
        proposed = watch_adapter.latest_safe_intent(obs)
    elif supervisor.mode == 'VLA_RUNNING':
        proposed = policy_buffer.next_action_for_epoch(supervisor.epoch)

    if proposed is None:
        target = safety.hold_target(obs)
    else:
        target, safety_events = safety.filter(proposed, obs)
        haptics.emit_edges(safety_events)

    grip_events = gripper_estimator.update(obs, target)
    haptics.emit_edges(grip_events)
    robot_agent.write_joint_target(target)  # ONLY MOTOR WRITER
    robot_agent.record(obs, target, supervisor.snapshot())
```

**實作細節**：`hold_target(obs)` 的策略要避免 Robot 受到 gravity load 時慢慢下垂，需依 SO-101 實測。Joint read/write 同一 bus 的排程需避免鎖定衝突，並實測 telemetry（如 Present_Current）讀取增加的時間。

---

## 11. Safety / Reliability / Security

### 11.1 初始參數（須實機實測）

```yaml
watch:
  requested_motion_hz: 50
  relay_motion_hz: 20
  calibration_still_ms: 400
  neutral_deadzone_deg: 5
phone:
  wss_reconnect: true
robot:
  control_hz: 30
  motion_stale_ms: 250
  wrist_required_foreground: true
  default_mode: HOLD
  vla_end_mode: AWAIT_RECALIBRATION
haptics:
  event_ttl_ms: 500
  limit_cooldown_ms: 1000
  near_limit_hysteresis: true
  grasp_once_per_transaction: true
vla:
  require_both_cameras: true
  task_allowlist: ["pick_red_cube_into_box"]
  action_epoch_check: true
  cancel_clears_action_queue: true
```

安全相關關節角度、速度、工作空間、夾爪壓力門檻不在文件中胡亂填值；必須依馬達校正、機構和場地逐步確認。

### 11.2 Safety invariants in practice

- 先把 SO-101 穩固固定於桌面，清除手臂可及範圍內的人手、線材與易碎物；先空夾低速測試。
- 實體急停或斷電機制獨立於 Watch/iPhone/Server，測試後考慮斷電下垂與重力負載。
- Watch session gone、iPhone inactive、stale motion、VLA delayed、camera lost、joint read error：Local Agent 進 HOLD 或 FAULT；不延續最後速度命令。
- 關節軟限位之外仍遵守硬體極限；VLA 不能靠文字命令停用 limit gate。
- 小心 `SO101FollowerConfig.disable_torque_on_disconnect=True`：disconnect 不是原地鎖住；正常 HOLD 不要 disconnect。
- 夾持物體時不要讓 VLA task conclusion 自動釋放夾爪。
- 對遠端 Server 啟用 TLS/WSS、per-device token、局域網或 VPN、Request ID 去重、最小權限；不可把未認證的 Motor API 暴露公網。
- 紀錄事件 timestamps、owner、epoch、source、command before/after clamp、fault reason，支援可重播的模擬分析。

### 11.3 Haptic failure is not a safety failure

Haptic 可能因 Watch inactive/background、配對不可達、音訊模式或系統節流而完全沒有震動。**必須由本地 Safety Gate 直接阻止危險動作，不可指望使用者感覺到震動再停手**。

---

## 12. Development plan / Milestones

| Milestone | 交付物 | 可量化驗收 |
|---|---|---|
| **M0 – Hardware/Version spike** | 機器人/攝影機/Watch/SDK matrix；固定 LeRobot commit | 可讀 6 軸關節與兩路影像；無重複馬達 writer |
| **M1 – Watch sensor + haptic** | Watch App 前景、Double Tap、IMU stream、Haptic preview | Double Tap/100 次測試成功率與 IMU jitter 報告；Watch 前景才能震動的限制已測 |
| **M2 – iPhone relay + protocol** | WSS、WCSession、身份驗證、status/intent/haptic ACK | 可記錄 p50/p95 延遲、封包損失、斷線時 server HOLD |
| **M3 – Safe manual** | Watch Teleoperator + IK + Double Tap Calibration | 中立姿態零動作、朝限位安全裁切、退出限位可移動；低速 10 分鐘不異常 |
| **M4 – Haptic limits/gripper** | Feetech telemetry + edge event + contact score | 量測 limit 事件正確率；空夾 false grasp 不通過則降級為 only contact suspected |
| **M5 – Dual-camera dataset** | LeRobot Record integration | 同步 frame/action/state/task 可重播；至少 50 筆乾淨示範以單任務起步 |
| **M6 – VLA rollout** | Fine-tuned SmolVLA, separate policy server | 成功率、每任務時間、action queue depth、推論延遲有完整測試紀錄 |
| **M7 – Handoff + intervention** | AWAIT_RECALIBRATION end-state, VLA abort, rebase | VLA 結束 100% 留在 HOLD，未 Double Tap 絕不動；中斷時舊 chunk 全丟棄 |
| **M8 – Demo-ready** | 統一 App/CLI/config/docs、故障注入測試 | 斷線、關閉攝影機、VLA timeout、Watch 熄屏、重複 Double Tap 均安全退回 HOLD |

### Acceptance tests（標準化測試案例）

- **TC01** Watch 校正時手不穩 → 不啟用 MANUAL、不動 Robot。
- **TC02** Watch neutral → end-effector 速度零，Robot 不回 Home。
- **TC03** 手腕持續要求超出工作空間 → 非法分量被 clamp + `LIMIT_HIT` haptic 一次；退回方向仍有效。
- **TC04** 夾爪空夾到底 → 不顯示 `GRASP_LIKELY`（如無法區分，系統應只回 `CONTACT_SUSPECTED`）。
- **TC05** 在安全物品中途夾住 → evidence sustained → haptic 一次；不持續震。
- **TC06** VLA 完成 → `AWAIT_RECALIBRATION`，即使 Watch IMU 繼續送資料 Robot 仍 HOLD。
- **TC07** VLA 結束後 Double Tap 且校正成功 → 才恢復人工控制。
- **TC08** VLA 執行中 Double Tap → Local Agent 遮斷舊 chunk，不再執行任何舊 epoch action。
- **TC09** Watch/Phone 無法傳訊超過 watchdog → Robot HOLD，Watch 震動可缺席但 Motor Safety 不可缺席。
- **TC10** Watch 在背景且收不到 Haptic → Local Agent limit clamp 仍正常。
- **TC11** 語音 STT 錯誤/不支援 task → 不送 VLA motor command。
- **TC12** 屏幕熄滅/控制 App 離開前景 → 即時手動控制停用，Robot HOLD。

---

## 13. Project repository layout

```text
watch-so101-vla/
  README.md
  docs/
    SPEC.md
    SAFETY.md
    TEST_PLAN.md
    API_PROTOCOL.md
    SOURCES.md
  apps/
    watch/                   # Xcode Watch target, Core Motion, Double Tap, Haptics
    ios/                     # iPhone target, WCSession, STT, WSS
    shared/                  # Swift Codable messages
  robot/
    pyproject.toml
    configs/default.yaml
    src/so101_watch/
      gateway.py
      supervisor.py
      robot_worker.py
      watch_teleop.py
      motion_mapper.py
      gripper_estimator.py
      haptics.py
      safety.py
      camera_worker.py
      recorder.py
      vla_client.py
      task_router.py
    tests/
      test_fsm.py
      test_owner_epoch.py
      test_haptic_limiter.py
      test_gripper_contact.py
      test_watchdog.py
  policies/
    dataset_specs/
    training_configs/
    checkpoints/            # exclude weights from Git
  tools/
    camera_probe.py
    feetech_telemetry_probe.py
    watch_latency_benchmark.py
    dry_run_simulator.py
```

### Interface-first implementation order

1. 定義 Swift/Python 共用 JSON schema + FSM + event enums。
2. 建立 `MockRobot`（完全不連接馬達）跑 TC01–TC12。
3. 在 Watch 實機做 haptic、Double Tap、錄音 PoC。
4. USB SO-101 只讀 telemetry + cameras；記錄 calibration/position/current/load dataset。
5. 開啟低速 Manual，接入安全限位與 edge haptics。
6. 接入 SmolVLA、紀錄示範、訓練與交接。

---

## 14. 開發前需完成的核實清單

- [ ] Apple Watch Series 11 watchOS 確切版本、Double Tap 已啟用、按鈕前景可見。
- [ ] Xcode SDK target 與 iPhone 報告的 iOS 27.2 配套實測。**（2026-10-10 實查）開發 Mac 為 macOS 15.1、Xcode 16.2（iOS SDK 18.2 / watchOS SDK 11.2），無法對 iOS 27 / watchOS 27 實機部署；需先升級 macOS 與 Xcode。**
- [ ] Double Tap → 自動短語音錄音是否能採用自訂麥克風流而不搶主畫面。
- [ ] `WCSession` 連續 20Hz sendMessageData 的真實可達率、battery cost 與長時間穩定性。
- [ ] haptic 在 Watch 降腕／inactive / background 時行為與掉訊情境。
- [ ] SO-101 設備型號及是否有 `Present_Current`，讀取時控制迴圈 FPS 有多少損失。
- [ ] 兩台 USB 攝影機可同時開啟，裝置路徑固定、曝光與 focus 穩定。
- [ ] Lock 版 LeRobot plugin / Phone Teleop Processor / Async Server 的入口與兼容性。
- [ ] VLA 訓練用 GPU / 推論裝置、CUDA/ROCm/PyTorch 相容版本。
- [ ] Robot 本地電腦 OS、USB serial 裝置路徑、實體急停。
- [ ] 功能完成前不用真物品上負載測試；先輕量泡棉方塊及低速。

---

## 15. Change log

- **v1.0** — Apple Watch Manual + Voice + VLA Handoff + dual camera.
- **v1.1 (2026-10-10)** — 新增 **Haptic Sensory Feedback**：工作空間/關節限位、接觸疑似、抓取可能、成功/失敗與狀態切換；加入 Feetech telemetry 可行性、False Grasp 防護、前景/背景限制及 Haptic Test Plan。明確保留 VLA 結束後 **必須 Double Tap 才回 Manual** 的核心不變量。

- **v1.2 (2026-10-10)** — 修正 FSM：所有返回 `MANUAL` 的路徑必經 `CALIBRATING`（聆聽逾時、任務被拒、驗證逾時）；新增不變量 9（MANUAL 唯一入口）與 10（非 STOP intent 的 epoch 檢查）；補上 motion stale、Watch inactive、VLA 中 Watch 斷線、攝影機失效、cancel 逾時、Fault 重置等轉移。對應實作與測試：`robot/src/so101_watch/supervisor.py`、`robot/tests/test_fsm.py`。

**END OF SPEC — Implementation-ready draft, not deployed or hardware-tested.**
