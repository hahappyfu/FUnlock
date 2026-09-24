# FUnlock Phase 3: macOS 14+ 现代 Observation 演进、全功能保留与 UI 质感升级实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 最低部署目标升至 macOS 14.0，全面引入 `@Observable` 宏替代旧版 Combine，设备模型贯通为不可变纯值 `DeviceSnapshot`，菜单栏 Popover 落地 8 大功能零删减与 Apple 弹簧微动效，保持 382 个单测全绿且 0 编译警告。

**架构：**
1. **工程配置**：`MACOSX_DEPLOYMENT_TARGET = 14.0;`（已完成）。
2. **状态响应**：在 `FUnManager`、`ProfileManager`、`DecisionLogger`、`SignalDataStore`、`FUn` 中全面应用 `@Observable` 宏，删除全部 `@Published` 与 `ObservableObject`。
3. **模型闭环**：`FUnDelegate` 的设备相关回调与 `discoveredDevices` 彻底切换为 `DeviceSnapshot` 纯值类型，杜绝跨线程堆引用。
4. **菜单栏悬浮窗升级**：`MenuBarPopover.swift` 按照苹果 HIG 翻新，**严格 1:1 保留全部 8 项功能**，集成 `.spring` 物理微动效、呼吸光环与 5 格平滑信号柱。
5. **视图层精简与概览增强**：`OverviewView.swift` 增加迟滞安全区可视化渲染，全量视图移除 `@ObservedObject` 改用标准属性。

**技术栈：** macOS 14.0+ SDK、Swift 6 严格并发模式、Swift 官方 Observation 框架、SwiftUI、XCTest。

**规格：** [docs/superpowers/specs/2026-09-24-modern-observation-design.md](docs/superpowers/specs/2026-09-24-modern-observation-design.md)

## 全局约束

- **零功能删减**：菜单栏悬浮窗中的 8 项核心功能（设备卡片、自动解锁开关、打开设置、修改锁屏密码、5态更新、信号统计仪表盘、立即锁屏、退出）**严禁删减任何一项**。
- 绝不改动 `SignalPipeline` 的 Kalman 滤波与自适应衰减数学模型。
- 绝不削弱密码读取与锁屏安全门控（`isSecureToInject`）逻辑。
- 保持全量 382 个单元测试 100% 通过。
- 核心业务单文件行数继续严格控制在 300 行以内。
- 不引入任何外部第三方依赖。

---

### 任务 1：Xcode 工程升级最低部署目标至 macOS 14.0 [已完成]

**文件：**
- 修改：`FUnlock.xcodeproj/project.pbxproj`

- [x] **步骤 1：批量更新 project.pbxproj 中的 MACOSX_DEPLOYMENT_TARGET**
- [x] **步骤 2：运行编译验证 ld 14.0 链接警告消除**
- [x] **步骤 3：运行测试验证通过**
- [x] **步骤 4：Commit**（已提交为 `7d152e0`）

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
移除 `@Published` 属性修饰符与 `ObservableObject` 继承。

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

视图层列表中类型直接使用 `DeviceSnapshot`，消除堆对象跨线程共享。

- [ ] **步骤 5：运行测试验证通过**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：382 个测试 100% 通过。

- [ ] **步骤 6：Commit**

```bash
git add FUnlock/FUn.swift FUnlock/BLEScanner.swift FUnlock/FUnManager.swift FUnlock/AppDelegate.swift FUnlock/OverviewView.swift FUnlock/SidebarView.swift
git commit -m "refactor(domain): 设备事件全链路迁移为不可变 DeviceSnapshot 纯值模型"
```

---

### 任务 4：菜单栏 Popover 现代质感与全功能 1:1 重构

**文件：**
- 修改：`FUnlock/MenuBarPopover.swift`

- [ ] **步骤 1：落地规格约定的 8 项菜单功能（严格 1:1，0 删减）**

对齐规格第 3 节契约：
1. 设备状态英雄卡（设备图标、名称、连接状态、5 格平滑指示柱、实时 dBm 数值、距离描述）
2. 自动解锁总开关（带 Toggle 平滑切换）
3. 打开设置（`⌘,` 快捷键）
4. 修改锁屏密码
5. 检查更新（5 态状态机、下载进度胶囊）
6. 信号统计仪表盘（`⌘S` 快捷键）
7. 立即锁屏（`⌃⌘Q` 快捷键，警告色）
8. 退出 FUnlock（`⌘Q` 快捷键）

- [ ] **步骤 2：注入苹果原生微动效与毛玻璃材质**

1. 弹簧微动效：`withAnimation(.spring(response: 0.32, dampingFraction: 0.78, blendDuration: 0))`。
2. 状态呼吸微光：处于解锁/连接状态时，呼吸圆点带柔和微光动画。
3. 5 格信号柱平滑插值：保留 5 根柱状条的高度与颜色平滑过渡。
4. 材质：`.background(.ultraThinMaterial)` + 半透明高光描边。
5. 按压反馈：菜单项支持 `scaleEffect(isPressed ? 0.985 : 1.0)`。

- [ ] **步骤 3：运行测试验证通过**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：382 个测试全部通过。

- [ ] **步骤 4：Commit**

```bash
git add FUnlock/MenuBarPopover.swift
git commit -m "refactor(ui): 菜单栏 Popover 现代控制中心风格重构并对齐全部 8 项功能"
```

---

### 任务 5：设备概览迟滞安全区增强与全量视图胶水代码精简

**文件：**
- 修改：`FUnlock/OverviewView.swift`
- 修改：`FUnlock/SidebarView.swift`
- 修改：`FUnlock/StatsView.swift`
- 修改：`FUnlock/DiagnosticsView.swift`
- 修改：`FUnlock/ConfigSettingsView.swift`
- 修改：`FUnlock/CalibrationWizardView.swift`
- 修改：`FUnlock/MainWindowView.swift`
- 修改：`FUnlock/NetworkSettingsView.swift`

- [ ] **步骤 1：OverviewView 引入迟滞安全区可视化渲染**

在 `OverviewView.swift` 的双阈值调节区中，可视化渲染“解锁与锁定”之间的安全防误锁缓冲带。

- [ ] **步骤 2：全量视图精简 @ObservedObject 样板代码**

将所有视图中的 `@ObservedObject var manager: FUnManager` 简化为 `var manager: FUnManager`。
将 `@ObservedObject var fun: FUn` 简化为 `var fun: FUn`。
将 `@ObservedObject private var dataStore` 简化为 `private var dataStore`。
将 `@StateObject private var profileManager` 简化为 `@State private var profileManager`。

- [ ] **步骤 3：运行全量测试验证**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：382 个测试全部通过。

- [ ] **步骤 4：Commit**

```bash
git add FUnlock/OverviewView.swift FUnlock/SidebarView.swift FUnlock/StatsView.swift FUnlock/DiagnosticsView.swift FUnlock/ConfigSettingsView.swift FUnlock/CalibrationWizardView.swift FUnlock/MainWindowView.swift FUnlock/NetworkSettingsView.swift
git commit -m "refactor(ui): 落地迟滞安全区可视化并全面精简 Observable 视图绑定"
```

---

### 任务 6：全量回归与终验

**文件：**
- 全局验证

- [ ] **步骤 1：clean build 验证 0 错误、0 源码警告、0 ld 告警**

运行：`xcodebuild clean build -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：0 警告，0 错误，BUILD SUCCEEDED。

- [ ] **步骤 2：全量 382 个单元测试验证**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：382 个测试 100% 通过。

- [ ] **步骤 3：Commit**

```bash
git commit --allow-empty -m "chore(release): Phase 3 现代 Observation 演进与 UI 重构全量验收通过"
```
