# 信号处理管道实现计划

> 基于设计文档 `docs/superpowers/specs/2026-06-17-signal-pipeline-design.md`

## 阶段〇：基础设施

- [ ] **P00: 新增 SignalDecision 结构体 + SignalSource 枚举**
  - 文件: FUn.swift 顶部
  - 风险: 🟢 低
  - 验证: 编译通过

- [ ] **P01: 扩大 latestN 从 5 到 11 + 新增 rssiTimestamps 数组**
  - 文件: FUn.swift, `startMonitor` 重置逻辑
  - 风险: 🟢 低
  - 影响: 窗口延迟 ~1.3s（BLE 100ms 间隔 × 11 样本）
  - 验证: 编译通过

## 阶段一：单阶段实现（逐一验证）

- [ ] **P02: Stage 1 — IQR 异常值过滤**
  - 纯函数: `func applyIQR(rssi: Double, window: [Double]) -> (isAnomalous: Bool)`
  - multiplier=2.0
  - 异常值仅标记，不调 Kalman Q
  - 风险: 🟢 低
  - 验证: 编译通过 + 单元测试

- [ ] **P03: Stage 2 — EWLR 斜率估算**
  - 纯函数: `func computeSlopeEWLR(rssis: [Double], timestamps: [Date], now: Date) -> Double`
  - λ=0.4/s, 时间窗口 1.5s
  - EMA 平滑: `smoothedSlope = 0.3 * rawSlope + 0.7 * prevSmoothedSlope`
  - 钳位 ±30 dB/s
  - 风险: 🟡 中 — 新增时间戳存储
  - 验证: 编译通过 + 单元测试

- [ ] **P04: Stage 3 — Kalman 自适应 Q 增强**
  - 修改 `getEstimatedRSSI`，接受 `slope: Double, isAnomalous: Bool`
  - delta^1.5, 下降 betaSlope=0, gammaAnomaly=1.5
  - 风险: 🟡 中 — 修改现有 Kalman 参数
  - **红线: 非对称性 (delta>0 分支) 不变**
  - 验证: 编译通过 + 单元测试

- [ ] **P05: Stage 4 — 两段式自适应时间衰减**
  - 修改 `getEffectiveRSSI`，接受 `slope: Double, elapsed: TimeInterval`
  - 两段式: |slope|>2 → fast, else → slow
  - slopeFactor=0.3, inactivityFactor=0.05
  - 风险: 🟡 中 — 修改衰减率
  - **红线: floor=-100 不变**
  - 验证: 编译通过 + 单元测试

## 阶段二：管道组装

- [ ] **P06: 新增 SignalPipeline struct + process 方法**
  - 纯函数: `func process(rssi: Int, source: SignalSource, now: Date) -> SignalDecision`
  - 链式调用 S0→S4
  - Kalman 状态作为 `inout` 参数传入/传出
  - 风险: 🟡 中 — 影响现有 updateMonitoredPeripheral
  - 验证: 编译通过 + 集成测试

- [ ] **P07: 重构 updateMonitoredPeripheral 为管道调用 + 决策层**
  - 保留现有 delegate 回调时序
  - displayRSSI 仍用 raw RSSI EMA
  - `resetSignalTimer()` 调用保持在管道之后
  - 风险: 🔴 高 — 修改核心函数
  - **红线: delegate 回调时序不变**
  - 验证: 编译通过 + Release 构建 + 手动测试

## 阶段三：多设备投票

- [ ] **P08: FUnManager 层多设备共识决策**
  - 轻量: `anyClose` / `allFar` 两值判断
  - 不进 FUn.SignalPipeline
  - 风险: 🟡 中
  - 验证: 编译通过

## 阶段四：回归验证

- [ ] **P09: 单元测试重写**
  - 每个 Stage 独立测试 (IQR/斜率/Kalman/衰减)
  - 管道集成测试 (完整链路)
  - 风险: 🟢 低
  - 验证: `xcodebuild test` (需先配置 test target)

- [ ] **P10: Release 构建 + 手动运行验证**
  - 风险: 🟢 低
  - 验证: BUILD SUCCEEDED + 手动验证锁屏/解锁行为

---

## 执行顺序

```
P00 (SignalDecision 类型)
  │
  └─► P01 (latestN=11 + timestamps)
        │
        ├─► P02 (Stage 1: IQR)      ← 独立测试
        │     │
        │     └─► P03 (Stage 2: EWLR)  ← 独立测试
        │           │
        │           └─► P04 (Stage 3: Kalman Q) ← 独立测试
        │                 │
        │                 └─► P05 (Stage 4: 衰减)  ← 独立测试
        │                       │
        │                       └─► P06 (组装管道)
        │                             │
        │                             └─► P07 (重构 updateMonitoredPeripheral)
        │                                   │
        │                                   └─► P08 (多设备投票)
        │                                         │
        │                                         └─► P09 (测试重写)
        │                                               │
        │                                               └─► P10 (验证)
```

每阶段独立 commit，每次 commit 后 `xcodebuild` 验证。

### 统计

| 任务 | 数量 |
|------|------|
| 🟢 低风险 | 5 |
| 🟡 中风险 | 4 |
| 🔴 高风险 | 1 |
| **合计** | **10** |
