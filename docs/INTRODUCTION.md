# watch-so101-vla 專案介紹

> 用 Apple Watch 遙控 SO-101 機械手臂；說一句話，就把手臂交給 VLA 模型自動完成任務；手臂碰到限位或夾到東西時，手錶會震動回饋。

本文是給第一次接觸這個專案的人看的整體介紹。工程細節以 [SPEC.md](SPEC.md)（v1.2）為準，開發進度與操作指令見 [README](../README.md)。

---

## 1. 這個專案在做什麼

一般的機械手臂遙控需要一支同款的「leader arm」，或是搖桿、VR 頭盔。這個專案改用**手腕上的 Apple Watch**：

1. **手腕遙控（MANUAL）**：手錶的 IMU 量測手腕姿態，手腕往前／往側邊傾，手臂就朝那個方向移動；手腕回到中立位置，手臂就原地停住。
2. **Double Tap 校正＋語音**：用 Apple Watch 原生的 Double Tap 手勢（食指拇指互點兩下），讓手臂停住、重新設定手腕的中立姿態，然後開始錄 5 秒語音。
3. **VLA 接手（VLA_RUNNING）**：語音轉文字後，如果內容是允許的任務（例如「把紅色積木放進盒子」），控制權交給 VLA（Vision-Language-Action）模型，由模型看雙攝影機畫面自動操作手臂。這段期間手錶的姿態完全不能控制手臂。
4. **交還控制權**：VLA 不論成功、失敗、被中斷或逾時，手臂都停在原地等待（`AWAIT_RECALIBRATION`）。使用者必須再 Double Tap 重新校正，才拿回手動控制權，**絕不自動交還**。
5. **觸覺回饋**：接近限位、撞到限位、疑似夾到東西、VLA 開始／結束、連線中斷時，手錶會用不同的系統震動樣式提示。

## 2. 為什麼這樣設計：安全原則

整個系統圍繞一條核心原則：

> **只有 Local Robot Agent 能對 SO-101 的馬達下指令。**

手錶、語音、VLA 都只是「控制請求的來源」。所有請求都要經過同一個 Control Supervisor（狀態機）、Safety Gate（限位與步長檢查）和唯一的馬達寫入點。由此衍生出幾個不變量，程式裡違反就直接丟 `IllegalTransition`：

- 任何時刻只有一個控制者：`owner ∈ {NONE, MANUAL, VLA}`。
- 每次換手或進入 HOLD/FAULT，`control_epoch` 就加一；舊 epoch 的封包、VLA action chunk 一律丟棄。所以就算 GPU 在中斷之後才回傳結果，也到不了馬達。
- 進入 `MANUAL` 的**唯一入口**是一次成功的校正，沒有其他路徑能回到手動模式。
- 除了 `STOP`，所有 intent 都要帶目前的 epoch，否則回 `STALE_EPOCH`。例如 VLA 剛結束時才到的「中斷 VLA」不會被誤解成「重新接管」。
- 任何鏈路斷線、資料逾時、攝影機失效、讀取錯誤：Agent 自己進 HOLD 或 FAULT，**不靠手錶震動來保證安全**。
- 斷線時不把馬達扭矩關掉（關掉手臂會垂下來），而是保持在原地。

Double Tap 不是急停。真正的急停必須是獨立的實體斷電或急停開關。

## 3. 系統架構

```text
 Apple Watch Series 11            姿態 IMU、Double Tap、錄音、震動、狀態畫面
        │  WatchConnectivity（WCSession）
 iPhone 13 Pro                    中繼、語音轉文字（SFSpeechRecognizer）、重連與重送
        │  WSS（TLS + Bearer token，可 pin 自簽憑證）
 Local Robot Agent（Python）      接在手臂旁的電腦，用 USB 連手臂
   ├─ gateway        連線驗證、單一控制端、訊息格式驗證、心跳
   ├─ supervisor     狀態機、owner、control_epoch
   ├─ motion_mapper  手腕相對姿態 → 末端速度
   ├─ safety         軟限位、每 tick 步長、非有限值拒收、限位預警
   ├─ haptics        震動事件去重、冷卻、優先級
   ├─ gripper_estimator  用馬達電流／負載／位置推估夾爪接觸
   ├─ task_router    語音文字 → 允許的任務（白名單、規則式）
   ├─ vla_client     VLA policy server 介面，按 epoch 過濾 action
   └─ robot_worker   唯一的馬達寫入者（LeRobot FeetechMotorsBus）
        │ USB serial                        │ 網路
 SO-101 follower（6 顆 STS3215）     Policy server（GPU，SmolVLA 類模型）
```

手錶不直接連網路（watchOS 對 WebSocket／TCP 有用途限制），所以一律經 iPhone 中繼。

## 4. 狀態機

```text
DISCONNECTED → HOLD ──Double Tap──► CALIBRATING(→MANUAL) ──成功──► MANUAL
                                                                    │ Double Tap
                                                                    ▼
                                          CALIBRATING(→LISTENING) ──► LISTENING
                                                                    │ 語音文字
                                                                    ▼
                                                             TASK_VALIDATING
                                    不認得的任務 / 逾時 ──► CALIBRATING(→MANUAL)
                                                                    │ 允許的任務 + 模型就緒 + 雙攝影機正常
                                                                    ▼
                                                               VLA_RUNNING
                                            Double Tap / 斷線 ──► VLA_CANCELLING
                                       成功 / 失敗 / 逾時 / 取消完成 ──► AWAIT_RECALIBRATION
                                                                    │ Double Tap（不開語音）
                                                                    ▼
                                                        CALIBRATING(→MANUAL) → MANUAL
任何狀態：控制器斷線 / 回饋異常 → FAULT；實體急停 → ESTOP_LATCHED
```

同一個 Double Tap 在不同狀態有不同意思（校正並說話／結束語音／中斷 VLA／重新接管），由 Agent 端的 Supervisor 決定，手錶只負責送出「我按了」。

## 5. 手腕怎麼控制手臂

- 校正時要求手腕靜止、掌心朝下約 400 ms，用 quaternion 取平均得到中立姿態 `q0`（全程不用 Euler 角，避免角度跳變）。
- 之後每一筆姿態算 `q_rel = q0⁻¹ ⊗ q`，取旋轉向量的 pitch / roll 兩軸，扣掉約 5° 的死區後乘上增益，限制最大速度和加速度，得到末端速度。
- yaw 會漂移，所以 v1 不使用。
- 這是「姿態 → 速度」而不是「手的位置 → 手臂位置」：IMU 加速度積分無法得到可靠的 3D 位置。

> 目前 `PlaceholderJointMapper` 只是把兩軸速度直接對到兩個關節（`shoulder_lift`、`shoulder_pan`），用來測整條管線。上真手臂前要換成 LeRobot 的 IK 處理鏈。

## 6. 觸覺回饋

| 事件 | 觸發條件 | 手錶震動 |
|---|---|---|
| `NEAR_LIMIT` | 接近軟限位（進入時震一次，有遲滯） | click |
| `LIMIT_HIT` | 指令被限位裁切（同一邊界有冷卻） | directionUp |
| `CONTACT_SUSPECTED` | 夾爪電流／負載異常＋位置停滯 | click |
| `GRASP_LIKELY` | 多項證據持續成立（每次夾取只震一次） | success |
| `VLA_STARTED` / `VLA_FINISHED` | 控制權交接 | start / success |
| `CALIBRATION_OK` / `FAILED` | 校正結果 | success / retry |
| `FAULT` / `CONNECTION_LOST` | 故障、斷線 | failure |

注意：

- 夾爪「夾到東西」只是推估。STS3215 的電流與負載讀值不是校準過的力感測器，而且**空夾到底不能被誤判成夾到東西**。所以 UI 用的是「Grasp likely」，不寫「已夾穩」。
- 震動只是盡力送達。手錶在背景、斷線或被系統節流時可能完全不震，安全不依賴它。

## 7. 程式碼結構

```text
apps/                     Swift（XcodeGen：apps/project.yml）
  shared/                 Swift Package
    SO101Protocol         與 Python 共用的訊息定義，用 JSON fixture 雙邊對照測試
    SO101Link             iPhone 中繼：WCSession 封包、WebSocket 連線、intent 重送、狀態補送
    SO101Voice            手錶錄音 → 分塊傳到 iPhone → 語音轉文字
    SO101WatchKit         手錶端控制邏輯、震動排程、Core Motion 轉接
  ios/SO101Relay/         iPhone App（中繼 + 設定 + 除錯畫面）
  watch/SO101Watch/       watchOS App（主按鈕 + Double Tap + HKWorkoutSession 背景執行）
robot/                    Python Local Robot Agent（uv 管理）
  src/so101_watch/        見第 3 節模組列表
  tests/                  FSM、epoch、震動限流、夾爪推估、gateway、TC01–TC12 驗收測試
  config/so101.example.toml  真手臂設定範本（數值都是佔位，需實測替換）
tools/                    硬體探測（馬達遙測、攝影機）、自簽憑證、序列埠防搶用、遠端啟動腳本
docs/
  SPEC.md                 完整工程規格 v1.2
  HARDWARE_PROBE_*.md     實機唯讀探測紀錄
```

## 8. 怎麼跑起來

### 不需要任何硬體

```sh
# Python agent 全部測試（含 TC01–TC12，用 MockRobot）
cd robot && uv run pytest

# Swift 共用套件
cd apps/shared && swift test
```

### Mock gateway ＋ 模擬器

```sh
cd robot && SO101_GATEWAY_TOKEN=<token> \
  uv run python -m so101_watch.gateway --mock --allow-insecure --host 127.0.0.1 --port 18770
cd apps && xcodegen generate   # 產生 SO101.xcodeproj
```

接著把 iPhone 與 Watch App 裝到一組配對的模擬器，詳細步驟見 README。模擬器沒有 device motion，所以校準一定會逾時失敗，這是正常的。

### 實機

- iPhone / Watch：需要新版 Xcode 與自己的 `DEVELOPMENT_TEAM`，從 Xcode 安裝 iPhone App，手錶 App 透過 iPhone 的 Watch App 安裝。
- 手臂端：用 `tools/make_cert.sh` 產生憑證（印出 pin 貼到 iPhone App），用 `tools/aup_agent.sh /dev/ttyACMx` 在 docker 內啟動 agent。啟動前會先檢查序列埠有沒有被其他程式佔用，被佔用就拒絕啟動，絕不強制結束別人的程式。

## 9. 目前進度

**已完成並測試**

- 狀態機、epoch、Safety Gate、震動策略、夾爪推估、任務路由：Python 單元測試與 TC01–TC12 驗收測試全部用 MockRobot 跑。
- WSS gateway（驗證、單一控制端、心跳），以及 Swift／Python 共用的協定 fixture。
- iPhone 中繼與手錶 App：已在真的 Apple Watch Series 11 + iPhone 上對 mock gateway 跑通，包含 Double Tap、語音轉文字、震動、手腕放下時用 `HKWorkoutSession` 維持背景執行。
- 真手臂的 `robot_worker`：不寫任何校正或設定暫存器；開扭矩前先把目標設為目前位置；若手臂停在伺服器自身限位之外就拒絕開扭矩（實測發現的問題）；斷線時保持扭矩。
- 實機唯讀探測：馬達讀取速率、兩台攝影機的路徑與同步誤差。

**還沒做**

- 用真正的 IK 取代 `PlaceholderJointMapper`。
- 用實測值取代軟限位與夾爪門檻。
- `camera_worker`（雙攝影機擷取）與 `recorder`（LeRobot 資料集錄製）。
- 接上實際的 VLA policy server（目前真手臂模式一律拒絕 VLA）。

### 實測後與 SPEC 不同的地方

| 項目 | SPEC | 現在 | 原因 |
|---|---|---|---|
| 手腕資料逾時 | 250 ms 回 HOLD | 250 ms 原地停住，1.5 s 才離開 MANUAL | WCSession 偶爾卡 300–600 ms |
| 語音聆聽逾時 | 8 s | 15 s | 錄音＋傳輸＋轉文字實測約 8.2 s |
| 手錶 inactive 判定 | 不是 active 就算 | workout 在跑時不算 | 手腕放下時 App 會變 inactive，但仍持續送資料 |
| 背景執行 | 未規定 | `HKWorkoutSession`（不存健康資料） | extended runtime session 無法維持 reachable |

## 10. 非目標（v1 不做的事）

- 不把 IMU 加速度積分當成手的 3D 位置。
- 不使用未公開的 Double Tap 原始手勢事件，也不在背景持續監聽手勢。
- 不宣稱夾爪電流讀值等於夾取力（牛頓）。
- 不讓 LLM 或 VLA 繞過 Supervisor 直接控制馬達。
- 不假設沒微調過的 VLA 能在任意新場景可靠地夾取放置。

## 11. 使用的現成技術

- **Apple**：Core Motion、SwiftUI `.handGestureShortcut(.primaryAction)`（Double Tap）、WatchKit haptics、WatchConnectivity、HealthKit workout session、Speech framework、URLSession WebSocket。
- **Robot**：[LeRobot](https://github.com/huggingface/lerobot) 0.6.1（Feetech 馬達匯流排、SO-101 定義），未來會用它的 IK processors、dataset 與 SmolVLA。
- **Python**：`websockets`、`uv`、`pytest`。

---

⚠️ 本專案控制的是實體機械手臂。所有限位、速度與門檻都必須在自己的手臂與場地上實測。第一次上電請低速、空夾，並準備好實體斷電開關。
