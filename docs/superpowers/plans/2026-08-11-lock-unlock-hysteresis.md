# 解锁到位触发 + 锁定联动 + 解锁冷静期 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 让自动解锁只在信号真正达到解锁阈值 `unlockRSSI` 时发动；调解解锁阈值时锁定阈值自动保持 10 dB 迟滞；任何解锁成功后 5 秒内禁止再自动锁定。

**架构：** 三处信号门槛（`FUnManager.swift:379/539/591`）从 `unlockStairThreshold` 改为 `unlockRSSI`；`unlockStairThreshold` 降级为快速轮询启动点（代码不变，仅更新注释）；`setUnlockRSSI` 联动 `setLockRSSI(value - 10)`；`FUn` 新增冷静基准刷新/判定，`onUnlock` 调用之，锁计时器触发处兜底跳过。

**技术栈：** Swift / SwiftUI（macOS 菜单栏 App）、CoreBluetooth、XCTest。无第三方依赖。测试命令：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test`（已知 BLE 集成测试偶发失败，重跑即过，与本改动无关——见 `docs/0805-handoff.md`）。

**设计规格：** `docs/superpowers/specs/2026-08-11-lock-unlock-hysteresis-design.md`（已批准）

---

## 关键现状（实现前必读）

- 解锁信号门控三处：`FUnManager.swift:379`（`onDeviceApproached` 触发点）、`:539`（`attemptAutoUnlock` 主 gate）、`:591`（`displaySleeping` 并行唤醒路径）。
- `unlockStairThreshold = unlockRSSI - preUnlockTrigger`（`FUn.swift:190-194`），`preUnlockTrigger` 默认 10 → stair = -70。`preWakeThreshold = unlockRSSI - wakeAdvance`（默认 20）→ preWake = -80（`FUn.swift:183-187`）。
- 常量（`FUn.swift` 顶部全局）：`fastPollInterval = 0.5`、`fastLockTimeout = 2.5`、`proximityPollWindow = 15.0`。`proximityGracePeriod = 5.0`、`lastProximityEventTime: Date`（`FUn.swift:213-214`，private）。
- `RSSIRange`：`OverviewView.swift:32`，`static let min = -95.0`、`max = -30.0`。
- 决策记录：`FUnManager.recordUnlock(_:reason:detail:)`（`:138-144`）写入可注入的 `DecisionLogger`（`FUnManager.init(fun:nowProvider:decisionLogger:)`，`DecisionLogger(testLogDirectory:)` 支持测试目录）。
- 测试可 `@testable import FUnlock`；`FUnManager`、`DecisionLogger` 均为 `@MainActor`。

---

### 任务 1：解锁触发点迁到 `unlockRSSI`

**文件：**
- 修改：`FUnlock/FUnManager.swift:379`、`:539`（含 `:542` detail 文案）、`:591`（含 `:590` 注释）
- 修改：`FUnlock/FUn.swift:188-194`（`unlockStairThreshold` 注释更新为轮询加速语义）
- 测试：`FUnlockTests/FUnlockTests.swift`（约 `:2756-2791` 区域，替换 `testOnDeviceApproachedAboveUnlockThresholdTriggersUnlock` 并新增两个用例）

- [ ] **步骤 1：改写/新增测试（先写失败测试）**

把 `FUnlockTests.swift` `:2778-2791` 的 `testOnDeviceApproachedAboveUnlockThresholdTriggersUnlock` 替换为：

```swift
func testOnDeviceApproachedBelowUnlockThresholdDoesNotAttemptUnlock() {
    UserDefaults.standard.set(true, forKey: "enabled")
    defer { UserDefaults.standard.removeObject(forKey: "enabled") }
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("fut-\(UUID().uuidString)")
    let logger = DecisionLogger(testLogDirectory: tmp)
    let fun = FUn()
    let manager = FUnManager(fun: fun, decisionLogger: logger)
    fun.unlockRSSI = -60
    fun.lockRSSI = -80
    fun.effectiveRSSI = -65.0  // ≥ 旧 stair(-70)，但 < 解锁阈值 -60
    fun.presence = true
    manager.onSystemScreenLocked()
    manager.onDeviceApproached()

    XCTAssertTrue(manager.state.isEffectivelyLocked,
                  "信号低于解锁阈值（-60）应保持锁定")
    XCTAssertFalse(logger.events.contains { $0.category == .unlock },
                   "-70~-60 预热带不应产生任何解锁决策记录")
}
```

在同一文件追加：

```swift
func testAttemptAutoUnlockBelowUnlockThresholdRecordsSignalBelowThreshold() {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("fut-\(UUID().uuidString)")
    let logger = DecisionLogger(testLogDirectory: tmp)
    let fun = FUn()
    let manager = FUnManager(fun: fun, decisionLogger: logger)
    fun.unlockRSSI = -60
    fun.lockRSSI = -80
    fun.effectiveRSSI = -65.0
    fun.presence = true
    manager.onSystemScreenLocked()
    manager.attemptAutoUnlock()
    XCTAssertTrue(logger.events.contains { $0.reason == .signalBelowThreshold },
                  "低于解锁阈值（-60）应被信号门控拦截并记录 signalBelowThreshold")
}
```

- [ ] **步骤 2：运行测试确认失败**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test`
预期：两个新用例 FAIL（当前 gate 用 `unlockStairThreshold=-70`，-65 会通过 gate；前者产生解锁决策记录，后者记录 `.manualLockActive` 而非 `.signalBelowThreshold`）。

- [ ] **步骤 3：实现三处 gate 切换 + 文案**

`FUnManager.swift:378-382`（`onDeviceApproached`）：

```swift
        // 到位解锁：平滑信号达到解锁阈值 unlockRSSI 才尝试解锁（-70~-60 为预热带，只唤醒不解锁）
        if smoothed >= Double(fun.unlockRSSI) {
            attemptAutoUnlock()
        }
```

`FUnManager.swift:539-543`（`attemptAutoUnlock` gate 与 detail）：

```swift
        guard fun.effectiveRSSI >= Double(fun.unlockRSSI) else {
            Log.sm.debug("SKIP: signal below unlock threshold (\(String(format: "%.1f", self.fun.effectiveRSSI)))")
            timingLog("SKIP signalBelowThreshold rssi=\(String(format: "%.1f", fun.effectiveRSSI)) unlock=\(fun.unlockRSSI)")
            recordUnlock(reason: .signalBelowThreshold, detail: "信号 \(String(format: "%.1f", self.fun.effectiveRSSI)) dBm 低于解锁阈值 \(self.fun.unlockRSSI) dBm")
            return
        }
```

`FUnManager.swift:589-591`（并行唤醒路径，含注释）：

```swift
            // 到位解锁：平滑信号达到解锁阈值 unlockRSSI 时才并行解锁
            if fun.effectiveRSSI >= Double(fun.unlockRSSI) {
```

`FUn.swift:188-194`（注释更新为轮询加速语义）：

```swift
    /// 预解锁触发阈值（dBm）：解锁阈值往更远方向提前 preUnlockTrigger（UI 可填，默认 10），
    /// 信号进入该接近窗口时启用 0.5s 快速轮询（开足马力探测）；不再直接触发解锁，
    /// 真正解锁由信号达到 unlockRSSI 决定
    var unlockStairThreshold: Int {
```

- [ ] **步骤 4：运行测试确认通过**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test`
预期：两个新用例 PASS；原「预备唤醒/阶梯门控」相关用例保持通过。

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/FUnManager.swift FUnlock/FUn.swift FUnlockTests/FUnlockTests.swift
git commit -m "fix: 解锁到位才触发（信号达 unlockRSSI 才注入），-70~-60 为预热带"
```

---

### 任务 2：锁定 `unlockStairThreshold` 作快速轮询启动点（保护测试 + 注释）

**文件：**
- 修改：无功能代码修改（`FUn.swift:987-1021` 轮询逻辑**保持不动**）
- 测试：`FUnlockTests/FUnlockTests.swift` 追加接近窗口断言

> 目的：防止未来的改动无意间把 stair 的轮询加速起点移除。窗口常量 `proximityPollWindow = 15.0`（`FUn.swift:25`），`isNearThreshold` 定义见 `FUn.swift:544-546`。

- [ ] **步骤 1：新增测试**

```swift
func testIsNearThresholdUsesStairWindow() {
    // 接近窗口 = [stair - 15, stair)，与轮询加速触发一致
    XCTAssertTrue(FUn.isNearThreshold(-71.0, threshold: -70.0),
                  "-71 落在 [stair-15, stair) 窗口内")
    XCTAssertTrue(FUn.isNearThreshold(-84.9, threshold: -70.0),
                  "窗口下界含 -84.9")
    XCTAssertFalse(FUn.isNearThreshold(-70.0, threshold: -70.0),
                   "达到阈值本身不算接近窗口")
    XCTAssertFalse(FUn.isNearThreshold(-85.1, threshold: -70.0),
                   "窗口外（-85.1，下界 -85 含等号）不算接近")
}
```

- [ ] **步骤 2：运行测试确认通过（基线）**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test`
预期：PASS（该行为已存在，属回归保护）。

- [ ] **步骤 3：Commit**

```bash
git add FUnlockTests/FUnlockTests.swift
git commit -m "test: 锁定 stair 接近窗口边界行为，保护快速轮询起点"
```

---

### 任务 3：锁定阈值联动（调解解锁自动拉开 10 dB）

**文件：**
- 修改：`FUnlock/FUn.swift` 顶部常量区（`fastPollInterval` 附近 `:27`）新增 `lockUnlockDelayGap`
- 修改：`FUnlock/FUnManager.swift:207-210`（`setUnlockRSSI`）
- 测试：`FUnlockTests/FUnlockTests.swift` 追加联动用例

- [ ] **步骤 1：编写失败的测试**

```swift
func testSetUnlockRSSIAutoAdjustsLock() {
    let fun = FUn()
    let manager = FUnManager(fun: fun)
    manager.setUnlockRSSI(-55)
    XCTAssertEqual(manager.lockRSSI, -65, "调解解锁阈值后锁定应自动设为解锁-10")
    XCTAssertEqual(fun.lockRSSI, -65)
    XCTAssertEqual(UserDefaults.standard.integer(forKey: "lockRSSI"), -65)
    UserDefaults.standard.removeObject(forKey: "unlockRSSI")
    UserDefaults.standard.removeObject(forKey: "lockRSSI")
}

func testSetUnlockRSSIDisabledDoesNotAdjustLock() {
    let fun = FUn()
    let manager = FUnManager(fun: fun)
    manager.setLockRSSI(-80)
    manager.setUnlockRSSI(FUn().UNLOCK_DISABLED)  // = 1
    XCTAssertEqual(manager.lockRSSI, -80, "解锁禁用时不联动锁定")
    UserDefaults.standard.removeObject(forKey: "unlockRSSI")
    UserDefaults.standard.removeObject(forKey: "lockRSSI")
}

func testSetUnlockRSSIClampToRangeMin() {
    let fun = FUn()
    let manager = FUnManager(fun: fun)
    manager.setUnlockRSSI(-95)
    XCTAssertEqual(manager.lockRSSI, -95, "联动值应钳制到滑杆下界 -95")
    UserDefaults.standard.removeObject(forKey: "unlockRSSI")
    UserDefaults.standard.removeObject(forKey: "lockRSSI")
}
```

- [ ] **步骤 2：运行测试确认失败**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test`
预期：`testSetUnlockRSSIAutoAdjustsLock` FAIL（当前 `setUnlockRSSI` 不联动，lockRSSI 仍为初始 -80）；`testSetUnlockRSSIClampToRangeMin` FAIL（当前不联动，lockRSSI 仍 -80）；`testSetUnlockRSSIDisabledDoesNotAdjustLock` PASS（解锁禁用时本就不联动，属保护性基线）。

- [ ] **步骤 3：实现联动**

`FUn.swift` 顶部（`let fastPollInterval = 0.5` 附近）新增：

```swift
/// 解锁 → 锁定 联动迟滞（dB）：调解解锁阈值时锁定自动设为 unlockRSSI - lockUnlockDelayGap
let lockUnlockDelayGap = 10
```

`FUnManager.swift:207-210` 替换为：

```swift
    func setUnlockRSSI(_ value: Int) {
        unlockRSSI = value
        fun.unlockRSSI = value
        UserDefaults.standard.set(value, forKey: "unlockRSSI")
        if value != FUn().UNLOCK_DISABLED {
            setLockRSSI(max(value - lockUnlockDelayGap, Int(OverviewView.RSSIRange.min)))
        }
    }
```

> **计划裁定：** 既有集成测试 `testThresholdChangeDuringDegradation`（`FUnlockTests.swift:3694`）在 `setLockRSSI` 之后调 `setUnlockRSSI` 并断言锁定值不变，联动实现会让其失败。处理方式（方案 A）：把该测试内两处的调用顺序调换为「先 `setUnlockRSSI` 再 `setLockRSSI`」，保留原断言值——核心目标（降级期间可改阈值、恢复后保持）不偏离，且恰好验证"锁定滑杆可手动覆盖"语义。此测试改动列入本任务 commit。

- [ ] **步骤 4：运行测试确认通过**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test`
预期：三个联动用例 PASS；现有阈值相关用例保持通过。

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/FUn.swift FUnlock/FUnManager.swift FUnlockTests/FUnlockTests.swift
git commit -m "feat: 调解解锁阈值自动联动锁定（解锁-10 迟滞，钳制到滑杆下界）"
```

---

### 任务 4：解锁成功后 5 秒冷却期禁止锁定

**文件：**
- 修改：`FUnlock/FUn.swift` 新增 `refreshProximityGrace()` 与 `isWithinLockGracePeriod(now:)`；`FUn.swift:552-587` 锁计时器 fire 闭包加兜底检查
- 修改：`FUnlock/FUnManager.swift:290`（`onUnlock()`）调用刷新
- 测试：`FUnlockTests/FUnlockTests.swift` 追加用例

- [ ] **步骤 1：编写失败的测试**

```swift
func testRefreshProximityGraceWindow() {
    let fun = FUn()
    XCTAssertFalse(fun.isWithinLockGracePeriod(now: Date()),
                   "默认（从未解锁）不应在冷静期")
    fun.refreshProximityGrace()
    XCTAssertTrue(fun.isWithinLockGracePeriod(now: Date()),
                  "刷新后应进入 5 秒冷静期")
    XCTAssertFalse(fun.isWithinLockGracePeriod(now: Date().addingTimeInterval(6)),
                   "超过 5 秒冷静期后应允许锁定")
}

func testOnUnlockRefreshesProximityGrace() {
    let fun = FUn()
    let manager = FUnManager(fun: fun)
    manager.onUnlock()
    XCTAssertTrue(fun.isWithinLockGracePeriod(now: Date()),
                  "任何解锁成功路径应刷新锁冷静基准")
}
```

- [ ] **步骤 2：运行测试确认失败**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test`
预期：FAIL（`refreshProximityGrace` / `isWithinLockGracePeriod` 尚不存在，编译错误即失败）。

- [ ] **步骤 3：实现刷新与判定 + 兜底**

`FUn.swift` 中 `heartbeat` 区域（`cancelHeartbeat` 附近 `:507`）新增：

```swift
    /// 刷新锁冷静基准（所有解锁成功路径调用）：重置 lastProximityEventTime，
    /// 使心跳锁检查与锁计时器触发时都能看到「距最近解锁 < proximityGracePeriod」
    func refreshProximityGrace() {
        lock.withLock { lastProximityEventTime = Date() }
    }

    /// 是否处于锁冷静期（距最近解锁/靠近 < proximityGracePeriod）
    func isWithinLockGracePeriod(now: Date = Date()) -> Bool {
        let last = lock.withLock { lastProximityEventTime }
        return now.timeIntervalSince(last) < proximityGracePeriod
    }
```

`FUn.swift:565` 的 lock timer fire 闭包中，在「输入活跃延后」分支（`if lockOnIdle && self.isUserInputActive`）之后、执行锁定（`Log.sm.debug("Device is away")`）之前插入：

```swift
            if self.isWithinLockGracePeriod() {
                lockLog("[LOCK] timer fired but within unlock grace period, skipping lock")
                self.lock.withLock { self.proximityTimer = nil }
                return
            }
```

`FUnManager.swift:290`（`onUnlock`，`state.screen = .unlocked` 后）追加：

```swift
        fun.refreshProximityGrace()
```

- [ ] **步骤 4：运行测试确认通过**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test`
预期：两个用例 PASS（`testRefreshProximityGraceWindow` 覆盖刷新+判定边界；fire 兜底逻辑复用同一判定函数，已有心跳宽容测试保持通过）。

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/FUn.swift FUnlock/FUnManager.swift FUnlockTests/FUnlockTests.swift
git commit -m "fix: 解锁成功后 5 秒锁冷静期，杜绝刚解锁又秒锁"
```

---

### 任务 5：生产调用点顺序改为「先解锁后锁定」（联动手动覆盖）

**来源：** Task 3 审查裁定（用户确认）。`setUnlockRSSI` 联动后，三处生产调用点"先 `setLockRSSI` 后 `setUnlockRSSI`"会把刚写入的手动锁定值覆盖为 `unlock-10`。改为先解锁（触发联动）再手动锁定，让用户手动设的锁定滑杆值保留。

**文件：** 三处，仅调换两行顺序
- `FUnlock/OverviewView.swift:218-219`
- `FUnlock/ProfileManager.swift:56-57`
- `FUnlock/CalibrationWizardView.swift:358-359`

- [ ] **步骤 1：调换三处调用顺序**

`OverviewView.swift:217-222`：
```swift
            Button {
                manager.setUnlockRSSI(Int(sliderUnlock))
                manager.setLockRSSI(Int(sliderLock))
                manager.setWakeAdvance(wakeAdvance)
                manager.setPreUnlockTrigger(preUnlockTrigger)
            } label: {
```

`ProfileManager.swift:54-58`：
```swift
    @MainActor func applyActiveProfile(to manager: FUnManager) {
        let profile = activeProfile
        manager.setUnlockRSSI(profile.unlockRSSI)
        manager.setLockRSSI(profile.lockRSSI)
    }
```

`CalibrationWizardView.swift:354-361`：
```swift
    private func applyValues() {
        let lock = max(min(suggestedLock, -30), -95)
        let unlock = max(min(suggestedUnlock, -30), -95)
        let finalUnlock = max(unlock, lock + 5)
        manager.setUnlockRSSI(finalUnlock)
        manager.setLockRSSI(lock)
        isPresented = false
    }
```

> 语义：先 `setUnlockRSSI` 触发联动锁定（默认解锁-10），再 `setLockRSSI` 让用户/配置手动锁定值覆盖。联动仍生效（调解锁会自动拉开迟滞），手动锁定滑杆不再被冲掉。行为最终态不变。

- [ ] **步骤 2：编译 + 回归测试**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test`
预期：全部通过；`testThresholdChangeDuringDegradation` 仍验证"先解锁联动、再手锁覆盖"语义。

- [ ] **步骤 3：Commit**

```bash
git add FUnlock/OverviewView.swift FUnlock/ProfileManager.swift FUnlock/CalibrationWizardView.swift
git commit -m "fix: 生产调用点先设解锁再手动锁覆盖，调解锁联动不再冲掉手动锁定值"
```

---

### 任务 6：全量回归

**文件：** 无（验证任务）

- [ ] **步骤 1：运行全量测试**

运行：`xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' test`
预期：全部通过（若有 BLE 集成用例偶发失败，单独重跑该用例确认，与本次改动无关）。

- [ ] **步骤 2：核对 user 场景回归点**

核对以下行为（设计规格「验证」节）：
1. `effectiveRSSI ≥ unlockRSSI` 才触发 `tryUnlock`；
2. `[unlockRSSI-10, unlockRSSI)` 预热带只唤醒、不解锁（无 unlock 决策噪音）；
3. `setUnlockRSSI(-55)` → `lockRSSI = -65`；
4. `onUnlock` 后 5 秒内信号低于锁定阈值不锁。

- [ ] **步骤 3：Commit（如需）**

若有测试残留（如临时文件清理），一并提交：

```bash
git add -A
git commit -m "chore: 解锁/锁定迟滞回归收尾"
```

---

## 自检记录

- **规格覆盖度：** 分节 1（三处 gate）→任务 1；分节 2（快速轮询保留）→任务 2；分节 3（联动）→任务 3；分节 4（冷静期）→任务 4；分节 5（测试）+ 验证 →任务 1/3/4 的用例与任务 5。全部覆盖。
- **占位符扫描：** 无 TODO/待定；每个实现步骤含完整代码块。
- **类型一致性：** `refreshProximityGrace()` / `isWithinLockGracePeriod(now:)` / `lockUnlockDelayGap` 在任务 3、4 定义与测试中的使用一致；`unlockStairThreshold` 在任务 1 后仅剩轮询加速职责，`FUn.swift:992-996` 未动。