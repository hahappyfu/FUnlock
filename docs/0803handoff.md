# Handoff: FUnlock Auto-Lock 不触发排查

## 背景

FUnlock 是 macOS BLE 自动解锁工具。用户报告两个问题：
1. 自动锁屏不触发（信号明明低于锁定阈值）
2. 之前的 `DecisionLogger` coalescing 事件不写磁盘（已修复）

## 截图证据（最新：17:38:30）

**信号诊断图显示：**
- 17:37:07 — 自动解锁事件（signal:-49.0, Eff:-49.6）
- 之后 Kalman 蓝线大幅下降，**Effective 紫线降到了 -75 ~ -80 dBm**
- 用户 lockRSSI 设置为 -65，**信号确实降到了锁屏阈值以下**
- 17:38:28 — 记录了自动锁屏事件（signal:-57.3, Eff:-53.5）
- **但用户确认屏幕实际没有锁定**

**关键矛盾：**
1. 信号降到了 lockRSSI(-65) 以下，锁屏事件也被记录了，但屏幕没有实际锁定
2. 锁屏事件记录的 Eff=-53.5 已经高于阈值了 — 说明锁屏定时器是在信号低于阈值时启动的，但定时器触发时信号已恢复
3. 可能存在"锁屏后立即被解锁"的快速循环

**另一个观察：** 图表中橙色虚线（锁屏阈值）在 ~-85 位置，但实际 lockRSSI=-65。可能图表显示的阈值计算有误，或存在不同的阈值逻辑。

## 用户配置

```bash
defaults read com.fuhahah.FUnlock
```

关键设置：
- `lockRSSI = "-65"`（锁屏阈值）
- `unlockRSSI = "-55"`（解锁阈值）
- `manualLockNoAutoUnlock = 1`（手动锁屏后不自动解锁）
- 设备：Apple Watch Series 7

## 排查方向

### 1. `applyLockTimer` 拦截条件分析

`FUnlock/FUn.swift` 第 790-819 行的 `applyLockTimer` 方法有多个拦截条件：

```swift
private func applyLockTimer(effectiveRSSI: Double) {
    let threshold = Double(lockRSSI == LOCK_DISABLED ? unlockRSSI : lockRSSI)
    if effectiveRSSI >= threshold {
        // 取消锁屏定时器
    } else {
        let (curPresence, curTimer) = lock.withLock { (presence, proximityTimer) }
        if curPresence && curTimer == nil {
            let elapsed = Date().timeIntervalSince(lastProximityEventTime)
            if elapsed < self.proximityGracePeriod {  // 5秒冷静期
                return  // ← 可能在这里被拦截
            }
            if lockOnIdle && isUserInputActive {
                return  // ← 或者在这里被拦截（用户正在操作）
            }
            startLockTimer()
        }
        // curPresence == false 也会跳过  ← 或者 presence 已经是 false
    }
}
```

**需要排查的3个拦截点：**
1. **`proximityGracePeriod`（5秒）** — 刚解锁后的冷静期，`lastProximityEventTime` 是否被频繁重置？
2. **`isUserInputActive`** — 用户正在输入时拒绝锁屏，是否这个条件一直为 true？
3. **`curPresence == false`** — 如果 presence 已经被设为 false（信号丢失检测），锁屏定时器不会启动

### 2. 心跳定时器中的重置逻辑

`FUnlock/FUn.swift` 第 530-604 行的 `ensureHeartbeat`/`makeHeartbeatTimer` 中：

```swift
if eff < threshold && !hasTimer && graceElapsed >= self.proximityGracePeriod {
    if self.isUserInputActive {
        self.lock.withLock {
            self.lastReceiveTime = Date()
            self.pipeline.decayBaseline = Date()  // ← 重置衰减基准！
        }
    } else {
        self.startLockTimer()
    }
}
```

**关键发现：** `isUserInputActive` 为 true 时，会重置 `lastReceiveTime` 和 `decayBaseline`，这会阻止 effectiveRSSI 衰减，导致信号"虚假回升"。

### 3. 需要添加的诊断日志

在 `applyLockTimer` 中添加日志记录每个拦截条件的状态：

```swift
// 建议在 applyLockTimer 的 else 分支中添加：
Log.sm.debug("[LOCK] effectiveRSSI=\(effectiveRSSI) threshold=\(threshold) presence=\(curPresence) hasTimer=\(curTimer != nil) graceElapsed=\(elapsed) inputActive=\(isUserInputActive)")
```

## 相关文件

- `FUnlock/FUn.swift` — BLE 核心逻辑（信号处理、presence 判断、锁屏定时器）
- `FUnlock/FUnManager.swift` — 管理器（状态机、决策记录、自动解锁逻辑）
- `FUnlock/DecisionLogger.swift` — 决策日志器（已修复 coalescing）
- `FUnlock/DiagnosticsView.swift` — 诊断 Tab（信号图表）
- `FUnlock/Info.plist` — 版本号 2.7.0 (1229)

## 相关计划文档

- `docs/superpowers/plans/2026-08-02-diagnostics-tab-handoff.md` — 诊断 Tab 实现计划

## 建议技能

- `systematic-debugging` — 系统化调试流程，用于排查 auto-lock 不触发的根因
- 重点使用**第一阶段（根因调查）**的"添加诊断埋点"和"跟踪数据流"方法

## 下一步

1. 在 `applyLockTimer` 中添加详细日志，记录每个拦截条件的状态
2. 编译安装，让用户重新测试
3. 收集日志，分析哪个拦截条件导致锁屏被阻止
4. 根据发现修复根本原因
