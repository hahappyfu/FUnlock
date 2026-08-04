# FUnlock 设计规格：解锁/锁屏效率优化（方案 A + C）

> 状态：已批准（2026-08-04）。方案 A（自适应轮询节奏）+ 方案 C（锁屏自适应超时）。

## 目标

缩短「锁屏后回来等解锁」的感知延迟（当前 ~3.5~4s），同时加快「离开后锁屏」的响应（当前信号跌破阈值后固定 5s）：

1. **解锁侧**：BLE 轮询感知延迟从 ≤2s 降到 ~0.5s，信号一触线立刻被感知，解锁总耗时可降到 ~2s。
2. **锁屏侧**：信号下降斜率陡峭（快速离开）时 2~3s 锁屏，缓降时维持 5s，避免误锁。
3. 不改解锁/锁屏决策逻辑本身，只改「感知节奏」与「等待时长」两个参数面，风险可控。

## 背景与现状

- 主动模式轮询间隔 `activePollInterval`（`FUn.swift:156`）默认 2.0s，已有两档自适应：信号稳定（波动 <5dBm 连续 10 次）→ 8s；波动 ≥5dBm → 回落 2s（`FUn.swift:895-907`）。**没有按「距阈值的接近度」加速的档位**——信号已经接近解锁阈值时仍按 2s 轮询，这是感知延迟的最大来源。
- 锁屏超时 `proximityTimeout = 5.0`（`FUn.swift:129`）是固定值，`startLockTimer()` 创建定时器时直接使用。离开速度不同但等待相同，快速离开时 5s 偏慢。
- `SignalPipeline.process()` 已输出 `slope`（EWLR 平滑斜率，`SignalPipeline.swift:100`），在 `updateMonitoredPeripheral` 的 `SignalDecision` 中可直接拿到（`FUn.swift:507`），无需新增计算。

## 设计原则

1. 不改变解锁/锁屏决策逻辑：`checkProximity`、`applyLockTimer` 的判定条件不变。
2. 只调参数面：轮询间隔、锁屏超时两个量，均改为信号状态驱动。
3. 省电优先于极限速度：远离阈值时维持现有 2s/8s 节奏，只有「接近阈值」才加速。
4. 可测试：新增参数（接近窗口、快速轮询间隔、快速锁屏超时）全部可注入/可单测。

## 方案 A：自适应轮询节奏

### 现状（`FUn.swift:895-907`）

```
信号稳定（波动<5 连续 10 次）→ 8s
波动 ≥5dBm                  → 2s
```

### 改动

在 `didReadRSSI` 的间隔调整逻辑（`FUn.swift:895-907`）中加入第三档「接近加速」：

| 条件 | 轮询间隔 |
|------|---------|
| `effectiveRSSI >= threshold - 15dBm` 且 `< threshold`（接近但未达） | **0.5s** |
| 波动 ≥5dBm（远离时波动） | 2s |
| 信号稳定 | 8s |

- `threshold` = `lockRSSI`（锁定时用）或 `unlockRSSI`（解锁时用），与 `applyLockTimer`/`checkProximity` 相同的取值逻辑。
- 接近判定用 `effectiveRSSI`（已含衰减惩罚），与锁屏判定一致，避免仅凭原始 RSSI 抖动频繁切换档位。
- 到达阈值触发解锁后，档位回落：若信号 ≥ threshold 且稳定 → 走既有 8s/2s 逻辑。
- 快速轮询档退出条件：信号离开接近窗口（< threshold-15）或 ≥ threshold 时，恢复 2s 基准。

新增常量（放在 `FUn.swift` 顶层，供测试引用）：

```swift
/// 接近阈值窗口：有效信号进入该窗口时启用快速轮询
let proximityPollWindow = 15.0   // dBm
/// 快速轮询间隔（接近阈值时）
let fastPollInterval = 0.5       // s
```

### 收益

- 感知延迟：2s → 0.5s（信号进入接近窗口后）
- 解锁总耗时：~3.5~4s → ~2~2.5s
- 锁屏侧间接受益：信号跌破锁阈值后，0.5s 内即感知并启动锁屏计时，锁屏总等待 = 0.5s 感知 + 超时

## 方案 C：锁屏自适应超时

### 现状（`FUn.swift:129`）

```
proximityTimeout = 5.0   // 固定
```

### 改动

`startLockTimer()`（`FUn.swift:462`）创建定时器时，用当前 `slope` 计算超时：

```swift
/// 锁屏超时随下降斜率自适应：
/// 陡降（slope ≤ -8 dBm/s）→ fastLockTimeout（2.5s）
/// 缓降（slope ≈ 0）     → proximityTimeout（5s）
/// 中间线性插值
let slope = lock.withLock { pipeline.smoothedSlope }  // 负值=下降
let timeout: TimeInterval
if slope <= -8 {
    timeout = 2.5
} else if slope >= -1 {
    timeout = 5.0
} else {
    timeout = 5.0 - 2.5 * ((-slope - 1.0) / 7.0)   // -1 ~ -8 线性映射 5s ~ 2.5s
}
```

- `slope` 为负表示信号下降（`SignalPipeline.swift:140` 中 `slope = -(...)`，下降时为负）。
- 定时器 fire 时的既有门控全部保留（信号恢复跳过、输入活动暂缓、presence 重置），只改等待时长。
- 新增常量：

```swift
/// 快速锁屏：信号快速下降时的锁屏超时
let fastLockTimeout = 2.5      // s
/// 判定「快速下降」的斜率阈值
let fastSlopeThreshold = 8.0   // dBm/s
/// 判定「缓降」的斜率阈值
let mildSlopeThreshold = 1.0   // dBm/s
```

### 收益

- 快速离开：5s → 2.5s 锁屏（加上 0.5s 感知，总响应 ~3s，原 ~5.5s）
- 缓慢走远/信号抖动：维持 5s，不增加误锁风险

## 数据流

```
BLE RSSI → SignalPipeline.process → SignalDecision{effectiveRSSI, slope}
              │                              │
              ▼                              ▼
   didReadRSSI 档位调整                  startLockTimer 超时计算
   （接近窗口→0.5s 轮询）              （斜率→2.5s~5s 超时）
              │                              │
              ▼                              ▼
   checkProximity / applyLockTimer → 触发解锁 / 触发锁屏
```

## 错误处理与降级

- slope 为 0 或信号刚恢复：`mildSlopeThreshold` 分支兜底 5s，行为与现状一致。
- 轮询档位切换失败（restartActiveModeTimer 竞态）：既有 `activeModeTimer` 重建逻辑已处理，不新增失败路径。
- 所有新常量有默认值，不依赖用户配置，无需 UI。

## 测试

- **轮询档位**：构造 `SignalPipeline` 与 `FUn` 测试，验证：
  - 接近窗口内（threshold-15 ≤ eff < threshold）→ `activePollInterval == 0.5`
  - 窗口外 → 2s / 8s 既有逻辑不变
  - 波动触发回落 2s 的既有行为不回退
- **锁屏超时**：`startLockTimer` 超时计算单测：
  - slope = -20 → 2.5s
  - slope = 0 → 5.0s
  - slope = -4 → ≈ 3.75s（线性中点）
- 既有 308 测试全量回归。

## 不做的事（YAGNI）

- 不做方案 B（斜率预测预热/预唤醒）——涉及决策流程改动，列为二期。
- 不改变被动模式扫描参数——被动模式已靠扫描回调驱动，无固定轮询间隔。
- 不做功耗优化（省电档已有 8s 稳定档，够用）。
