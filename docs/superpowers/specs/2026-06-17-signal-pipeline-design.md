# FUnlock 信号处理管道重构设计

> 日期: 2026-06-17 | 状态: 待评审

## 一、目标

将 FUn.swift 中 `updateMonitoredPeripheral`（约 50 行，混合滤波/决策/副作用）重构为**纯函数的信号处理管道**，输出单一 `SignalDecision` 结构体，决策层据此执行原有 delegate 回调。

同时纳入五个纯算法改进：

1. **IQR 异常值过滤** — 检测并标记 RSSI 噪声尖峰
2. **指数加权回归斜率** — 实时估算 RSSI 变化率
3. **Kalman 自适应 Q 增强** — 斜率辅助的非对称 Q 调节
4. **两段式自适应时间衰减** — 下降期/静默期切换衰减速率
5. **多设备投票共识** — FUnManager 层轻量封装（不进管道）

---

## 二、SignalDecision 输出类型

```swift
struct SignalDecision: Equatable {
    let displayRSSI: Double         // 显示用平滑 RSSI（raw RSSI EMA，alpha=0.1）
    let kalmanEstimate: Double      // Kalman 滤波后的 RSSI
    let effectiveRSSI: Double       // 时间衰减后的有效 RSSI
    let slope: Double               // RSSI 变化率 (dB/s)，正值=靠近
    let isAnomalous: Bool           // 当前值被 IQR 判定为异常
    let sourceWeight: Double        // 信号源权重 (connected=1.0, scanning=0.7)
}

enum SignalSource { case scanning, connected }
```

**不在决策里的**（由 FUnManager / FUn 的决策层处理）：
- `lockConfidence` / `unlockConfidence` — 阈值比较在决策层做
- `signalLostCount` — 独立状态机，不进管道
- `stableCount` / `activePollInterval` — BLE 连接策略，不进管道

---

## 三、管道架构

### 3.1 管道持有者

```swift
// FUn.swift 新增属性
struct SignalPipeline {
    // 状态（在 FUn 实例上持有，不可逃逸）
    var kalmanEstimate: Double = -60.0
    var kalmanP: Double = 1.0
    var kalmanSampleCount: Int = 0
    var smoothedSlope: Double = 0.0
    var latestRSSIs: [Double] = []     // 增至 11
    var rssiTimestamps: [Date] = []    // 新增，与 latestRSSIs 同步
}

var pipeline = SignalPipeline()
```

### 3.2 管道入口

```swift
func updateMonitoredPeripheral(_ rssi: Int) {
    let now = Date()
    let source: SignalSource = (activeModeTimer != nil) ? .connected : .scanning

    // -- 管道: 纯计算 --
    let decision = pipeline.process(rssi: rssi, source: source, now: now)

    // -- 更新 FUn 级状态 --
    displayRSSI = decision.displayRSSI
    lastReceiveTime = now
    effectiveRSSI = decision.effectiveRSSI
    // ... 其余保持现有行为 ...

    // -- 决策层: 管道输出驱动 --
    applyDecision(decision, rawRSSI: rssi)
}
```

### 3.3 管道内部阶段

```
raw RSSI + source ──┐
                     ▼
          ┌─────────────────────┐
          │ S0  源标记           │
          │ weight = connected   │
          │  ? 1.0 : 0.7        │
          └────────┬────────────┘
                   ▼
          ┌─────────────────────┐
          │ S1  IQR 异常检测      │
          │ n=11, multiplier=2.0 │
          │ 异常值 → 标记但不调 Q │
          └────────┬────────────┘
                   ▼
          ┌─────────────────────┐
          │ S2  EWLR 斜率估算    │
          │ λ=0.4/s, 时间窗口 1.5s│
          │ → EMA 平滑斜率       │
          └────────┬────────────┘
                   ▼
          ┌─────────────────────┐
          │ S3  Kalman 非对称 Q  │
          │ Q = baseQ * (1       │
          │  + alpha*delta^1.5   │
          │  + beta*slope (上升)  │
          │  + gamma*(anomaly?))  │
          │ 下降时 beta=0        │
          └────────┬────────────┘
                   ▼
          ┌─────────────────────┐
          │ S4  两段式自适应衰减  │
          │ |slope|>2 → fastRate │
          │ else     → slowRate  │
          │ penalty → effective   │
          └────────┬────────────┘
                   ▼
            SignalDecision
```

---

## 四、各阶段参数（经数学审查修订）

### S0: 源标记

```
sourceWeight = source == .connected ? 1.0 : 0.7
```

不在管道内做轮询策略决策。`source` 由 `updateMonitoredPeripheral` 调用方传入。

### S1: IQR 异常值过滤

| 参数 | 修订前 | 修订后 |
|------|--------|--------|
| 窗口管理 | 固定 latestN=5 | **时间窗口 1.5s** |
| IQR multiplier | 1.5 | **2.0** |
| 异常处理 | 增大 Kalman Q | **仅标记 isAnomalous** |

理由：时间窗口优于固定样本数（BLE 采样率不固定，1.5s 窗口自适应样本密度）；BLE RSSI 重尾分布需更宽的门限；Kalman R=0.5 已对单点异常有足够抑制力。

### S2: 指数加权回归斜率

| 参数 | 值 |
|------|-----|
| 方法 | EWLR (Exponential Weighted Linear Regression) |
| 衰减常数 λ | 0.4 / s |
| 时间窗口 | 1.5s 内的所有样本 |
| 斜率平滑 | `smoothedSlope = 0.3 * rawSlope + 0.7 * prevSmoothedSlope` |
| 斜率单位 | dB/s，钳位 ±30 |

代替普通 OLS 的理由：时间间隔不均等、需要最近值权重最高、不需存储固定数量的时间戳。

### S3: Kalman 自适应 Q

```swift
var q = kalmanQ
if kalmanSampleCount > 5 && abs(delta) > kalmanDeadZone {
    if delta > 0 {
        // 上升: Q 增大快速跟踪
        let baseTerm = 1.0 + kalmanAlpha * pow(abs(delta), 1.5)
        let slopeTerm = smoothedSlope > 0 ? betaSlope * smoothedSlope : 0
        let anomTerm = isAnomalous ? gammaAnomaly : 0
        q = kalmanQ * (baseTerm + slopeTerm + anomTerm)
    } else {
        // 下降: 保持强力阻尼 (slopeTerm=0)
        let baseTerm = 1.0
        let anomTerm = isAnomalous ? gammaAnomaly : 0
        q = kalmanQ * (baseTerm + anomTerm)
    }
    q = min(q, kalmanQMax)
}
```

| 参数 | 值 |
|------|-----|
| alpha | 0.02 (不变) |
| delta 指数 | **1.5** (替代 delta²) |
| betaSlope (上升) | 0.1 |
| betaSlope (下降) | **0** |
| gammaAnomaly | **1.5** (替代 3.0) |
| Q_max | 0.5 (不变) |

### S4: 两段式自适应时间衰减

```
如果 |slope| > 2.0 dB/s (快速变化):
    adaptiveRate = decayRate * (1 + slopeFactor * |slope|)
否则 (稳定):
    adaptiveRate = decayRate / (1 + inactivityFactor * elapsed)

penalty = adaptiveRate * elapsed
effectiveRSSI = max(kalmanEstimate - penalty, effectiveRSSIFloor)
```

| 参数 | 值 |
|------|-----|
| slopeFactor | 0.3 |
| inactivityFactor | 0.05 / s |
| switchThreshold | 2.0 dB/s |
| effectiveRSSIFloor | -100 (不变) |

---

## 五、不进管道的外部状态机

以下逻辑**继续在 FUn.swift 上独立管理**，不属于管道：

| 状态机 | 位置 | 原因 |
|--------|------|------|
| `signalTimer` / `signalLostCount` | `resetSignalTimer()` — 在 `updateMonitoredPeripheral` 末尾调用，与管道平级 | 独立的状态机，管道仅负责通知"有数据到达" |
| `activeModeTimer` / `stableCount` / `activePollInterval` | `didReadRSSI` 回调中 | BLE 连接策略，非信号质量评估 |
| `heartbeatTimer` / `ensureHeartbeat()` | 与管道平级，读取 `effectiveRSSI` | 定时触发锁屏检查 |
| `proximityTimer` / `startLockTimer()` | 与管道平级 | 锁屏决策机制 |

---

## 六、多设备投票共识（方案 5）— FUnManager 层

不进管道。在 `FUnManager` 中做轻量封装：

```swift
// FUnManager 新增
func consensusDecision() -> Bool {
    let decisions = deviceDecisions  // [UUID: SignalDecision]
    let anyClose = decisions.contains { $0.value.effectiveRSSI > Double(unlockRSSI) }
    let allFar = decisions.allSatisfy { $0.value.effectiveRSSI < Double(lockRSSI) }
    if anyClose { return false }     // 有设备近 → 不解锁
    if allFar { return true }       // 全远离 → 锁屏
    return isScreenLocked()          // 不确定 → 保持现状
}
```

不做复杂加权投票，原因是：当前 FUn 架构是一个 `monitoredPeripheral` + 一套 Kalman 状态，多设备独立跟踪需要重构 FUn 类——这是重大架构变更，不在本次范围。

---

## 七、红线守卫

以下逻辑**绝对不修改**：

- Kalman 非对称性: delta > 0 时 Q 增大，delta <= 0 时保持 base Q
- `getEffectiveRSSI()` 的 floor 钳位 (-100 dBm)
- `displayRSSI` 使用 raw RSSI EMA（alpha=0.1，不用 Kalman 估计值）
- `InputActivityMonitor` 的 os_unfair_lock 保护
- 现有 delegate 回调时序 (`updateRSSI` / `updatePresence` / `onDeviceApproached`)

---

## 八、测试策略

每个管道阶段独立可测试：

```swift
// Stage 单元测试
func testIQR_anomaly_detection()  // 正常值 vs 离群值
func testEWLR_slope_rising()      // 上升信号
func testEWLR_slope_falling()     // 下降信号
func testKalman_asymmetric_Q()    // 上升/下降不对称
func testAdaptiveDecay_fastMode() // |slope| > 2 时
func testAdaptiveDecay_slowMode() // 稳定时

// 集成测试
func testPipeline_full_path()     // S0→S4 完整链路
func testDecision_layer_presence()// applyDecision 正确性
```

---

## 九、回滚策略

每个阶段独立编译通过。如果某阶段引入问题，将其从管道中移除（该阶段 return identity/passthrough），其余阶段不受影响。
