# FUnlock Phase 3: macOS 14+ 现代 Observation 演进、全功能保留与 UI 质感升级设计规格

> 创建日期: 2026-09-24 | 阶段: Phase 3 (现代状态响应与 UI 质感升级) | 目标: 部署目标升至 macOS 14.0，全面迁移至 `@Observable` 宏，菜单栏 Popover 与主窗口按照 Apple 原生 HIG 现代化重构，**现有 8 大菜单功能 1:1 完整保留严禁删减**，保持 382 个单测全绿且 0 编译警告。

## 1. 目标与背景

在完成 Phase 1（Swift 6 严格并发基线）与 Phase 2（核心领域高内聚解耦）之后，代码库架构已十分清晰。
本阶段作为三步演进的终章，聚焦于**现代状态响应（Observation）**与**苹果原生质感（Apple Native HIG）UI 重构**：
1. **部署目标升级**: 提升至 macOS 14.0，消除 Xcode 16+ 对 XCTest 的 ld 链接告警。
2. **状态模型升级**: 利用 Swift 官方 `import Observation` 彻底消除旧版 Combine 的 `@Published` 与 `ObservableObject` 粗粒度刷新。
3. **并发模型闭环**: 将 `FUnDelegate` 的设备回调与 `discoveredDevices` 彻底贯通为不可变纯值类型 `DeviceSnapshot`，从根本上杜绝堆对象跨 Actor 引用。
4. **UI 质感升级与零功能删减**: 全面翻新状态栏菜单（`MenuBarPopover.swift`）与主设置窗口，采用现代毛玻璃材质与苹果弹簧物理动效，**100% 严格保留原有的全部功能与快捷键**。

## 2. 约束与红线

1. **功能零删减红线**: 菜单栏悬浮窗中的 8 项核心功能（设备状态卡、自动解锁总开关、打开设置、修改锁屏密码、5态检查更新、信号统计仪表盘、立即锁屏、退出应用）**严禁删减任何一项**。
2. **算法与安全红线**: 绝不触碰 `SignalPipeline` 的 Kalman 滤波与自适应衰减数学模型；绝不削弱密码注入与锁屏门控（`isSecureToInject`）逻辑。
3. **测试红线**: 全量 382 个单元测试持续 100% 通过（`xcodebuild test`）。
4. **编译红线**: `SWIFT_STRICT_CONCURRENCY = complete` 下保持 0 错误、0 源码警告，同时消除 XCTest ld 14.0 链接警告。
5. **依赖红线**: 0 外部第三方依赖，仅使用 Apple 标准库 `Observation` 与 `SwiftUI` 原生控件。

## 3. 功能保留契约（对账清单）

重构后的 UI 必须逐一承载以下功能项，行为与快捷键 1:1 对齐：

| # | 功能项 | 对应代码 / 状态机 | UI 表现形式 | 快捷键 | 判定标准 |
|---|---|---|---|---|---|
| **1** | **设备状态英雄卡** | `FUnManager.monitoredDeviceName`、`manager.connected`、`fun.signalSnapshot()` | 顶部大卡片，展示设备图标（根据名称自动匹配 SF Symbol）、设备名、已解锁/锁定/未连接状态胶囊、**5 格平滑信号指示柱**、实时有效 RSSI 数值（如 `-58 dBm`）及近/较近/远语义描述 | - | 动态刷新，支持失联 3 次超时后显示 `-- dBm` |
| **2** | **自动解锁总开关** | `@AppStorage("enabled")` | 独立卡片 Toggle 控件，开启为绿色，暂停为灰色，平滑过渡 | - | 即时生效，状态持久化到 UserDefaults |
| **3** | **打开设置...** | `MenuBarAction.openSettings` | 菜单项，激活主设置窗口 | `⌘,` | 窗口居中前台激活 |
| **4** | **修改锁屏密码...** | `MenuBarAction.changePassword` | 菜单项，弹出密码输入与钥匙串保存弹窗 | - | 独立钥匙图标，操作完成后持久化至 Keychain |
| **5** | **检查更新** | 5 态状态机：`idle`、`checking`（转圈）、`downloading(progress)`（百分比胶囊）、`latest`（对勾）、`failed` | 动态文字与图标，下载时行尾高亮显示下载百分比 | - | 支持自动后台下载与手动点击触发 |
| **6** | **信号统计仪表盘** | `MenuBarAction.showStats` | 菜单项，打开波形统计仪表盘 | `⌘S` | 快捷键响应，图表展示 |
| **7** | **立即锁屏** | `MenuBarAction.lockNow` | 警告色菜单项，调用 `SystemInteractionService.shared.lockOrSaveScreen` | `⌃⌘Q` | 立即触发系统锁屏或屏幕保护 |
| **8** | **退出 FUnlock** | `MenuBarAction.quit` | 底部危险区菜单项，执行清理并调用 `NSApp.terminate` | `⌘Q` | 退出前执行 cleanup 释放 Assertion 与 Timer |

## 4. 苹果原生级（Apple Native HIG）动效与微交互规范

1. **弹簧物理微动效（Spring Physics）**:
   - 交互动效遵循系统自然物理规律，采用苹果标准弹簧曲线：
     `withAnimation(.spring(response: 0.32, dampingFraction: 0.78, blendDuration: 0))`
   - 菜单项与按钮增加按压微缩放物理反馈（`scaleEffect(isPressed ? 0.985 : 1.0)`）。
2. **状态呼吸微光（Status Breathing Glow）**:
   - 处于解锁/连接状态时，状态指示圆点带有 1.8 秒周期的柔和径向微光（`opacity: 0.7 -> 1.0, scale: 0.95 -> 1.15`），提供生命感；断开时柔和褪为静止灰色。
3. **5 格信号柱插值（Signal Interpolation）**:
   - 继承原版 5 格信号判据算法（按 `effectiveRSSI` 精确映射为 1-5 格），高度与颜色过渡平滑插值，避免频繁跳动闪烁。
4. **材质与分层（Material Layering）**:
   - 菜单栏悬浮窗背景采用系统原生 `.background(.ultraThinMaterial)`，外层增加 `0.5pt` 半透明高光描边（`StrokeBorder(Color.white.opacity(0.18))`），确保在浅色与深色桌面背景下均清晰通透。

## 5. 架构改动清单

### 5.1 部署目标升级（已由 commit 7d152e0 完成）
- **文件**: `FUnlock.xcodeproj/project.pbxproj`
- **改动**: `MACOSX_DEPLOYMENT_TARGET = 14.0;`，消除全部 ld 14.0 链接警告。

### 5.2 核心服务与状态模型迁移至 `@Observable` 宏
- **文件**:
  - `FUnlock/FUnManager.swift`
  - `FUnlock/ProfileManager.swift`
  - `FUnlock/DecisionLogger.swift`
  - `FUnlock/SignalDataStore.swift`
  - `FUnlock/FUn.swift`
- **改动**:
  - 引入 `import Observation`。
  - 移除 `: ObservableObject`，使用 `@Observable` 宏修饰类。
  - 移除所有 `@Published` 属性包装器。
  - 移除 `objectWillChange.send()`。

### 5.3 DeviceSnapshot 不可变设备模型全链路贯通
- **文件**:
  - `FUnlock/FUn.swift` (`FUnDelegate`)
  - `FUnlock/BLEScanner.swift`
  - `FUnlock/FUnManager.swift`
  - `FUnlock/AppDelegate.swift`
  - `FUnlock/OverviewView.swift`
  - `FUnlock/SidebarView.swift`
- **改动**:
  - `FUnDelegate` 签名升级为接收纯值 `DeviceSnapshot`。
  - `BLEScanner` 在派发前通过 `device.toSnapshot(isMonitored:)` 派发快照。
  - `FUnManager.discoveredDevices` 类型升级为 `[DeviceSnapshot]`。

### 5.4 菜单栏 Popover 现代质感与全功能重构
- **文件**: `FUnlock/MenuBarPopover.swift`
- **改动**: 落地第 3 节与第 4 节规范，完整实现 8 大功能卡片化重构，接入弹簧动效。

### 5.5 主窗口、设备概览（迟滞安全带）与 SwiftUI 胶水代码精简
- **文件**: 全量 SwiftUI 视图（`OverviewView.swift`, `SidebarView.swift`, `MainWindowView.swift`, `StatsView.swift` 等）
- **改动**:
  - 视图中 `@ObservedObject` 降为标准属性，`@StateObject` 降为 `@State`。
  - `OverviewView` 引入“双阈值迟滞安全缓冲带”直观可视化渲染。

## 6. 验证计划

1. **静态编译与警告检查**:
   ```bash
   xcodebuild clean build -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'
   ```
   输出必须为 0 错误、0 警告。
2. **全量单测回归**:
   ```bash
   xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS'
   ```
   全量 382 个单元测试持续 100% 通过。
