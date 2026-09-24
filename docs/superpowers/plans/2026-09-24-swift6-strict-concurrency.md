# FUnlock Phase 1: Swift 6 严格并发升级实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 在不破坏现有业务逻辑前提下开启 `SWIFT_STRICT_CONCURRENCY = complete`，清除所有 Sendable、跨 Actor 隔离与全局可变状态警告，保证 381 个单元测试 100% 通过。

**架构：**
1. Xcode 工程级开启 `SWIFT_STRICT_CONCURRENCY = complete`。
2. 将全局常量收敛至不可变命名空间 `enum BLEUUIDs`，全局日志时间戳与路径加入安全隔离。
3. 服务单例明确区分 `@MainActor` 隔离（UI/系统交互）与 `@unchecked Sendable` 保护（自包含锁的后台服务）。
4. 规范化 `FUnDelegate` 为 `@MainActor` 协议，修正 `UNUserNotificationCenterDelegate` 异步签名。
5. 适配测试套件的主线程隔离，验证编译 0 警告、381 单测通过。

**技术栈：** Swift 5.10 / Swift 6 语言并发特性（`@MainActor`, `Sendable`, `@unchecked Sendable`, `@preconcurrency`）、Xcode 16+、XCTest。

**规格：** [docs/superpowers/specs/2026-09-24-swift6-strict-concurrency-design.md](docs/superpowers/specs/2026-09-24-swift6-strict-concurrency-design.md)

## 全局约束

- 绝不改动 `SignalPipeline` 的 Kalman 滤波与自适应衰减算法。
- 绝不改动密码读取与注入校验逻辑。
- 保持全量 381 个单元测试 100% 通过。
- 不引入任何外部第三方依赖。

---

### 任务 1：Xcode 工程开启完整严格并发检查

**文件：**
- 修改：`FUnlock.xcodeproj/project.pbxproj`

- [ ] **步骤 1：在 project.pbxproj 中为 FUnlock Target 和 FUnlockTests Target 注入 SWIFT_STRICT_CONCURRENCY**

在 `FUnlock.xcodeproj/project.pbxproj` 的 `buildSettings` 中为 Debug 和 Release 配置增加 `SWIFT_STRICT_CONCURRENCY = complete;`：

```pbxproj
				SWIFT_STRICT_CONCURRENCY = complete;
				SWIFT_VERSION = 5.0;
```

- [ ] **步骤 2：运行编译并捕获全部严格并发警告**

运行：`xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | grep "warning:"`
预期：编译成功，能观测到严格并发检查触发的约 15-20 条 warning。

- [ ] **步骤 3：Commit**

```bash
git add FUnlock.xcodeproj/project.pbxproj
git commit -m "build(xcode): 开启 SWIFT_STRICT_CONCURRENCY = complete"
```

---

### 任务 2：全局共享变量与 CBUUID 命名空间治理

**文件：**
- 修改：`FUnlock/FUn.swift:1-30,935-1160`
- 修改：`FUnlock/DebugLog.swift:1-25`

- [ ] **步骤 1：在 FUn.swift 中收敛 CBUUID 与日志节流锁**

修改 `FUnlock/FUn.swift`：
1. 添加 `@preconcurrency import CoreBluetooth`。
2. 将全局 `DeviceInformation`、`ManufacturerName`、`ModelName`、`ExposureNotification` 收敛到 `enum BLEUUIDs`:
```swift
enum BLEUUIDs {
    static let deviceInformation = CBUUID(string: "180A")
    static let manufacturerName = CBUUID(string: "2A29")
    static let modelName = CBUUID(string: "2A24")
    static let exposureNotification = CBUUID(string: "FD6F")
}
```
3. 替换 `FUn.swift` 中所有对这 4 个常量的引用点为 `BLEUUIDs.xxx`。
4. 将 `bleLogThrottleLock` 与 `bleLogLastTime` 封装在 `final class BLELogThrottler: @unchecked Sendable` 中，消除裸全局变量。

- [ ] **步骤 2：在 DebugLog.swift 中治理静态可变属性**

修改 `FUnlock/DebugLog.swift`：
将用于测试覆盖的 `testLogDirectory` 与 `maxFileSize` 声明标记为 `nonisolated(unsafe)`，或者通过其已有串行队列 `queue` 进行线程安全读写访问：
```swift
    /// 测试覆盖：非 nil 时写该目录，避免污染用户真实日志
    nonisolated(unsafe) static var testLogDirectory: URL?
    /// 单文件滚动上限（测试可调小）
    nonisolated(unsafe) static var maxFileSize: UInt64 = LogRotator.defaultMaxBytes
```

- [ ] **步骤 3：运行编译验证上述警告消除**

运行：`xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | grep -E "FUn.swift|DebugLog.swift"`
预期：`FUn.swift` 与 `DebugLog.swift` 的 global mutable variable / CBUUID 警告消除。

- [ ] **步骤 4：Commit**

```bash
git add FUnlock/FUn.swift FUnlock/DebugLog.swift
git commit -m "refactor(concurrency): 治理全局 CBUUID 常量与静态日志变量"
```

---

### 任务 3：服务单例与数据管理器的 Sendable 规范化

**文件：**
- 修改：`FUnlock/SystemInteractionService.swift:8-15`
- 修改：`FUnlock/SecurityService.swift:20-25`
- 修改：`FUnlock/ProfileManager.swift:13-16`
- 修改：`FUnlock/SignalDataStore.swift:20-25`
- 修改：`FUnlock/ScriptRunner.swift:4-10`
- 修改：`FUnlock/TelemetryLogger.swift:31-35`
- 修改：`FUnlock/UpdateDownloader.swift:3-12`

- [ ] **步骤 1：为无状态服务与主线程服务标记 Sendable / @MainActor**

1. `FUnlock/SystemInteractionService.swift`：
```swift
final class SystemInteractionService: Sendable {
    static let shared = SystemInteractionService()
    private init() {}
```
2. `FUnlock/SecurityService.swift`：
```swift
final class SecurityService: Sendable {
    static let shared = SecurityService()
    private init() {}
```
3. `FUnlock/ProfileManager.swift`（UI 观察对象标注 `@MainActor`）：
```swift
@MainActor
final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()
```

- [ ] **步骤 2：为带内部并发保护的后台服务标记 @unchecked Sendable**

1. `FUnlock/SignalDataStore.swift`：
```swift
final class SignalDataStore: ObservableObject, @unchecked Sendable {
    static let shared = SignalDataStore()
```
2. `FUnlock/ScriptRunner.swift`：
```swift
final class ScriptRunner: @unchecked Sendable {
    static let shared = ScriptRunner()
```
3. `FUnlock/TelemetryLogger.swift`：
```swift
final class TelemetryLogger: @unchecked Sendable {
    static let shared = TelemetryLogger()
```
4. `FUnlock/UpdateDownloader.swift`：声明为 `final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable`，`onStateChange` 闭包回调标为 `@Sendable ((State) -> Void)?`。

- [ ] **步骤 3：运行编译验证单例警告消除**

运行：`xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | grep "may have shared mutable state"`
预期：所有 static property `shared` 相关的非 Sendable 警告完全消除。

- [ ] **步骤 4：Commit**

```bash
git add FUnlock/SystemInteractionService.swift FUnlock/SecurityService.swift FUnlock/ProfileManager.swift FUnlock/SignalDataStore.swift FUnlock/ScriptRunner.swift FUnlock/TelemetryLogger.swift FUnlock/UpdateDownloader.swift
git commit -m "refactor(concurrency): 规范化服务单例与数据存储的 Sendable 特性"
```

---

### 任务 4：协议与跨 Actor 隔离及通知代理方法规范化

**文件：**
- 修改：`FUnlock/FUn.swift`（`FUnDelegate` 定义与调用）
- 修改：`FUnlock/AppDelegate.swift:165-270`

- [ ] **步骤 1：将 FUnDelegate 声明为 @MainActor 协议**

在 `FUnlock/FUn.swift` 中：
```swift
@MainActor
protocol FUnDelegate: AnyObject {
    func newDevice(device: Device)
    func updateDevice(device: Device)
    func removeDevice(device: Device)
    func updateRSSI(rssi: Int?, active: Bool)
    func updatePresence(presence: Bool, reason: String)
    func bluetoothPowerWarn()
    func onDeviceApproached()
}
```
并在 `FUn.swift` 中向代理派发事件处，使用 `Task { @MainActor [weak self] in self?.delegate?.xxx() }` 或已有调度确保在主线程调用代理。

- [ ] **步骤 2：修正 AppDelegate 中的 UNUserNotificationCenterDelegate 签名**

在 `FUnlock/AppDelegate.swift:261`：
```swift
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        return [.alert, .sound]
    }
```
消除 `nearly matches optional requirement` 警告。

- [ ] **步骤 3：运行编译验证主工程 0 警告**

运行：`xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | grep "warning:"`
预期：输出中无任何 Concurrency 或 Selector 警告。

- [ ] **步骤 4：Commit**

```bash
git add FUnlock/FUn.swift FUnlock/AppDelegate.swift
git commit -m "refactor(concurrency): 规范化 FUnDelegate 主线程隔离与通知回调"
```

---

### 任务 5：测试套件 MainActor 隔离与全量回归验证

**文件：**
- 修改：`FUnlockTests/FUnlockTests.swift`

- [ ] **步骤 1：为访问 MainActor 属性的测试用例标注 @MainActor**

在 `FUnlockTests/FUnlockTests.swift` 中：
1. 涉及 `manager` 与 `currentTime` 变异的测试类/方法标注 `@MainActor`，例如 `class FUnlockHysteresisTests: XCTestCase` 标为 `@MainActor class FUnlockHysteresisTests: XCTestCase`。
2. 修复 `testCancelsOtherTasksAfterWin` 中未读变量 `cgSessionChecked` 警告。
3. 修复 `testOffsetClampNegative` 中未使用的 `fun` 实例警告。

- [ ] **步骤 2：运行单元测试并验证 0 失败**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：全量 381 个测试在约 12-15 秒内全部通过，无崩溃、无数据竞态。

- [ ] **步骤 3：验证构建无警告**

运行：`xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | grep "warning:" | grep -v "Run script build phase"`
预期：除 Xcode 自带 Run Script 阶段外，0 Swift 编译器警告。

- [ ] **步骤 4：Commit**

```bash
git add FUnlockTests/FUnlockTests.swift
git commit -m "test(concurrency): 修复测试套件主线程隔离与编译器警告"
```
