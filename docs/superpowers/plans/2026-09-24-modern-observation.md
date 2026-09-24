# FUnlock Phase 3: macOS 14+ 现代 Observation 演进与 DeviceSnapshot 闭环实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 将项目最低部署目标升至 macOS 14.0，全面引入 Swift 官方 `@Observable` 宏替代旧版 Combine 状态模型，将设备模型彻底闭环至不可变值类型 `DeviceSnapshot`，保持 382 个测试持续通过且 0 编译器与链接告警。

**架构：**
1. **工程配置**：升级 `MACOSX_DEPLOYMENT_TARGET = 14.0`，消除 XCTest 的 ld 链接版本不匹配警告。
2. **状态响应**：在 `FUnManager`、`ProfileManager`、`DecisionLogger`、`SignalDataStore`、`FUn` 中引入 `import Observation` 与 `@Observable` 宏，删除全部 `@Published` 与 `ObservableObject` 样板代码。
3. **模型闭环**：将 `FUnDelegate` 的设备相关回调与 `FUnManager.discoveredDevices` 彻底切换为 `DeviceSnapshot` 纯值类型，杜绝跨线程堆引用。
4. **视图精简**：SwiftUI 视图层全面精简，用普通属性代替 `@ObservedObject`，用 `@State` 代替 `@StateObject`。

**技术栈：** macOS 14.0+ SDK、Swift 6 严格并发模式、Swift 官方 Observation 框架、SwiftUI、XCTest。

**规格：** [docs/superpowers/specs/2026-09-24-modern-observation-design.md](docs/superpowers/specs/2026-09-24-modern-observation-design.md)

## 全局约束

- 绝不改动 `SignalPipeline` 的 Kalman 滤波与自适应衰减数学模型。
- 绝不削弱密码读取与锁屏安全门控（`isSecureToInject`）逻辑。
- 保持全量 382 个单元测试 100% 通过。
- 核心业务单文件行数继续严格控制在 300 行以内。
- 不引入任何外部第三方依赖。

---

### 任务 1：Xcode 工程升级最低部署目标至 macOS 14.0

**文件：**
- 修改：`FUnlock.xcodeproj/project.pbxproj`

- [ ] **步骤 1：批量更新 project.pbxproj 中的 MACOSX_DEPLOYMENT_TARGET**

将 project.pbxproj 中所有的 `MACOSX_DEPLOYMENT_TARGET = 13.0;` 统一修改为 `MACOSX_DEPLOYMENT_TARGET = 14.0;`。

- [ ] **步骤 2：运行编译验证 ld 14.0 链接警告消除**

运行：`xcodebuild build-for-testing -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | grep "ld: warning"`
预期：此前关于 `building for macOS-13.0, but linking with dylib which was built for newer version 14.0` 的链接警告完全消除。

- [ ] **步骤 3：运行测试验证通过**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：382 个测试 100% 通过。

- [ ] **步骤 4：Commit**

```bash
git add FUnlock.xcodeproj/project.pbxproj
git commit -m "build(xcode): 升级最低部署目标至 macOS 14.0"
```

---

### 任务 2：核心服务与数据模型全面升级至 @Observable 宏

**文件：**
- 修改：`FUnlock/ProfileManager.swift`
- 修改：`FUnlock/DecisionLogger.swift`
- 修改：`FUnlock/SignalDataStore.swift`
- 修改：`FUnlock/FUnManager.swift`
- 修改：`FUnlock/FUn.swift`

- [ ] **步骤 1：ProfileManager 与 DecisionLogger 升级至 @Observable**

1. `FUnlock/ProfileManager.swift`:
```swift
import Foundation
import Observation

@Observable
@MainActor
final class ProfileManager {
    static let shared = ProfileManager()
    var profiles: [Profile] = []
    var activeProfileID: String = "default"
```
2. `FUnlock/DecisionLogger.swift`:
```swift
import Foundation
import Observation

@Observable
@MainActor
final class DecisionLogger {
    static let shared = DecisionLogger()
    private(set) var events: [DecisionEvent] = []
```

- [ ] **步骤 2：SignalDataStore 升级至 @Observable**

`FUnlock/SignalDataStore.swift`:
```swift
import Foundation
import Observation

@Observable
final class SignalDataStore: @unchecked Sendable {
    static let shared = SignalDataStore()
    private(set) var samples: [SignalSample] = []
    var unlockThreshold: Double = -60
    var lockThreshold: Double = -80
```
移除 `@Published` 属性修饰符。

- [ ] **步骤 3：FUnManager 与 FUn 升级至 @Observable**

1. `FUnlock/FUnManager.swift`:
```swift
import Foundation
import Observation

@Observable
@MainActor
final class FUnManager {
    var state = LockScreenState()
    var rssi: Int? = nil
    var connected: Bool = false
    var discoveredDevices: [Device] = []
    var monitoredDeviceName: String? = nil
    var lockRSSI: Int = -80
    var unlockRSSI: Int = -60
    var thresholdVersion: Int = 0
    private(set) var updateState: UpdateDownloader.State = .idle
```
移除所有 `@Published`，移除 `objectWillChange.send()`。
2. `FUnlock/FUn.swift`:
```swift
import Foundation
import Observation
@preconcurrency import CoreBluetooth
import os

@Observable
class FUn: NSObject, @unchecked Sendable, BLEScannerHost {
    var lockRSSI = -80
    var unlockRSSI = -60
```
移除 `: ObservableObject` 与 `@Published`。

- [ ] **步骤 4：运行测试验证通过**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：382 个测试 100% 通过。

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/ProfileManager.swift FUnlock/DecisionLogger.swift FUnlock/SignalDataStore.swift FUnlock/FUnManager.swift FUnlock/FUn.swift
git commit -m "refactor(model): 核心服务与状态模型迁移至 @Observable 宏"
```

---

### 任务 3：DeviceSnapshot 不可变设备模型全链路贯通

**文件：**
- 修改：`FUnlock/FUn.swift`
- 修改：`FUnlock/BLEScanner.swift`
- 修改：`FUnlock/FUnManager.swift`
- 修改：`FUnlock/AppDelegate.swift`
- 修改：`FUnlock/OverviewView.swift`
- 修改：`FUnlock/SidebarView.swift`

- [ ] **步骤 1：升级 FUnDelegate 协议方法为消费 DeviceSnapshot**

在 `FUnlock/FUn.swift` 中：
```swift
@MainActor
protocol FUnDelegate: AnyObject {
    func newDevice(device: DeviceSnapshot)
    func updateDevice(device: DeviceSnapshot)
    func removeDevice(device: DeviceSnapshot)
    func updateRSSI(rssi: Int?, active: Bool)
    func updatePresence(presence: Bool, reason: String)
    func bluetoothPowerWarn()
    func onDeviceApproached()
}
```

- [ ] **步骤 2：BLEScanner 派发不可变快照**

在 `FUnlock/BLEScanner.swift` 中：
在派发 `newDevice`, `updateDevice`, `removeDevice` 前，统一调用 `device.toSnapshot(isMonitored:)` 转为纯值 `DeviceSnapshot` 派发。

- [ ] **步骤 3：FUnManager 与 AppDelegate 接收 DeviceSnapshot**

1. `FUnlock/FUnManager.swift`:
`var discoveredDevices: [DeviceSnapshot] = []`
`onDeviceDiscovered(_ device: DeviceSnapshot)` 等方法直接处理纯值快照，`selectDevice(_ device: DeviceSnapshot)`。
2. `FUnlock/AppDelegate.swift`:
`newDevice(device: DeviceSnapshot)` 等委托方法参数更新。

- [ ] **步骤 4：适配 OverviewView 与 SidebarView**

视图层列表中类型直接使用 `DeviceSnapshot`。

- [ ] **步骤 5：运行测试验证通过**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：382 个测试 100% 通过。

- [ ] **步骤 6：Commit**

```bash
git add FUnlock/FUn.swift FUnlock/BLEScanner.swift FUnlock/FUnManager.swift FUnlock/AppDelegate.swift FUnlock/OverviewView.swift FUnlock/SidebarView.swift
git commit -m "refactor(domain): 设备事件全链路迁移为不可变 DeviceSnapshot 纯值模型"
```

---

### 任务 4：SwiftUI 视图层胶水代码精简（@ObservedObject -> var, @StateObject -> @State）

**文件：**
- 修改：`FUnlock/OverviewView.swift`
- 修改：`FUnlock/SidebarView.swift`
- 修改：`FUnlock/MenuBarPopover.swift`
- 修改：`FUnlock/StatsView.swift`
- 修改：`FUnlock/DiagnosticsView.swift`
- 修改：`FUnlock/ConfigSettingsView.swift`
- 修改：`FUnlock/CalibrationWizardView.swift`
- 修改：`FUnlock/MainWindowView.swift`
- 修改：`FUnlock/NetworkSettingsView.swift`

- [ ] **步骤 1：精简全量视图的属性包装器**

将所有视图中的 `@ObservedObject var manager: FUnManager` 简化为 `var manager: FUnManager`。
将 `@ObservedObject var fun: FUn` 简化为 `var fun: FUn`。
将 `@ObservedObject private var dataStore` 简化为 `private var dataStore`。
将 `@StateObject private var profileManager` 简化为 `@State private var profileManager`。

- [ ] **步骤 2：运行测试验证视图构建与行为**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：382 个测试全部通过。

- [ ] **步骤 3：Commit**

```bash
git add FUnlock/OverviewView.swift FUnlock/SidebarView.swift FUnlock/MenuBarPopover.swift FUnlock/StatsView.swift FUnlock/DiagnosticsView.swift FUnlock/ConfigSettingsView.swift FUnlock/CalibrationWizardView.swift FUnlock/MainWindowView.swift FUnlock/NetworkSettingsView.swift
git commit -m "refactor(ui): 精简 SwiftUI 视图层 Observable 绑定样板代码"
```

---

### 任务 5：全量回归验证与终验

**文件：**
- 全局验证

- [ ] **步骤 1：clean build 验证 0 错误、0 警告、0 ld 告警**

运行：`xcodebuild clean build -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：0 警告，0 错误，BUILD SUCCEEDED。

- [ ] **步骤 2：全量 382 个单元测试验证**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：382 个测试 100% 通过。

- [ ] **步骤 3：单文件行数核查**

运行：`wc -l FUnlock/*.swift | sort -nr | head -n 15`
预期：核心领域文件均受控在规范范围内。

- [ ] **步骤 4：Commit**

```bash
git commit --allow-empty -m "chore(release): Phase 3 现代 Observation 演进与 DeviceSnapshot 闭环验收通过"
```
