# FUnlock Phase 2: 核心领域解耦与千行巨类拆解实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 将 `FUn.swift`（1160行）和 `FUnManager.swift`（934行）拆解为职责内聚、行数均在 300 行以内的单一职责模块，引入不可变纯值类型 `DeviceSnapshot`，保持 382 个单元测试持续通过且 0 编译器告警。

**架构：**
1. **模型层**：抽出 `Device.swift`（CoreBluetooth 底层实体）与 `DeviceSnapshot.swift`（不可变对外纯值类型）。
2. **信号与算法层**：抽出 `SignalHysteresisEngine.swift`，承担阶梯唤醒偏移、动态超时与迟滞判定纯逻辑。
3. **硬件驱动层**：抽出 `BLEScanner.swift`，在 `bleQueue` 串行执行，封装 CoreBluetooth 扫描与连接；`FUn.swift` 瘦身为协调 Facade。
4. **业务流水线层**：抽出 `@MainActor` 隔离的 `UnlockOrchestrator.swift`，封装锁屏门控、密码注入与双保险校验；`FUnManager.swift` 瘦身为纯粹的 SwiftUI 状态中枢。

**技术栈：** Swift 6 严格并发模式、CoreBluetooth、XCTest、Xcode PBX 自动化。

**规格：** [docs/superpowers/specs/2026-09-24-domain-decoupling-design.md](docs/superpowers/specs/2026-09-24-domain-decoupling-design.md)

## 全局约束

- 绝不改动 `SignalPipeline` 的 Kalman 滤波与自适应衰减算法。
- 绝不削弱密码读取与锁屏安全门控（`isSecureToInject`）逻辑。
- 保持全量 382 个单元测试 100% 通过。
- 新建与重构后的核心单文件行数严格控制在 300 行以内。
- 不引入任何外部第三方依赖。

---

### 任务 1：抽取独立领域模型 Device.swift 与不可变快照 DeviceSnapshot.swift

**文件：**
- 创建：`FUnlock/DeviceSnapshot.swift`
- 创建：`FUnlock/Device.swift`
- 修改：`FUnlock/FUn.swift:53-117`
- 修改：`FUnlock.xcodeproj/project.pbxproj`

- [ ] **步骤 1：创建 DeviceSnapshot.swift**

定义不可变纯值类型 `DeviceSnapshot`:
```swift
import Foundation

public struct DeviceSnapshot: Sendable, Identifiable, Hashable, Equatable {
    public let id: UUID
    public let uuid: UUID
    public let name: String
    public let rssi: Int
    public let manufacture: String?
    public let model: String?
    public let isMonitored: Bool

    public init(id: UUID, uuid: UUID, name: String, rssi: Int, manufacture: String? = nil, model: String? = nil, isMonitored: Bool = false) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.rssi = rssi
        self.manufacture = manufacture
        self.model = model
        self.isMonitored = isMonitored
    }
}
```

- [ ] **步骤 2：创建 Device.swift 并从 FUn.swift 迁出 Device 类**

创建 `FUnlock/Device.swift`，包含 `class Device: NSObject`、属性、`appleDeviceNames` 映射与 iBeacon 解析，并增加 `toSnapshot(isMonitored:) -> DeviceSnapshot` 方法。
在 `FUn.swift` 中删除原 `Device` 定义（第 53-117 行）。

- [ ] **步骤 3：在 project.pbxproj 中注册新文件**

将 `DeviceSnapshot.swift` 与 `Device.swift` 注册到 PBXBuildFile、PBXFileReference 以及 Sources 构建阶段。

- [ ] **步骤 4：运行测试验证通过**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：382 个测试 100% 通过。

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/DeviceSnapshot.swift FUnlock/Device.swift FUnlock/FUn.swift FUnlock.xcodeproj/project.pbxproj
git commit -m "refactor(domain): 抽取独立 Device 与 DeviceSnapshot 领域模型"
```

---

### 任务 2：抽取纯逻辑迟滞与阶梯唤醒引擎 SignalHysteresisEngine.swift

**文件：**
- 创建：`FUnlock/SignalHysteresisEngine.swift`
- 修改：`FUnlock/FUn.swift`
- 修改：`FUnlock.xcodeproj/project.pbxproj`

- [ ] **步骤 1：创建 SignalHysteresisEngine.swift**

实现无状态 / 纯逻辑的迟滞判定器：
1. 阶梯唤醒偏移量钳制与读取：`clampOffset(_:)`, `offsetSetting(_:default:)`
2. 动态锁屏超时判定：`lockTimeout(slope:base:)`、`isNearThreshold(_:threshold:)`
3. 锁冷静期检查：`isWithinLockGracePeriod(lastUnlockTime:gracePeriod:now:)`
4. 靠近与离开信号判定：`checkProximity(rssi:effectiveRSSI:unlockRSSI:lockRSSI:)`

- [ ] **步骤 2：在 FUn.swift 中委托 SignalHysteresisEngine**

在 `FUn.swift` 中移除重复算法实现，改为调用 `SignalHysteresisEngine` 静态方法，对外保留原有类方法与实例方法签名，保持向下兼容。

- [ ] **步骤 3：将 SignalHysteresisEngine.swift 加入 Xcode 工程**

更新 `FUnlock.xcodeproj/project.pbxproj` 包含新文件。

- [ ] **步骤 4：运行测试验证通过**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：涉及阶梯唤醒与防抖的 382 个测试全绿。

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/SignalHysteresisEngine.swift FUnlock/FUn.swift FUnlock.xcodeproj/project.pbxproj
git commit -m "refactor(signal): 抽取独立纯逻辑 SignalHysteresisEngine 迟滞引擎"
```

---

### 任务 3：抽取底层蓝牙硬件驱动 BLEScanner.swift 并瘦身 FUn.swift

**文件：**
- 创建：`FUnlock/BLEScanner.swift`
- 修改：`FUnlock/FUn.swift`
- 修改：`FUnlock.xcodeproj/project.pbxproj`

- [ ] **步骤 1：创建 BLEScanner.swift**

将 CoreBluetooth 代理与硬件生命周期迁入 `BLEScanner`:
1. `CBCentralManager` 初始化与状态监控（`centralManagerDidUpdateState`）。
2. 设备广播发现与解析（`didDiscover`）。
3. 外设连接、断开与 RSSI 读取轮询（`CBPeripheralDelegate`、`activeModeTimer`）。
4. 严格串行运行于 `bleQueue`。

- [ ] **步骤 2：重构 FUn.swift 为轻量协调 Facade**

`FUn.swift` 瘦身为协调层（<300行）：
持有 `BLEScanner`、`SignalPipeline` 与 `SignalHysteresisEngine`，向外部保持原有统一接口。

- [ ] **步骤 3：更新 project.pbxproj 并运行全量测试**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：382 个测试 100% 通过。

- [ ] **步骤 4：Commit**

```bash
git add FUnlock/BLEScanner.swift FUnlock/FUn.swift FUnlock.xcodeproj/project.pbxproj
git commit -m "refactor(ble): 抽取 BLEScanner 硬件驱动并将 FUn 瘦身为协调器"
```

---

### 任务 4：抽取解锁流水线协调器 UnlockOrchestrator.swift 并瘦身 FUnManager.swift

**文件：**
- 创建：`FUnlock/UnlockOrchestrator.swift`
- 修改：`FUnlock/FUnManager.swift`
- 修改：`FUnlock.xcodeproj/project.pbxproj`

- [ ] **步骤 1：创建 UnlockOrchestrator.swift**

标注 `@MainActor`，迁入完整解锁流水线：
1. `guardFetchPassword()`: 屏幕锁定前置检查、状态机降级判断、冷却检查、密码读取、注入前安全校验。
2. `performInjectionAndVerify(password:)`: AppleScript / CGEvent 密码注入、双保险验证、成功/失败回调。
3. 唤醒重试机制：`startWakeRetry()`。

- [ ] **步骤 2：重构 FUnManager.swift 瘦身为状态中心**

`FUnManager.swift` 瘦身至 300 行以内：
仅保留 SwiftUI `@Published` 属性发布、系统通知监听分发，以及委托 `UnlockOrchestrator` 执行解锁。

- [ ] **步骤 3：更新 project.pbxproj 并运行全量测试**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：382 个测试全部通过。

- [ ] **步骤 4：Commit**

```bash
git add FUnlock/UnlockOrchestrator.swift FUnlock/FUnManager.swift FUnlock.xcodeproj/project.pbxproj
git commit -m "refactor(unlock): 抽取 UnlockOrchestrator 解锁流水线并将 FUnManager 瘦身为状态中枢"
```

---

### 任务 5：全量代码规模验收与全回归审查

**文件：**
- 全局扫描与测试

- [ ] **步骤 1：执行文件行数检查**

运行：`wc -l FUnlock/FUn.swift FUnlock/FUnManager.swift FUnlock/BLEScanner.swift FUnlock/UnlockOrchestrator.swift FUnlock/SignalHysteresisEngine.swift FUnlock/Device.swift FUnlock/DeviceSnapshot.swift`
预期：所有单文件行数均在 300 行以内。

- [ ] **步骤 2：执行严格并发零警告验证**

运行：`xcodebuild clean build -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：0 警告，0 错误。

- [ ] **步骤 3：执行全量 382 个单元测试验证**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'`
预期：382 个测试 100% 通过。

- [ ] **步骤 4：Commit**

```bash
git commit --allow-empty -m "chore(release): Phase 2 核心领域解耦全量验收通过"
```
