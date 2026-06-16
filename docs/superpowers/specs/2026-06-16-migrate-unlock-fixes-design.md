# BLE Unlock 修复移植到 FUnlock

## 背景

BLEUnlock 项目经过调试修复了以下关键问题：
1. `wakeDisplay()` 无法唤醒深度休眠的显示器（macOS Sequoia）
2. `CGEvent.post(.cghidEventTap)` 无法到达锁屏（macOS Sequoia）
3. `AXIsProcessTrusted()` 对 agent 应用返回 false（TCC 签名问题）
4. `startWakeRetry` 依赖 `screensDidWakeNotification` 但 `wakeDisplay()` 不触发该通知
5. Return 键码 52（小键盘 Enter）应为 36（主键盘 Return）

## 迁移范围

仅移植 3 个文件的差异，保留 FUnlock 现有的 BLE.swift（Kalman 滤波）和其他实现。

### 1. `lowlevel.c` — 增强显示器唤醒

在 `wakeDisplay()` 中加入三种唤醒方式：
- `IOPMAssertionDeclareUserActivity`（原有）
- `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep)` （强断言）
- IORegistry `IODisplayWrangler` 直接唤醒

### 2. `BluetoothManager.swift` — 4 处修改

- 新增 `unlockLog()` 诊断函数
- `attemptAutoUnlock`：加 `ax` 检查 + guard 日志
- `startWakeRetry`：加 `isScreenLocked()` 检测 + `attemptAutoUnlock()` 调用
- `fakeKeyStrokes`：`.cgSessionEventTap` + 键码 36 + AppleScript 备选

### 3. `AppDelegate.swift` — 1 处修改

- Accessibility 启动检查 + `requestAccessibilityIfNeeded` 改为打开系统设置

### 不改动

BLE.swift、MenuDashboardView.swift、CalibrationWizardView.swift 等所有其他文件。

## 验证

- 构建 Release 版本
- 部署到 /Applications/FUnlock.app
- 测试：走远触发锁屏 → 走近触发显示器唤醒 → 自动解锁
