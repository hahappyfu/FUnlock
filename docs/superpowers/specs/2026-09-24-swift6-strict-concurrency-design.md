# FUnlock Phase 1: Swift 6 严格并发升级设计规格

> 创建日期: 2026-09-24 | 阶段: Phase 1 (严格并发基线) | 目标: `SWIFT_STRICT_CONCURRENCY = complete` 零警告零错误

## 1. 目标与背景

FUnlock 包含大量跨线程操作（CoreBluetooth 异步代理、IOKit 事件、系统锁屏与钥匙串访问、SwiftUI 状态发布）。目前工程运行在 Swift 5 模式，未开启严格并发检查。

本阶段作为三步演进的第一步，目标是在不改变任何业务逻辑的前提下，开启 `SWIFT_STRICT_CONCURRENCY = complete` 并消除所有并发警告，将数据竞态与跨线程共享状态隐患在编译期收敛，为 Phase 2（拆解千行巨类）奠定类型系统保障。

## 2. 约束与红线

1. **零业务破坏**: 绝不修改蓝牙扫描、Kalman 滤波衰减、密码注入与锁屏门控的核心算法与逻辑。
2. **测试基线**: 全量 381 个单元测试必须持续 100% 通过（`xcodebuild test -scheme FUnlock`）。
3. **零外部依赖**: 仅使用 Swift 5.10 / Swift 6 标准库并发特性（`Sendable`, `@MainActor`, `actor`, `OSAllocatedUnfairLock` / `@unchecked Sendable` 保护）。

## 3. 架构设计与改动清单

### 3.1 工程配置调整
- **文件**: `FUnlock.xcodeproj/project.pbxproj`
- **改动**: 为 Debug 与 Release 构建配置增加 `SWIFT_STRICT_CONCURRENCY = complete`。

### 3.2 协议与跨 Actor 隔离规范化
- **文件**: `FUnlock/FUn.swift`, `FUnlock/AppDelegate.swift`
- **改动**:
  - `FUnDelegate` 标注 `@MainActor protocol FUnDelegate: AnyObject`。由于 `FUnDelegate` 的所有回调均涉及 UI、通知或主状态机（`manager.onDeviceDiscovered` 等），在协议层标注 `@MainActor`，使得 `AppDelegate` 的实现自然隔离在主线程，消除 ConformanceIsolation 警告。
  - 在 `FUn.swift` 中，向代理派发事件统一通过 `Task { @MainActor in self.delegate?.xxx() }` 或已有主线程调度机制分发。

### 3.3 全局共享变量治理
- **文件**: `FUnlock/FUn.swift`, `FUnlock/DebugLog.swift`, `FUnlock/FUnlockUtils.swift`
- **改动**:
  - 将 `FUn.swift` 中的散落全局 `CBUUID`（`DeviceInformation`, `ManufacturerName`, `ModelName`, `ExposureNotification`）放入不可变枚举 `enum BLEUUIDs` 作为静态常量，或补齐 `@preconcurrency import CoreBluetooth`。
  - 将 `bleLogLastTime`（Dictionary）与节流锁打包为线程安全的不可变状态或受保护的隔离单元。
  - 将 `DebugLog.testLogDirectory` 与 `DebugLog.maxFileSize` 标注 `@MainActor` 或改为带锁保护的安全属性。

### 3.4 服务与单例的 Sendable 规范化
- **文件**: `FUnlock/SystemInteractionService.swift`, `FUnlock/SecurityService.swift`, `FUnlock/ProfileManager.swift`, `FUnlock/SignalDataStore.swift`, `FUnlock/ScriptRunner.swift`, `FUnlock/TelemetryLogger.swift`, `FUnlock/UpdateDownloader.swift`
- **改动**:
  - **MainActor 隔离服务**: `SystemInteractionService`、`SecurityService`、`ProfileManager` 标注 `@MainActor`，其 `static let shared` 自然享有主线程并发安全。
  - **后台数据服务**: `SignalDataStore`、`ScriptRunner`、`TelemetryLogger` 声明为 `final class`，内部通过已有的锁保护状态，并显式标注 `final class ...: @unchecked Sendable`，附带线程安全保证说明。
  - **网络与下载器**: `UpdateDownloader` 声明为 `final class`，状态回调闭包标注 `@Sendable`，闭包调用统一收敛到安全隔离域。

### 3.5 UNUserNotificationCenterDelegate 签名修正
- **文件**: `FUnlock/AppDelegate.swift`
- **改动**: 修正 `userNotificationCenter(_:willPresent:)` 的参数签名与属性标记，使其完全匹配系统协议原型，消除 nearly matches 警告。

## 4. 验证计划

1. **静态编译检查**:
   ```bash
   xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'
   ```
   输出中不得包含任何 Swift Concurrency 相关的 warning 或 error。
2. **单测回归**:
   ```bash
   xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'
   ```
   确认全量 381 个测试 100% 通过。
