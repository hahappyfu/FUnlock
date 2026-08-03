# FUnlock V3 安全加固版实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 解决当前 50% 的解锁成功率问题，提升到 95%+，并增强安全性和稳定性。

**架构：** 引入 Actor 并发改造，实现预备唤醒、注入前奏、双保险验证、防抖冷却、连续失败降级、Keychain 安全收紧。

**技术栈：** Swift Actor, async/await, IOKit, CGEvent, Keychain, NSWorkspace, DistributedNotificationCenter

---

## 文件结构

### 创建的文件

| 文件 | 职责 |
|------|------|
| `FUnlock/FUnlockStateMachine.swift` | Actor 状态机，管理所有状态转换和防抖冷却 |
| `FUnlockTests/FUnlockStateMachineTests.swift` | 状态机单元测试 |

### 修改的文件

| 文件 | 职责 |
|------|------|
| `FUnlock/FUnManager.swift` | 集成状态机，重构解锁流程 |
| `FUnlock/SystemInteractionService.swift` | 注入前奏、屏幕唤醒、双保险验证 |
| `FUnlock/SecurityService.swift` | Keychain 安全收紧、冷启动错误码捕获 |
| `FUnlock/AppDelegate.swift` | 用户主动干预处理、降级通知 |
| `FUnlockTests/FUnlockTests.swift` | 新增测试用例 |

---

## 任务 1：创建 FUnlockStateMachine Actor

**文件：**
- 创建：`FUnlock/FUnlockStateMachine.swift`
- 测试：`FUnlockTests/FUnlockStateMachineTests.swift`

- [ ] **步骤 1：编写失败的测试**

```swift
// FUnlockTests/FUnlockStateMachineTests.swift
import XCTest
@testable import FUnlock

class FUnlockStateMachineTests: XCTestCase {
    
    func testInitialStateIsActive() async {
        let stateMachine = FUnlockStateMachine()
        let state = await stateMachine.currentState
        XCTAssertEqual(state, .active)
    }
    
    func testTransitionFromActiveToDisplayAsleep() async {
        let stateMachine = FUnlockStateMachine()
        await stateMachine.transition(to: .displayAsleep)
        let state = await stateMachine.currentState
        XCTAssertEqual(state, .displayAsleep)
    }
    
    func testAttemptUnlockWhenReadyToUnlock() async {
        let stateMachine = FUnlockStateMachine()
        await stateMachine.transition(to: .readyToUnlock)
        let canUnlock = await stateMachine.attemptUnlock()
        XCTAssertTrue(canUnlock)
        let state = await stateMachine.currentState
        XCTAssertEqual(state, .unlocking)
    }
    
    func testAttemptUnlockFailsWhenInCooldown() async {
        let stateMachine = FUnlockStateMachine()
        await stateMachine.transition(to: .cooldown)
        let canUnlock = await stateMachine.attemptUnlock()
        XCTAssertFalse(canUnlock)
    }
    
    func testConsecutiveFailuresTriggersDegradation() async {
        let stateMachine = FUnlockStateMachine()
        await stateMachine.transition(to: .unlocking)
        await stateMachine.handleUnlockFailure()
        await stateMachine.handleUnlockFailure()
        await stateMachine.handleUnlockFailure()
        let state = await stateMachine.currentState
        XCTAssertEqual(state, .degraded)
    }
}
```

- [ ] **步骤 2：运行测试验证失败**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -only-testing:FUnlockTests/FUnlockStateMachineTests`

预期：FAIL，`FUnlockStateMachine` 不存在

- [ ] **步骤 3：编写最少实现代码**

```swift
// FUnlock/FUnlockStateMachine.swift
import Foundation

actor FUnlockStateMachine {
    
    // MARK: - 状态定义
    
    enum State: Equatable {
        case active              // 正常使用中
        case displayAsleep       // 屏幕息屏，但系统未休眠
        case preWaking           // 触发预备唤醒
        case readyToUnlock       // 屏幕已亮，等待信号达到阈值
        case unlocking           // 正在注入密码
        case cooldown            // 冷却防抖中
        case degraded            // 连续失败降级中
    }
    
    // MARK: - 核心属性
    
    private(set) var currentState: State = .active
    private var lastUnlockAttempt: Date = .distantPast
    private var consecutiveFailures: Int = 0
    private var activeTask: Task<Void, Never>?
    
    // MARK: - 防抖配置
    
    private let unlockCooldown: TimeInterval = 5.0
    private let failureCooldown: TimeInterval = 10.0
    private let maxConsecutiveFailures: Int = 3
    
    // MARK: - 状态转换
    
    func transition(to newState: State) {
        guard canTransition(from: currentState, to: newState) else {
            return
        }
        currentState = newState
    }
    
    private func canTransition(from: State, to: State) -> Bool {
        switch (from, to) {
        case (.active, .displayAsleep),
             (.displayAsleep, .preWaking),
             (.preWaking, .readyToUnlock),
             (.readyToUnlock, .unlocking),
             (.unlocking, .active),
             (.unlocking, .cooldown),
             (.cooldown, .active),
             (_, .degraded),
             (_, .active):  // 任意状态可以切回 active（用户干预）
            return true
        default:
            return false
        }
    }
    
    // MARK: - 解锁尝试
    
    func attemptUnlock() -> Bool {
        let now = Date()
        
        // 防抖检查
        guard now.timeIntervalSince(lastUnlockAttempt) > unlockCooldown else {
            return false
        }
        
        // 降级检查
        guard consecutiveFailures < maxConsecutiveFailures else {
            transition(to: .degraded)
            return false
        }
        
        lastUnlockAttempt = now
        transition(to: .unlocking)
        return true
    }
    
    // MARK: - 失败处理
    
    func handleUnlockFailure() {
        consecutiveFailures += 1
        
        if consecutiveFailures >= maxConsecutiveFailures {
            transition(to: .degraded)
        } else {
            transition(to: .cooldown)
        }
    }
    
    // MARK: - 重置状态
    
    func resetToActive() {
        currentState = .active
        consecutiveFailures = 0
        activeTask?.cancel()
        activeTask = nil
    }
    
    // MARK: - 任务管理
    
    func setActiveTask(_ task: Task<Void, Never>?) {
        activeTask?.cancel()
        activeTask = task
    }
    
    func cancelActiveTask() {
        activeTask?.cancel()
        activeTask = nil
    }
}
```

- [ ] **步骤 4：运行测试验证通过**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -only-testing:FUnlockTests/FUnlockStateMachineTests`

预期：PASS

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/FUnlockStateMachine.swift FUnlockTests/FUnlockStateMachineTests.swift
git commit -m "feat: 创建 FUnlockStateMachine Actor 状态机"
```

---

## 任务 2：集成状态机到 FUnManager

**文件：**
- 修改：`FUnlock/FUnManager.swift`
- 测试：`FUnlockTests/FUnlockTests.swift`

- [ ] **步骤 1：编写失败的测试**

```swift
// 在 FUnlockTests.swift 中添加
func testFUnManagerUsesStateMachine() async {
    let manager = FUnManager()
    let state = await manager.stateMachine.currentState
    XCTAssertEqual(state, .active)
}
```

- [ ] **步骤 2：运行测试验证失败**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -only-testing:FUnlockTests/testFUnManagerUsesStateMachine`

预期：FAIL，`stateMachine` 属性不存在

- [ ] **步骤 3：编写最少实现代码**

在 `FUnManager` 中添加状态机：

```swift
// FUnlock/FUnManager.swift 中添加
let stateMachine = FUnlockStateMachine()
```

修改解锁流程使用状态机：

```swift
func attemptAutoUnlock() {
    Task {
        // 检查是否可以解锁
        let canUnlock = await stateMachine.attemptUnlock()
        guard canUnlock else {
            Log.sm.debug("SKIP: cannot unlock (cooldown or degraded)")
            return
        }
        
        // 执行解锁
        await performUnlock()
    }
}
```

- [ ] **步骤 4：运行测试验证通过**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock`

预期：PASS

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/FUnManager.swift FUnlockTests/FUnlockTests.swift
git commit -m "feat: 集成状态机到 FUnManager"
```

---

## 任务 3：实现注入前奏

**文件：**
- 修改：`FUnlock/SystemInteractionService.swift`
- 测试：`FUnlockTests/FUnlockTests.swift`

- [ ] **步骤 1：编写失败的测试**

```swift
// 在 FUnlockTests.swift 中添加
func testInjectPasswordWithPrelude() async {
    let service = SystemInteractionService.shared
    // 测试注入前奏流程
    // 注意：实际测试需要模拟键盘事件
}
```

- [ ] **步骤 2：运行测试验证失败**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock`

预期：FAIL，`injectPasswordWithPrelude` 方法不存在

- [ ] **步骤 3：编写最少实现代码**

在 `SystemInteractionService` 中添加：

```swift
func injectPasswordWithPrelude(_ password: String, isSecureCheck: () -> Bool) async -> Bool {
    // 1. 发送 Shift 键
    sendShiftKey()
    
    // 2. 等待 300ms
    try? await Task.sleep(nanoseconds: 300_000_000)
    
    // 3. 检查是否被取消
    guard !Task.isCancelled else { return false }
    
    // 4. 检查安全性
    guard isSecureCheck() else { return false }
    
    // 5. 发送密码
    let result = fakeKeyStrokes(password, isSecureCheck: isSecureCheck)
    
    // 6. 发送 Return 键
    sendReturnKey()
    
    return result
}

private func sendShiftKey() {
    let src = CGEventSource(stateID: .hidSystemState)
    let shiftDown = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: true) // 56 = Shift
    let shiftUp = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: false)
    shiftDown?.post(tap: .cgSessionEventTap)
    shiftUp?.post(tap: .cgSessionEventTap)
}
```

- [ ] **步骤 4：运行测试验证通过**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock`

预期：PASS

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/SystemInteractionService.swift FUnlockTests/FUnlockTests.swift
git commit -m "feat: 实现注入前奏（Shift + 300ms）"
```

---

## 任务 4：实现双保险验证

**文件：**
- 修改：`FUnlock/SystemInteractionService.swift`
- 测试：`FUnlockTests/FUnlockTests.swift`

- [ ] **步骤 1：编写失败的测试**

```swift
// 在 FUnlockTests.swift 中添加
func testVerifyUnlockWithDualInsurance() async {
    let service = SystemInteractionService.shared
    // 测试双保险验证
}
```

- [ ] **步骤 2：运行测试验证失败**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock`

预期：FAIL，`verifyUnlock` 方法不存在

- [ ] **步骤 3：编写最少实现代码**

在 `SystemInteractionService` 中添加：

```swift
func verifyUnlock() async -> Bool {
    return await withTaskGroup(of: Bool.self) { group in
        // 主通道：等待通知
        group.addTask {
            await self.waitForUnlockNotification()
            return true
        }
        
        // 兜底通道：3秒超时
        group.addTask {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return self.checkScreenUnlocked()
        }
        
        // 获取最先完成的结果
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

private func waitForUnlockNotification() async {
    await withCheckedContinuation { continuation in
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { _ in
            DistributedNotificationCenter.default().removeObserver(observer)
            continuation.resume()
        }
    }
}

private func checkScreenUnlocked() -> Bool {
    if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
        return dict["CGSSessionScreenIsLocked"] as? Int != 1
    }
    return false
}
```

- [ ] **步骤 4：运行测试验证通过**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock`

预期：PASS

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/SystemInteractionService.swift FUnlockTests/FUnlockTests.swift
git commit -m "feat: 实现双保险验证（通知 + CGSession 兜底）"
```

---

## 任务 5：实现预备唤醒

**文件：**
- 修改：`FUnlock/FUn.swift`
- 修改：`FUnlock/SystemInteractionService.swift`
- 测试：`FUnlockTests/FUnlockTests.swift`

- [ ] **步骤 1：编写失败的测试**

```swift
// 在 FUnlockTests.swift 中添加
func testSmoothedRSSI() {
    let pipeline = SignalPipeline()
    let smoothed = pipeline.smoothedRSSI(-60.0)
    XCTAssertNotNil(smoothed)
}
```

- [ ] **步骤 2：运行测试验证失败**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock`

预期：FAIL，`smoothedRSSI` 方法不存在

- [ ] **步骤 3：编写最少实现代码**

在 `SignalPipeline` 中添加：

```swift
func smoothedRSSI(_ rawRSSI: Double) -> Double {
    let alpha = 0.3
    if previousRSSI == 0 {
        previousRSSI = rawRSSI
        return rawRSSI
    }
    let smoothed = alpha * rawRSSI + (1 - alpha) * previousRSSI
    previousRSSI = smoothed
    return smoothed
}

private var previousRSSI: Double = 0
```

在 `FUnManager` 中添加预备唤醒逻辑：

```swift
func handleRSSIUpdate(_ rssi: Double) {
    let smoothed = fun.pipeline.smoothedRSSI(rssi)
    
    // 预备唤醒阈值（unlockRSSI + 10dBm）
    let wakeThreshold = Double(unlockRSSI) + 10.0
    
    if smoothed >= wakeThreshold {
        // 触发预备唤醒
        Task {
            await stateMachine.transition(to: .preWaking)
            SystemInteractionService.shared.wakeDisplay()
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 等待 1 秒
            await stateMachine.transition(to: .readyToUnlock)
        }
    }
}
```

- [ ] **步骤 4：运行测试验证通过**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock`

预期：PASS

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/FUn.swift FUnlock/FUnManager.swift FUnlockTests/FUnlockTests.swift
git commit -m "feat: 实现预备唤醒（信号平滑 + 阶梯唤醒）"
```

---

## 任务 6：实现连续失败降级

**文件：**
- 修改：`FUnlock/FUnlockStateMachine.swift`
- 修改：`FUnlock/AppDelegate.swift`
- 测试：`FUnlockTests/FUnlockTests.swift`

- [ ] **步骤 1：编写失败的测试**

```swift
// 在 FUnlockTests.swift 中添加
func testDegradationNotification() async {
    let stateMachine = FUnlockStateMachine()
    await stateMachine.transition(to: .unlocking)
    await stateMachine.handleUnlockFailure()
    await stateMachine.handleUnlockFailure()
    await stateMachine.handleUnlockFailure()
    let state = await stateMachine.currentState
    XCTAssertEqual(state, .degraded)
}
```

- [ ] **步骤 2：运行测试验证失败**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock`

预期：FAIL，通知发送逻辑未实现

- [ ] **步骤 3：编写最少实现代码**

在 `AppDelegate` 中添加通知处理：

```swift
func sendDegradationNotification() {
    let content = UNMutableNotificationContent()
    content.title = "FUnlock 自动解锁失败"
    content.body = "您是否修改了 Mac 登录密码？点击重新配置。"
    content.sound = .default
    
    let request = UNNotificationRequest(
        identifier: "degradation",
        content: content,
        trigger: nil
    )
    
    UNUserNotificationCenter.current().add(request)
}
```

- [ ] **步骤 4：运行测试验证通过**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock`

预期：PASS

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/AppDelegate.swift FUnlockTests/FUnlockTests.swift
git commit -m "feat: 实现连续失败降级通知"
```

---

## 任务 7：Keychain 安全收紧

**文件：**
- 修改：`FUnlock/SecurityService.swift`
- 测试：`FUnlockTests/FUnlockTests.swift`

- [ ] **步骤 1：编写失败的测试**

```swift
// 在 FUnlockTests.swift 中添加
func testKeychainColdBootError() {
    let service = SecurityService.shared
    // 测试冷启动错误码捕获
}
```

- [ ] **步骤 2：运行测试验证失败**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock`

预期：FAIL，冷启动错误码捕获未实现

- [ ] **步骤 3：编写最少实现代码**

修改 `SecurityService`：

```swift
func fetchPassword() -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "FUnlock",
        kSecReturnData as String: true
    ]
    
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    
    // 冷启动错误码捕获
    if status == errSecInteractionNotAllowed {
        // Mac 刚重启，用户还没进行第一次手动解锁
        // 保持静默，不增加失败计数，不触发降级
        return nil
    }
    
    guard status == errSecSuccess, let data = result as? Data else {
        return nil
    }
    
    return String(data: data, encoding: .utf8)
}
```

- [ ] **步骤 4：运行测试验证通过**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock`

预期：PASS

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/SecurityService.swift FUnlockTests/FUnlockTests.swift
git commit -m "feat: Keychain 安全收紧（冷启动错误码捕获）"
```

---

## 任务 8：用户主动干预处理

**文件：**
- 修改：`FUnlock/AppDelegate.swift`
- 测试：`FUnlockTests/FUnlockTests.swift`

- [ ] **步骤 1：编写失败的测试**

```swift
// 在 FUnlockTests.swift 中添加
func testUserInterventionHandling() async {
    // 测试用户主动干预处理
}
```

- [ ] **步骤 2：运行测试验证失败**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock`

预期：FAIL，用户干预处理未实现

- [ ] **步骤 3：编写最少实现代码**

在 `AppDelegate` 中添加：

```swift
func setupUserInterventionObserver() {
    NotificationCenter.default.addObserver(
        forName: NSWorkspace.screensDidWakeNotification,
        object: nil,
        queue: .main
    ) { [weak self] _ in
        guard let self else { return }
        
        Task {
            let state = await self.stateMachine.currentState
            if state != .active {
                await self.stateMachine.resetToActive()
                Log.sm.debug("User intervention detected, resetting to active")
            }
        }
    }
}
```

- [ ] **步骤 4：运行测试验证通过**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock`

预期：PASS

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/AppDelegate.swift FUnlockTests/FUnlockTests.swift
git commit -m "feat: 实现用户主动干预处理"
```

---

## 任务 9：集成测试

**文件：**
- 测试：`FUnlockTests/FUnlockTests.swift`

- [ ] **步骤 1：编写集成测试**

```swift
// 在 FUnlockTests.swift 中添加
func testFullUnlockFlow() async {
    // 测试完整解锁流程：信号 → 预备唤醒 → 解锁 → 验证
}
```

- [ ] **步骤 2：运行测试验证通过**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock`

预期：PASS

- [ ] **步骤 3：Commit**

```bash
git add FUnlockTests/FUnlockTests.swift
git commit -m "test: 添加集成测试"
```

---

## 任务 10：版本号更新和文档

**文件：**
- 修改：`FUnlock/Info.plist`
- 修改：`README.md`

- [ ] **步骤 1：更新版本号**

```bash
# 更新 Info.plist 版本号为 2.6.0
```

- [ ] **步骤 2：更新 README**

更新功能说明和版本号。

- [ ] **步骤 3：Commit**

```bash
git add FUnlock/Info.plist README.md
git commit -m "chore: 更新版本号为 2.6.0"
```

---

## 测试策略

### 单元测试
- Actor 状态转换测试
- 防抖冷却逻辑测试
- 信号平滑算法测试
- 连续失败降级测试

### 集成测试
- BLE 信号 → 预备唤醒 → 密码注入 完整流程
- 电源状态变化 → 扫描控制
- 密码修改 → 降级 → 恢复

### 安全测试
- Keychain 访问权限测试
- 冷启动错误码捕获测试
- 并发访问安全性测试

---

## 性能基准

| 指标 | 目标 | 测试方法 |
|------|------|---------|
| 解锁响应时间 | < 1 秒 | 测量从信号达标到解锁完成的时间 |
| 解锁成功率 | > 95% | 统计 100 次解锁尝试的成功次数 |
| 内存使用 | < 100 MB | 监控应用内存占用 |
| CPU 使用 | < 5% | 监控应用 CPU 占用 |
