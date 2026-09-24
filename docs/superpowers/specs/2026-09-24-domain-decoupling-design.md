# FUnlock Phase 2: 核心领域解耦与千行巨类拆解设计规格

> 创建日期: 2026-09-24 | 阶段: Phase 2 (架构解耦) | 目标: 拆解 `FUn.swift` (1160行) 与 `FUnManager.swift` (934行)，所有单文件收敛在 300 行内，引入纯值类型 `DeviceSnapshot`，保持 382 个单元测试 100% 通过。

## 1. 目标与背景

在 Phase 1 中，我们建立起了 Swift 6 严格并发基线（`SWIFT_STRICT_CONCURRENCY = complete`）。
然而，`FUn.swift` 和 `FUnManager.swift` 依然是承担了过多职责的上帝类（God Objects）：
- `FUn.swift` 混杂了底层 CoreBluetooth 硬件驱动、RSSI 滤波平滑算法、阶梯唤醒与防抖计时器、设备实体与 iBeacon 解析。
- `FUnManager.swift` 混杂了 SwiftUI 观察状态发布、系统级睡眠/锁屏事件分发、复杂的锁屏门控与密码注入流水线、媒体控制与应用更新。

本阶段目标是将上述职责彻底解耦为高内聚、职责单一的独立组件，同时将设备跨 Actor 传递彻底升级为不可变纯值类型 `DeviceSnapshot`，从根本上杜绝引用类型跨线程读写竞态。

## 2. 约束与红线

1. **算法红线**: 绝不修改 `SignalPipeline` 的 Kalman 滤波与自适应衰减数学模型。
2. **安全红线**: 密码注入双重验证、锁屏安全门控（`isSecureToInject`）逻辑严禁削弱。
3. **测试红线**: 保持现有 382 个单元测试 100% 通过，不破坏对外 API 兼容性。
4. **代码规模**: 拆解后的新建模块单文件代码行数必须严格控制在 300 行以内。

## 3. 架构设计与模块划分

```
                     ┌────────────────────────┐
                     │      FUnManager        │ (瘦身至 ~250 行，负责 SwiftUI @Published 状态)
                     └────┬──────────────┬────┘
                          │              │
        ┌─────────────────┴─┐          ┌─┴──────────────────┐
        │ UnlockOrchestrator│          │        FUn         │ (瘦身至 ~250 行，BLE 与信号协调层)
        └───────────────────┘          └─────┬───────────┬──┘
         (解锁门控/密码注入流水线)               │           │
                               ┌─────────────┴─┐       ┌─┴────────────────────────┐
                               │  BLEScanner   │       │  SignalHysteresisEngine  │
                               └───────────────┘       └──────────────────────────┘
                              (CoreBluetooth 驱动)     (阶梯唤醒/超时迟滞纯逻辑引擎)
```

### 3.1 领域模型独立与值类型化
- **文件**: `FUnlock/DeviceSnapshot.swift`（新建，约 60 行）
  ```swift
  public struct DeviceSnapshot: Sendable, Identifiable, Hashable, Equatable {
      public let id: UUID
      public let uuid: UUID
      public let name: String
      public let rssi: Int
      public let manufacture: String?
      public let model: String?
      public let isMonitored: Bool
  }
  ```
  UI 视图（`OverviewView`、`SidebarView`、`MenuBarPopover`）只消费 `DeviceSnapshot`，消除堆对象跨线程竞态。
- **文件**: `FUnlock/Device.swift`（新建，约 120 行）
  从 `FUn.swift` 中迁出 `class Device: NSObject` 及 `appleDeviceNames` 查找逻辑，作为 CoreBluetooth 私有扫描实体，并提供生成不可变快照的方法：
  ```swift
  extension Device {
      func toSnapshot(isMonitored: Bool) -> DeviceSnapshot { ... }
  }
  ```

### 3.2 BLE 硬件与信号引擎拆解（拆解原 `FUn.swift`）
- **文件**: `FUnlock/SignalHysteresisEngine.swift`（新建，约 180 行）
  - 纯函数与无状态/单锁逻辑计算器。
  - 职责：
    1. 阶梯唤醒偏移计算（`clampOffset`、`offsetSetting`）。
    2. 靠近（Approach）与远离（Away）判定迟滞条件。
    3. 动态锁屏超时判定（`lockTimeout(slope:base:)`、`isNearThreshold`）。
    4. 锁冷却缓冲期（`isWithinLockGracePeriod`）。
  - 完全脱离 CoreBluetooth 依赖，可直接编写纯单测验证边界。
- **文件**: `FUnlock/BLEScanner.swift`（新建，约 260 行）
  - 纯粹的 CoreBluetooth 硬件驱动。
  - 严格隔离在 `bleQueue` 串行队列上运行。
  - 职责：`CBCentralManager` 初始化、广播发现解析、主动/被动轮询连接、RSSI 定时读取。
- **文件**: `FUnlock/FUn.swift`（瘦身至约 250 行）
  - 作为对外 Facade / 协调器。
  - 统一协调 `BLEScanner` 采集的原始信号与 `SignalHysteresisEngine` 的决策，保持现存外部调用点（如 `startMonitor`, `setLockRSSI` 等）100% 兼容。

### 3.3 解锁门控与密码注入流水线拆解（拆解原 `FUnManager.swift`）
- **文件**: `FUnlock/UnlockOrchestrator.swift`（新建，约 220 行）
  - 标注 `@MainActor`，完全隔离在主线程运行。
  - 职责：
    1. 前置门控判定（屏幕是否锁定、是否处于冷却、状态机是否允许）。
    2. 安全密码读取（`SecurityService` 交互与冷启动拦截）。
    3. 密码注入执行（`SystemInteractionService` AppleScript / CGEvent 注入）。
    4. 结果双重校验与异常检测（`verifyUnlock`、`recordUnlockSuccess/Failure`）。
- **文件**: `FUnlock/FUnManager.swift`（瘦身至约 250 行）
  - 职责纯粹化：
    1. 持有 SwiftUI 视图绑定的 `@Published` 属性（`discoveredDevices: [DeviceSnapshot]`, `rssi`, `connected`, `state`）。
    2. 响应系统生命周期通知（睡眠、唤醒、锁屏、屏保），委托 `UnlockOrchestrator` 执行解锁。
    3. 处理用户手势交互（选择设备、解除绑定、阈值调节）。

## 4. 工程与测试迁移策略

1. **新建文件加入 Xcode 项目**:
   `DeviceSnapshot.swift`、`Device.swift`、`SignalHysteresisEngine.swift`、`BLEScanner.swift`、`UnlockOrchestrator.swift` 必须规范加入 `FUnlock.xcodeproj` 的 `Compile Sources` 阶段。
2. **渐进式替换，保持测试全绿**:
   每拆出一个新模块，原类使用委托/内嵌实例包装，先跑通 382 个单元测试，再继续下一步。
3. **消除上帝对象测试依赖**:
   测试中针对迟滞逻辑的单测无需再实例化庞大的 `FUn`，直接针对轻量 `SignalHysteresisEngine` 测试。

## 5. 验收标准

1. `wc -l FUnlock/*.swift` 检查：所有核心业务单文件行数均降至 300 行以内。
2. 全量 382 个单元测试持续 100% 通过（`xcodebuild test`）。
3. 严格并发持续保持 0 错误、0 警告（`SWIFT_STRICT_CONCURRENCY = complete`）。
