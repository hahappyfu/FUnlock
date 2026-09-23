# FUnlock 审计优化执行计划

> 创建日期: 2026-09-23 | 分支: `refactor/2026-09-23-audit-optimization`

## 全局约束与红线

1. **红线守卫**: 绝不破坏现有 `SignalPipeline` 的 Kalman 滤波与自适应衰减算法。
2. **红线守卫**: 锁屏安全门控（`isSecureCheck`、双重校验）逻辑只能加强不能削弱。
3. **测试基线**: 每步修改后必须保证现存 370 个单元测试 100% 通过（`xcodebuild test -scheme FUnlock`）。
4. **代码规范**: 遵循现有 Swift 风格，避免引入外部第三方依赖。

---

## Task 1: 消除 AppleScript 明文密码注入安全隐患

- **目标**: 消除通过 `/usr/bin/osascript` 命令行参数暴露用户明文锁屏密码的漏洞。
- **文件**: `FUnlock/SystemInteractionService.swift`
- **详细改动**:
  1. 在 `injectWithAppleScript(_:isSecureCheck:)` 中，移除使用 `Process()` 调用 `/usr/bin/osascript -e [script]` 的实现。
  2. 改为使用进程内 `NSAppleScript` 执行：
     ```swift
     var errorInfo: NSDictionary?
     let appleScript = NSAppleScript(source: script)
     let success = appleScript?.executeAndReturnError(&errorInfo) != nil
     ```
  3. 执行前后保持 `isSecureCheck()` 安全检查；
  4. 保证密码不会以任何形式作为外部进程参数传递。
- **验证**:
  - `xcodebuild test -scheme FUnlock` 全部通过；
  - 检查代码中无任何 `Process` 启动 `osascript` 包含密码的调用。

---

## Task 2: 修复 FUnlockStateMachine 与 WiFiMonitor 并发访问隐患

- **目标**: 消除跨线程访问数据竞争，确保 `@MainActor` 隔离正确。
- **文件**: `FUnlock/WiFiMonitor.swift`, `FUnlock/FUnManager.swift`
- **详细改动**:
  1. `FUnlock/WiFiMonitor.swift`:
     - 将 `WiFiMonitor` 类标注为 `@MainActor`；
     - 确保 `pendingCompletions` 数组与 `locationManagerDidChangeAuthorization` 的读写都在 `@MainActor` 上执行，避免 CoreLocation 线程与主线程竞态。
  2. `FUnlock/FUnManager.swift`:
     - `tryUnlock()` 内部与 `stateMachine`（`@MainActor`）的交互明确调度到主线程，例如在调用 `stateMachine.attemptUnlock()`、`stateMachine.handleUnlockFailure()`、`stateMachine.handleUnlockSuccess()` 时确保在 `@MainActor` 下执行，杜绝后台 Task 裸调 MainActor 状态机方法。
- **验证**:
  - 运行 `xcodebuild test -scheme FUnlock -only-testing:FUnlockTests/FUnlockStateMachineTests`；
  - 运行全部单元测试确保无并发崩溃。

---

## Task 3: 日志文件增加滚动截断限制（防无界增长）

- **目标**: 为应用长期运行产生的 4 个日志文件添加 5MB 上限与自动轮转，防止吃满用户磁盘。
- **文件**: `FUnlock/DebugLog.swift`, `FUnlock/FUnlockUtils.swift`, `FUnlock/TelemetryLogger.swift`, `FUnlock/ScriptRunner.swift`
- **详细改动**:
  1. 在 `DebugLog.swift` 或通用工具中提供一个统一的滚动检查函数：若文件大小超过 5MB（`5 * 1024 * 1024` 字节），将原文件重命名为 `.old`（覆盖旧备份）并清空新建。
  2. 在 `DebugLog.log`、`timingLog`、`TelemetryLogger`、`ScriptRunner.logEvent` 写入前调用此滚动检查（或在句柄打开时检查）。
- **验证**:
  - 编写单元测试验证文件超过 5MB 时正确轮转且保留 `.old`；
  - 现有测试 100% 通过。

---

## Task 4: 清理失效蓝牙缓存读取与 ActiveMode 重复代码

- **目标**: 移除已失效的死代码，精简重复的 Timer 重启逻辑。
- **文件**: `FUnlock/FUn.swift`
- **详细改动**:
  1. 删除 `readBluetoothDevice(_:)` 函数（39-51行），因 macOS 12+ 的 `/Library/Preferences/com.apple.Bluetooth.plist` 已无 `CoreBluetoothCache`，该方法恒为 nil。
  2. 在 `FUn.swift:970` 处移除对 `readBluetoothDevice` 的后备调用（保留 `getLEDeviceInfoFromUUID`）。
  3. 重构 `FUn.swift:1106-1132` 的 ActiveMode 启动代码，将其替换为直接调用已经实现的 `restartActiveModeTimer(peripheral: peripheral)`，消除 27 行冗余代码。
- **验证**:
  - `xcodebuild test -scheme FUnlock` 测试全部通过；
  - 静态检查无死代码残留。

---

## Task 5: 移除废弃 Launcher 模块与 Xcode 依赖配置

- **目标**: 彻底移除已废弃的旧版开机自启辅助应用 `Launcher`，简化工程结构。
- **文件**: `Launcher/` 目录, `FUnlock.xcodeproj/project.pbxproj`
- **详细改动**:
  1. 移除 `Launcher/` 源码目录（包括 `AppDelegate.m`, `Info.plist`, `MainMenu.xib` 等）；
  2. 从 `FUnlock.xcodeproj` 中移除 `Launcher` target、相关 scheme 以及主 target 中嵌入 LoginItems 的构建步骤；
  3. 确认主应用使用 `SMAppService.mainApp` 正常构建。
- **验证**:
  - 运行 `xcodebuild -scheme FUnlock build` 成功；
  - 运行 `xcodebuild test -scheme FUnlock` 成功；
  - 产物包结构干净无多余 `Launcher.app`。

---

## Task 6: 全量回归验证与 Release 签名确认

- **目标**: 确保所有优化落地后，370 个单元测试通过，Release 构建与签名完整。
- **文件**: 全局
- **详细改动**:
  1. 运行 `xcodebuild test -scheme FUnlock`；
  2. 运行 `xcodebuild -scheme FUnlock -configuration Release build`；
  3. 验证产物代码签名：`codesign -v build/DerivedData/Build/Products/Release/FUnlock.app`。
- **验证**:
  - 所有测试 0 失败；
  - codesign 退出码 0。
