# FUnlock Phase 3: macOS 14+ 现代 Observation 演进与 DeviceSnapshot 闭环设计规格

> 创建日期: 2026-09-24 | 阶段: Phase 3 (现代状态响应与模型闭环) | 目标: 部署目标升至 macOS 14.0，全面迁移至 `@Observable` 宏，将设备状态全面闭环至不可变值类型 `DeviceSnapshot`，保持 382 个单测全绿且 0 警告。

## 1. 目标与背景

在完成 Phase 1（Swift 6 严格并发基线）与 Phase 2（核心领域高内聚解耦）之后，代码库架构已十分清晰。
但目前项目仍受限于 macOS 13.0 最低部署目标，依赖旧版 Combine 的 `ObservableObject` / `@Published` 体系：
1. **粗粒度重绘**: 任何属性变更都会通过 `objectWillChange` 触发视图树大面积重绘。
2. **Xcode 链接警告**: Xcode 16+ 不断提示部署目标 13.0 与 XCTest (14.0) 库版本不匹配的 ld 告警。
3. **并发闭环遗留**: Phase 2 审查指出的 `Device` 引用类型跨 Actor 共享问题，需要在此阶段将 `FUnDelegate` 与 `discoveredDevices` 彻底贯通为 `DeviceSnapshot` 纯值类型。

本阶段作为三步演进的终章，将全面升级至 macOS 14.0，利用 Swift 官方 `import Observation` 彻底消除旧版 Combine 样板代码，并完成不可变数据模型闭环。

## 2. 约束与红线

1. **核心算法红线**: 绝不触碰 `SignalPipeline` 的 Kalman 滤波与自适应衰减数学模型。
2. **安全门控红线**: 密码注入双保险验证、锁屏安全门控（`isSecureToInject`）逻辑严禁削弱。
3. **测试红线**: 全量 382 个单元测试持续 100% 通过（`xcodebuild test`）。
4. **编译红线**: `SWIFT_STRICT_CONCURRENCY = complete` 下保持 0 错误、0 源码警告，同时消除 XCTest ld 14.0 链接警告。
5. **依赖红线**: 0 外部第三方依赖，仅使用 Apple 标准库 `Observation`。

## 3. 架构设计与改动清单

### 3.1 工程配置与部署目标升级
- **文件**: `FUnlock.xcodeproj/project.pbxproj`
- **改动**:
  - 将 Project 与所有 Target 的 `MACOSX_DEPLOYMENT_TARGET` 从 `13.0` 统一修改为 `14.0`。
  - 彻底消除 `ld: warning: building for macOS-13.0, but linking with dylib which was built for newer version 14.0` 告警。

### 3.2 领域与服务模型全面迁移至 `@Observable`
- **文件**:
  - `FUnlock/FUnManager.swift`
  - `FUnlock/ProfileManager.swift`
  - `FUnlock/DecisionLogger.swift`
  - `FUnlock/SignalDataStore.swift`
  - `FUnlock/FUn.swift`
- **改动**:
  - 引入 `import Observation`。
  - 移除 `: ObservableObject` 继承，使用 `@Observable` 宏修饰类（例如 `@Observable @MainActor final class FUnManager`）。
  - 移除所有 `@Published` 属性包装器。
  - 移除 `objectWillChange.send()` 等手动触发代码，利用 Observation 宏提供的属性级精准跟踪。

### 3.3 DeviceSnapshot 不可变设备模型贯通闭环
- **文件**:
  - `FUnlock/FUn.swift` (`FUnDelegate`)
  - `FUnlock/BLEScanner.swift`
  - `FUnlock/FUnManager.swift`
  - `FUnlock/OverviewView.swift`
  - `FUnlock/SidebarView.swift`
  - `FUnlock/AppDelegate.swift`
- **改动**:
  - 协议层：`FUnDelegate` 的方法签名统一升级为消费纯值快照：
    ```swift
    @MainActor
    protocol FUnDelegate: AnyObject {
        func newDevice(device: DeviceSnapshot)
        func updateDevice(device: DeviceSnapshot)
        func removeDevice(device: DeviceSnapshot)
        ...
    }
    ```
  - 派发层：`BLEScanner` 内部将底层 `Device` 通过 `device.toSnapshot(isMonitored:)` 转为不可变 `DeviceSnapshot` 后再行派发，彻底杜绝堆对象跨 Actor 引用。
  - UI 与管理层：`FUnManager.discoveredDevices` 类型改为 `[DeviceSnapshot]`，视图层直接绑定纯值类型。

### 3.4 视图层（SwiftUI）胶水代码精简
- **文件**: 全量 SwiftUI 视图（`OverviewView.swift`, `SidebarView.swift`, `MenuBarPopover.swift`, `StatsView.swift`, `DiagnosticsView.swift`, `ConfigSettingsView.swift`, `CalibrationWizardView.swift`, `MainWindowView.swift`）
- **改动**:
  - 移除 `@ObservedObject`，改为普通的 `var manager: FUnManager`。
  - 局部状态持有由 `@StateObject` 简化为标准 `@State`。

## 4. 验证计划

1. **静态编译与链接检查**:
   ```bash
   xcodebuild clean build -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'
   ```
   检查确保无 ld 14.0 链接告警，0 Swift 编译器警告。
2. **全量单测回归**:
   ```bash
   xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'
   ```
   确保 382 个单元测试全部绿色通过。
