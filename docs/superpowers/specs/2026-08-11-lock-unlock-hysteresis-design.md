# 解锁到位触发 + 锁定联动 + 解锁冷静期设计

## 背景

### 问题现象

用户实测（2026-08-11，`~/Library/Logs/FUnlock/decisions.jsonl` 精确到秒）：

| 时间 | 事件 | 有效信号 |
|---|---|---|
| 08:50:11 | 自动锁定 lockedAway | -55（判决值已衰减） |
| 09:00:12 | 自动解锁 | -62 |
| 09:00:14 | 解锁失败，用户被迫手动解锁 | -67.9 |
| 09:00:22 | **自动再锁定（距手动解锁仅 8 秒）** | -77 |
| 09:03:05 | 自动解锁 | -60 |
| 09:03:07 | 解锁失败，手动解锁 | -57 |
| 09:03:08 | stateMachineBlocked | -61 |

核心症状：**解锁后短时间内再次被自动锁定**；以及解锁在信号低于名义解锁阈值时即发动。

### 根因（已完成系统化调试）

用户配置：`unlockRSSI = -60`、`preUnlockTrigger = 10`、`lockRSSI = -70`。

1. **解锁实际边界与名义边界不符**。设计上 `unlockStairThreshold = unlockRSSI - preUnlockTrigger = -70`，注释称其为「预解锁触发/弹密码框」；但代码中它被 `FUnManager.attemptAutoUnlock`（`FUnManager.swift:539`、`:591`）当作**直接解锁**的信号门控，且 `attemptAutoUnlock` 内没有「等待信号达到 `unlockRSSI` 再注入」的二次门槛。全仓库无「弹密码框/预解锁准备」实现（`primeUnlock`/`revealPassword` 均不存在）。历史：2.8.23（`d99f18d`）把原「到位解锁 margin=0」改为「解锁阈值 - trigger」，注释写成「弹密码框」，但未落地预热机制，导致解锁提前 10 dBm 发动。

2. **锁定边界与解锁边界重合**。`lockRSSI = -70` 与解锁实际边界 `unlockStairThreshold = -70` 一致（无迟滞带），Apple Watch 信号在 -60~-75 正常波动即频繁跨越同一阈值，造成「解锁 → 秒锁 → 再解锁」振荡。

3. **手动解锁不刷新锁冷静基准**。锁冷静期 `lastProximityEventTime`（`FUn.swift:698`）只在自动靠近（`checkProximity`）时刷新；用户手动解锁（`FUnManager.onUnlock`）不会刷新，导致手动解锁后数秒即可再被锁定（09:00:22 实证）。

4. 副因：锁定判决用 `getEffectiveRSSI()`（`FUn.swift:431`，含 BLE 采样中断时间衰减），iMessage 通知却显示未衰减的 `fun.effectiveRSSI`，造成「强信号 -55 却锁定」的观感失真。本设计不作为修改项，仅记录。

## 目标

1. 解锁只在信号达到**解锁阈值 `unlockRSSI`** 时才发动（名实相符）。
2. 解锁后短时间（冷静期）内禁止自动锁定，杜绝「刚解锁又秒锁」。
3. 调解解锁阈值时锁定阈值自动跟随（拉开固定迟滞），避免阈值重合重演。

## 非目标（不做）

- 不修改锁定判决的 `getEffectiveRSSI()` 时间衰减逻辑。
- 不修改 iMessage 通知的信号显示来源。
- 不引入「预估密码框/预解锁准备」新 UI 或新功能。
- 不做锁定阈值智能动态迟滞（如按噪声幅度自适应）。

## 设计

### 1. 解锁触发点改为解锁阈值（核心）

`FUnManager.swift:539`、`:591`、`:379` 的信号门槛由 `unlockStairThreshold` 改为 `unlockRSSI`：

- `:539`（`attemptAutoUnlock` 主门控）
- `:591`（displaySleeping 并行唤醒+解锁路径）
- `:379`（`onDeviceApproached` 阶梯解锁触发点，改为 `unlockRSSI` 后同时避免预热带内产生 `signalBelowThreshold` 噪音决策记录）

```swift
// 之前
guard fun.effectiveRSSI >= Double(fun.unlockStairThreshold) else { ... }
// 之后
guard fun.effectiveRSSI >= Double(fun.unlockRSSI) else { ... }
```

- 信号 ∈ [-70, -60)（预热带）：只唤醒（由 `preWakeThreshold = -80` 已有逻辑负责）、只快速轮询，**不输密码**。
- 信号 ≥ -60：才走 `tryUnlock()` → 密码注入。
- 非目标语义保留：`unlockRSSI == UNLOCK_DISABLED` 时依旧被 `attemptAutoUnlock` 的既有 guard（`FUnManager.swift:536`）拦截，行为不变。

同步改决策日志文案，使其如实反映判决依据：

- `FUnManager.swift:542` `signalBelowThreshold` 的 detail 由「低于阶梯阈值 X」改为「低于解锁阈值 X」。

### 2. 保留 -70 作为快速轮询启动点

`FUn.swift:992-996` 不变：信号进入 `[unlockStairThreshold - 窗口, unlockStairThreshold)` 时仍启动 0.5s 快速轮询（`fastPollInterval`）；离开窗口回落 2s 基准；稳定 10 次进 8s 慢档。`preUnlockTrigger` 的角色从「解锁触发器」降级为「轮询加速触发器」，其数值与 UI 含义不变。

即：`-70` 对应「开足马力探测」，`-60` 对应「动手输密码」，两层职责分开。

### 3. 锁定阈值联动（联动默认 + 可覆盖）

在 `FUnManager.setUnlockRSSI(_ value: Int)`（`FUnManager.swift:207`）中，当 `value != FUn().UNLOCK_DISABLED` 时联动设置锁定阈值：

```swift
func setUnlockRSSI(_ value: Int) {
    unlockRSSI = value
    fun.unlockRSSI = value
    UserDefaults.standard.set(value, forKey: "unlockRSSI")
    if value != FUn().UNLOCK_DISABLED {
        setLockRSSI(max(value - lockUnlockDelayGap, RSSIRange.min))  // 新增常量 lockUnlockDelayGap = 10，联动值钳制到滑杆下界
    }
}
```

- 新增常量 `lockUnlockDelayGap = 10`（放 `FUn.swift` 常量区，UI 不暴露）。联动值钳制到 `RSSIRange.min`，避免解跌破滑杆下界时锁定产生越界值。
- 保留独立 `setLockRSSI` / 锁定滑杆，用户可随时手动覆盖；校准向导、`ProfileManager`、`AppDelegate` 偏好读取逻辑**不动**（profile 内仍独立存储 lockRSSI，切换 profile 时仍走 `setLockRSSI` 原样覆盖）。
- 语义（已与用户确认）：调解解锁阈值后，锁定阈值被重置为「解锁 - 10」；此后如需自定义锁定，再单独调一次锁定滑杆即可（下次调解解锁会再次重置）。
- 副作用收益：本次用户配置 `unlockRSSI=-60 → lockRSSI=-70`，联动后值恰好与现状一致，无实际配置迁移。
- 启动时 `AppDelegate.swift:457-458` 从偏好加载 `lockRSSI` 的逻辑不变；仅运行时调解解锁才会触发联动。

### 4. 解锁成功后的锁冷静期（C）

现状机制：`FUn.swift:475-477` 心跳锁检查用 `graceElapsed = now - lastProximityEventTime >= proximityGracePeriod(5.0)` 作为启动锁计时器的门槛；`lastProximityEventTime` 仅在 `checkProximity`（`FUn.swift:698`）自动靠近时刷新。

改动：

1. 在 `FUn` 暴露刷新方法（如 `func refreshProximityGrace()`），将 `lastProximityEventTime` 置为 `Date()`。
2. `FUnManager.onUnlock()`（`FUnManager.swift:290`，覆盖手动解锁与自动解锁全部成功路径）调用该方法。
3. 锁计时器触发时（`FUn.swift:552-587` fire 闭包）追加冷静期检查：距最近刷新（即最近解锁）小于 `proximityGracePeriod` 时跳过锁定并复位 `proximityTimer`。覆盖心跳启动门槛遗漏的边界（如刚解锁后立即进入锁计时但 fire 时已过 grace 的情形——统一在 fire 处兜底）。

效果：任何解锁成功后至少 5 秒内，信号再弱也不触发自动锁定。

### 5. 测试

更新既有断言：

- `FUnlockTests.testOnDeviceApproachedAboveUnlockThresholdTriggersUnlock`（`:2778`）：`effectiveRSSI = -65`（< 解锁阈值 -60）时应**不再触发**解锁流程（改断言为保持锁定）。
- 梳理 `FullUnlockFlowIntegrationTests` 中按旧 stair 语义的注释/断言，与新解锁边界对齐。

新增用例：

1. 解锁触发点：`effectiveRSSI ≥ unlockRSSI` 触发 `tryUnlock` 流程；`[-70, -60)` 区间只唤醒、不解锁。
2. stair 仍启动快速轮询：接近窗口命中时 `activePollInterval == fastPollInterval`；离开回落。
3. 锁定联动：`setUnlockRSSI(-55)` → `lockRSSI == -65`；`UNLOCK_DISABLED` 不联动。
4. 锁冷静期：`onUnlock` 后 5 秒内信号低于锁定阈值不锁；超过 5 秒后可锁。
5. 决策文案：`signalBelowThreshold` detail 含「解锁阈值」。

## 验证

- 全部 XCTest（约 329 用例）通过：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`（具体以仓库既有测试命令为准）。
- 用户回归验证：日常使用不再出现「解锁后数秒自动锁定」。

## 风险

- 解锁延时略增（需信号真正到 -60 才输密码）。换取的是边缘信号不再频繁解锁，体验目标已权衡。
- 联动会覆盖曾被手动设置的锁定值——已在语义中明示，可通过再次手动调节绕过。