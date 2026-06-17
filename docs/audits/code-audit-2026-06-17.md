# FUnlock 代码深度优化审计报告

> 审计日期: 2026-06-17 | 版本: v1.12.2 (build 902) | 代码总行数: ~3,200

---

## 一、性能与能效

### 🔴 高优: IOPMAssertion 系统资源泄漏 (`lowlevel.c:8-16`)

`wakeDisplay()` 在每次调用时创建 `IOPMAssertionID` (`assertionID`、`preventSleepID`)，但**从未调用 `IOPMAssertionRelease()` 释放**。这两个变量声明为 `static`，意味着它们的生命周期是整个进程，每次新的 `IOPMAssertionCreateWithName` 调用会覆盖旧的 assertion ID，旧 assertion 永远不会被释放。

- **建议**: 每次 `wakeDisplay()` 调用结束后主动释放前一次创建的 assertion；或在 `lowlevel.c` 中增加 `releaseDisplayAssertions()` 函数，由 `FUnManager` 在屏幕唤醒后调用。

### 🟡 中优: 显示器唤醒重试循环 (`FUnManager.swift:417-441`)

`startWakeRetry()` 每 0.5 秒调用一次 `wakeDisplay()`，最多 10 次。每次 `wakeDisplay()` 泄漏 assertion，整个重试周期产生 20 个未释放的 IOPMAssertion。此外，`wakeDisplay()` 的第 1 种方式 (`IOPMAssertionDeclareUserActivity`) 被注释认为"不足以唤醒深度休眠的显示器"，徒增开销。

- **建议**: 移除效果不明的第 1/第 3 种唤醒方式，只保留第 2 种（`kIOPMAssertionTypePreventUserIdleDisplaySleep`）；在唤醒完成后释放 assertion。

### 🟡 中优: `FUn.swift` 中 6 个 Timer 在 RunLoop 上运行 (`FUn.swift:117-150`)

`proximityTimer`、`signalTimer`、`heartbeatTimer`、`activeModeTimer`、`connectionTimer`，以及每个 `Device` 的 `scanTimer` 全部挂在 `RunLoop.main` 的 `.common` mode 上。虽然对于蓝牙和外设监控来说是必要的，但 `heartbeatTimer` 每 2 秒触发一次 `getEffectiveRSSI()` 计算，即使在设备已经断开的情况下也可能继续运行（虽然有取消逻辑，但不完整——见下文）。

- **建议**: `heartbeatTimer` 在 `presence == false` 时立即停止（代码已经做了，但需要确保所有退出路径都覆盖）。考虑将心跳间隔从 2s 提高到 3-4s 以降低 CPU 轮询频率。

### 🟡 中优: `print()` 语句未用日志等级控制 (`FUnManager.swift` 等)

生产代码中散布了约 12 个 `print("[SM] ...")` 语句和 9 个 `unlockLog()` 调用（后者写文件 I/O）。每次解锁/锁定事件都会触发多次文件写入，且 `<Debug>` 构建中 print 也会输出到控制台。

- **建议**: 引入 `os.Logger` (macOS 11+) 或编译期条件编译 `#if DEBUG` 控制日志输出。`unlockLog()` 应该在 Release 构建中禁用或缩减。

### 🟢 低优: `Cancellables` 死代码 (`FUnManager.swift:98`, `AppDelegate.swift:142`)

两处声明了 `private var cancellables = Set<AnyCancellable>()`，但全局没有任何 `.store(in: &cancellables)` 调用。这意味着这两个 Combine 集合完全是死代码，占用内存但不做任何事。

- **建议**: 删除或使用 Combine 订阅（当前项目的 Combine 使用只限于 `ObservableObject` 的 `@Published` + `objectWillChange.send()`）。

---

## 二、架构与解耦

### 🟡 中优: BLE 逻辑直接写入了设备发现和 UI 更新 (`FUn.swift:488-550`)

`centralManager(_:didDiscover:advertisementData:rssi:)` 同时做了三件事：BLE 信号处理、设备数据库管理、以及 `DispatchQueue.main.async { delegate?.newDevice(device:) }`。虽然 delegate 模式提供了一层抽象，但 `FUn.swift` 内部耦合了大量设备元信息解析（读取 Bluetooth plist、SQLite 数据库查询 `getLEDeviceInfoFromUUID`、iBeacon 解析），这些都运行在 `bleQueue` 线程上。

- **建议**: 将设备元信息解析 (`getMACFromUUID`、`getNameFromMAC`、iBeacon 解析) 抽离为独立的 `DeviceMetadataResolver` 或类似结构。

### 🟡 中优: `FUn.swift` 既负责 BLE 又负责锁屏决策 (`FUn.swift:375-428`)

`updateMonitoredPeripheral()` 函数 53 行代码同时包含：Kalman 滤波、presence 判断、lock timer 启动/取消、heartbeat 管理、delegate 回调等。虽然这是之前的优化重点，但该函数承接了过多职责，测试性差（当前测试文件 `FUnlockTests.swift` 只覆盖了几个简单场景，无法覆盖锁屏决策路径）。

- **建议**: 将 `updateMonitoredPeripheral` 拆分为 `processSignal(rssi:) -> SignalDecision` 和 `applyDecision(_:)` 两个方法。

### 🟢 低优: 状态机分散在 `FUnManager` 和 `FUn` 之间 (`FUnManager.swift:49-68`, `FUn.swift:119-154`)

`LockScreenState` 定义在 `FUnManager` 中，但 `presence`、`devicePresence` 等 BLE 相关状态定义在 `FUn` 中。`FUn` 通过 `FUnDelegate` 回调和 `FUnManager` 通信，形成了双层的发布-订阅。`LockScreenState` 的整体设计很好（单向聚合），但 `FUn.swift` 仍直接操作一些影响屏幕逻辑的状态。

- **建议**: 将 `FUn.presence` 相关的判断统一移到 `FUnManager` 的状态机中，`FUn` 只负责：信号采集 → 滤波 → 输出 `(rssi, effectiveRSSI)`。

### 🟡 中优: `checkUpdate.swift` 使用全局可变状态 (`checkUpdate.swift:6-8`)

`notified`、`checking`、`lastCheckAt` 都是文件级全局变量，并且 `checkUpdate()` 是由 `FUnManager.onUnlock()` 触发的副作用。这形成了隐式耦合——`FUnManager` 不知道更新检查的实际状态，更新检查也没有生命周期管理（例如退出时取消正在进行的网络请求）。

- **建议**: 将更新检查封装为 `UpdateChecker` 类，作为 `FUnManager` 的依赖注入。

---

## 三、鲁棒性与并发安全

### 🔴 高优: `FUn.swift` 中 `bleQueue` 线程访问 `self` 属性无同步保护 (`FUn.swift:107,681`)

`CBCentralManager` 创建在 `bleQueue` 上，所有 delegate 回调在 `bleQueue` 执行。但 `FUn.swift` 的几乎所有属性（`devices: [UUID: Device]`、`monitoredUUID`、`monitoredPeripheral`、`presence`、`kalmanEstimate`、`latestRSSIs` 等）都是 NSObject 的原子属性，**没有独立的锁保护**。以下是两个关键数据竞争路径：

1. **`updateMonitoredPeripheral` 写入 `latestRSSIs` (bleQueue)** ↔ **读取 (无明确访问者)**
2. **`centralManager.didDiscover` 写入 `devices` (bleQueue)** ↔ **`MenuDashboardView` 读取 `manager.discoveredDevices` (MainActor)**

第一个路径：`updateMonitoredPeripheral` 在 `bleQueue` 执行，修改 `latestRSSIs`、`kalmanEstimate`、`kalmanP`、`presence`、`proximityTimer` 等；但 `heartbeatTimer` 的 block 在 `RunLoop.main` 执行，也在读取 `presence`、`proximityTimer`、`inputMonitor?.isActive`。**虽然没有显式的锁，但由于所有 BLE delegate 回调在 `bleQueue` 串行队列上，而 Timer 回调在 `RunLoop.main` 上，这里实际上有潜在的竞态。**

具体风险点：
- `FUn.swift:338` — `heartbeatTimer`回调在 `RunLoop.main` 上读取 `self.presence`，而 `FUn.swift:388` 在 `bleQueue` 上写入 `self.presence = true`
- `FUn.swift:415` — `RunLoop.main` 上的 `proximityTimer` 回调写入 `self.presence = false`，但 `bleQueue` 上的 `updateMonitoredPeripheral` 同时检查 `self.presence && proximityTimer == nil`

- **建议**: 引入 `os_unfair_lock` 保护共享状态的读写；或用 Swift actor 将 BLE 状态隔离到独立的 actor context 中。

### 🔴 高优: `FUnManager` 中 `@MainActor` 和 `DispatchQueue.main.async` 的冗余与混乱 (`FUnManager.swift:429-440, 480-481`)

`FUnManager` 标注了 `@MainActor`，理论上所有方法都在主 actor 执行。但在 `startWakeRetry()` 的 `Task` 闭包内（417行），又显式使用了 `DispatchQueue.main.async { [weak self] in self?.attemptAutoUnlock() }`（429、438行）。更严重的是 `lockOrSaveScreen()` 在 480-481 行也使用了 `DispatchQueue.main.async { _ = SACLockScreenImmediate() }`。

这种混用的风险：
1. `Task` 闭包继承了 `@MainActor` context → 已在主线程执行 → `DispatchQueue.main.async` 是冗余的（浪费一次 RunLoop 循环）
2. 如果某个 Task 被错误地从非 MainActor 上下文创建，`@MainActor` 的行为取决于 Swift 版本——可能产生编译警告而非运行时保证

- **建议**: 移除 `@MainActor` 类内部不必要的 `DispatchQueue.main.async` 包装；在非 MainActor 上下文（如 `FUn.swift` 的回调）进入 `FUnManager` 时统一使用 `await MainActor.run {}` 或 `Task { @MainActor in }`。

### 🟡 中优: `FUnManager` 中 `Task` 不追踪取消状态 — 多任务叠加 (`FUnManager.swift:161-168, 178-188, 363-382, 417-441`)

多个 `Task` (`wakeTask`、`unlockTask`、`intrudeCheckTask`) 保存为实例变量，在启动新任务前取消旧任务。但在极端场景下可能存在时间窗口问题：

1. 连续快速靠近/远离 → `attemptAutoUnlock()` 被多次快速调用 → `unlockTask?.cancel()` + 新 `unlockTask = Task {...}` → 旧 Task 的 `tryUnlock()` 可能在 `cancel()` 和 `Task.sleep` 结束后仍执行
2. `onSystemWake()` 中直接 `Task { ... }`（无引用保存）— 如果系统快速睡眠/唤醒交替，旧的延时 Task 可能在新的 `state.system = .awake` 之后执行，导致状态不一致

- **建议**: 所有非瞬时的 `Task` 都应保存引用并支持取消检查；`onSystemWake` 中的延时 Task 需要保存为 `systemWakeTask` 属性。

### 🟡 中优: `InputActivityMonitor` 的 C 回调在 IOHID 线程执行 (`AppDelegate.swift:55-61`)

`inputCallback` 是 C 函数指针回调，在 IOHID 系统的内部线程（非主线程）执行。虽然 `didReceiveInput()` 操作只写入 `lastInputTime: Date`，`Date` 的构造是线程安全的，但读取方（`isActive` computed property）可能在任意线程被调用，没有原子性保证。在 ARM 架构上，对 `Date` 的读写不保证是原子的。

- **建议**: 在 `InputActivityMonitor` 中使用 `os_unfair_lock` 保护 `lastInputTime` 的读写；或将 `didReceiveInput()` 调度到 `DispatchQueue.main`。

### 🟡 中优: `FUn.startMonitor()` 对 Timer 的清理不完整 (`FUn.swift:184-221`)

`startMonitor()` 无效化了 `proximityTimer`、`activeModeTimer`，重置了 `signalTimer`，调用了 `cancelHeartbeat()`，但**没有无效化 `connectionTimer`**。如果用户在设备重连过程中快速切换设备，旧的 `connectionTimer` 可能仍然在 60 秒后触发并取消正在进行的连接。

- **建议**: 在 `startMonitor()` 中增加 `connectionTimer?.invalidate(); connectionTimer = nil`。

### 🟡 中优: `FUnManager.cleanup()` 没有清理 `heartbeatTimer` (`FUnManager.swift:659-671`)

`cleanup()` 方法清理了 `proximityTimer`、`signalTimer`、`activeModeTimer`、`connectionTimer`，以及 3 个 Task，但**没有调用 `fun.cancelHeartbeat()` 或手动无效化 `fun.heartbeatTimer`**。应用退出时可能留下悬空的 Timer。

- **建议**: 在 `cleanup()` 中增加 `fun.cancelHeartbeat()` 调用。

### 🟢 低优: `LEDeviceInfo.swift` 中 SQLite 连接无错误恢复 (`LEDeviceInfo.swift:12-24`)

SQLite 数据库只在首次调用时打开一次 (`inited` 标志)，之后即使数据库文件被替换或损坏，也不会重试。虽然这在桌面应用中很少发生，但从健壮性角度，如果 `sqlite3_prepare` 返回错误，应记录日志并尝试重新打开连接。

---

## 四、代码现代化与代码异味 (Code Smell)

### 🔴 高优: `NSUserNotificationCenterDelegate` — 废弃 API (`AppDelegate.swift:189`)

`userNotificationCenter(_:shouldPresent:) -> Bool` 是 `NSUserNotificationCenterDelegate` 的协议方法（macOS 10.8–10.14 的旧 API），而新的 `UNUserNotificationCenterDelegate` 使用 `userNotificationCenter(_:willPresent:) -> UNNotificationPresentationOptions`。

- 行 189 的旧方法永远不会被调用（因为 `UNUserNotificationCenter` 的 delegate 使用新协议）
- 但 `NSUserNotificationCenterDelegate` 的 adoption 可能导致编译警告

- **建议**: 删除行 189 的废弃方法，或明确区分两个协议。

### 🔴 高优: `@NSApplicationMain` 已废弃 (`AppDelegate.swift:127`)

`@NSApplicationMain` 从 Swift 5.3 / Xcode 12 起被 `@main` 替代。当前使用的 `@NSApplicationMain` 在未来 Swift 版本中可能产生编译错误。

- **建议**: 替换为 `@main`。

### 🟡 中优: 强制解包 (`!`) 共发现 5 处 (`FUnManager.swift`)

- `554`: `password.data(using: .utf8)!` — 用户密码始终可编码为 UTF-8，低风险但不符合最佳实践
- `577`: `kCFBooleanTrue!` — CF 常量强制桥接，低风险
- `595`: `String(data: data, encoding: .utf8)!` — Keychain 中存储的数据理论上始终可解码，但一旦损坏就崩溃
- `FUn.swift:30`: `var uuid : UUID!` — 隐式解包可选，Object-C 桥接遗留
- `FUn.swift:50`: `return appleDeviceNames[mod]!` — 字典强制解包

- **建议**: 用 `guard let` 替代所有生产路径上的 `!`；至少为 `595` 行的 keychain 解码提供 `?? "decode error"` 后备。

### 🟡 中优: `frozenDevices` 快照机制存在 TOCTOU 问题 (`MenuDashboardView.swift:122-127`)

3 秒后冻结设备列表的逻辑存在时序风险：`DispatchQueue.main.asyncAfter(deadline: .now() + 3)` 中读取 `manager.discoveredDevices`，但 `manager.discoveredDevices` 可能在这 3 秒内被 BLE delegate 回调修改（`onDeviceDiscovered`、`onDeviceUpdated`、`onDeviceRemoved`）。虽然 `@MainActor` 保护了 `FUnManager`，但 BLE delegate 的回调通过 `FUnDelegate` → `AppDelegate` → `manager.onDeviceDiscovered()` 路径进入，而 `updateDevice` 中又手动调用了 `objectWillChange.send()`。

- **建议**: `frozenDevices` 应该在赋值时深拷贝（`map { ... Device(uuid: $0.uuid) }`），避免后续视图引用可能被修改的对象。

### 🟡 中优: `FUnManager` 无 `deinit` (`FUnManager.swift`)

`FUnManager` 持有多个 `Task` 引用（`wakeTask`、`unlockTask`、`intrudeCheckTask`）和 Combine 订阅（未使用），但没有实现 `deinit` 来取消这些 task。依赖 `applicationWillTerminate` → `cleanup()` 是脆弱的——如果 `FUnManager` 在其他生命周期中被释放（如在 SwiftUI 预览中），task 不会被取消。

- **建议**: 添加 `deinit` 调用 `cleanup()` 或至少取消所有 `Task`。

### 🟢 低优: `@available(macOS 12.0, *)` 与部署目标不一致 (`MenuDashboardView.swift:9`, `CalibrationWizardView.swift:6`)

项目的 `MACOSX_DEPLOYMENT_TARGET = 12.0`，但所有 SwiftUI View 都标注了 `@available(macOS 12.0, *)`。这是冗余的——因为部署目标已经是 12.0，这些 View 不可能在更低版本运行。

- **建议**: 移除 `@available(macOS 12.0, *)` 标注，它们增加了代码噪音。

### 🟢 低优: `checkUpdate.swift` 检查的仓库 URL 是旧的 BLEUnlock (`checkUpdate.swift:20`)

检查更新的 URL 是 `https://api.github.com/repos/ts1/BLEUnlock/releases/latest`（原项目仓库），但当前项目已经 fork 到 `https://gitee.com/fuhahah/bleunlock/releases`。这导致更新检查永远不会发现新版本。

- **建议**: 更新 URL 为 Gitee API 或自建更新检查端点。

### 🟢 低优: `NotificationCenter` addObserver 使用基于 block 的 API 但未存储返回值 (`AppDelegate.swift:305-314`)

`addObserver(forName:object:queue:using:)` 返回一个 `NSObjectProtocol` token，应该在 `applicationWillTerminate` 中通过 `removeObserver(_:)` 移除。虽然当前代码使用了 `removeObserver(self)` 来清理，但没有保存这些 token 意味着无法做精确清理。实际上 `removeObserver(self)` 只对 target-action 模式的观察者有效，对 block-based 的无效。

- **建议**: 修改为使用发布者 (`NotificationCenter.default.publisher(for:)` + `.sink {}`)，并将订阅存入 `cancellables`。

---

## 五、测试覆盖

### 🔴 高优: 测试文件严重滞后 (`FUnlockTests.swift`)

当前的测试文件 `FUnlockTests.swift` 只有 82 行，包含 7 个测试用例，且注释中有 `// EMA:` 字样——说明这些测试是为旧的 EMA 滤波器编写的，尚未更新为 Kalman 滤波。测试完全没有覆盖以下关键路径：

- Kalman 非对称滤波逻辑
- 时间衰减逻辑 (`getEffectiveRSSI()`)
- 状态机的 `canAutoUnlock` 守卫
- Lock intent 转换（manualLock ↔ autoLock）
- 显示器唤醒重试逻辑
- 心跳定时器的锁屏触发
- 信号丢失 3 次超时逻辑

**此外，当前测试直接无法编译通过**——测试中的 `fun.updateMonitoredPeripheral(-60)` 调用了一个参数不匹配的方法（`updateMonitoredPeripheral` 在当前代码中接受 `Int` 参数但不返回值，而测试中把返回值赋值给了 `_`）。

- **建议**: 全面重写测试文件，使用依赖注入使 `FUn` 和 `FUnManager` 的核心逻辑可测试。

---

## 六、汇总

| 等级 | 数量 | 关键项 |
|------|------|--------|
| 🔴 高优 | 5 | IOPMAssertion 泄漏、bleQueue 数据竞争、`@MainActor`/`DispatchQueue` 混用、废弃 API、测试文件不可编译 |
| 🟡 中优 | 10 | 唤醒循环性能、timer 生命周期、解耦不足、Task 取消不完整、强制解包、NotificationCenter 清理 |
| 🟢 低优 | 6 | 死代码、冗余标注、更新 URL 错误、日志控制 |

**总体评价**: 核心的 Kalman 滤波和状态机逻辑设计良好，`LockScreenState` 的聚合模型方向正确。但与 BLE 相关的并发安全性是最大的隐患——`bleQueue` 和 `RunLoop.main` 之间共享状态的竞态条件可能在长期运行后触发难以复现的 bug。建议优先修复高优项目中的并发安全和资源泄漏问题。
