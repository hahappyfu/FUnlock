# BLE → FUn 全面重命名 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将项目中所有 BLE/BLEUnlock 命名（文件、目录、代码符号、Xcode 配置）统一替换为 FUn/FUnlock 格式。

**Architecture:** 先改文件/目录名 → 再改 Xcode 项目配置（pbxproj）→ 最后改 Swift 代码符号。按依赖顺序逐层替换，确保每步可编译。

**Tech Stack:** Swift, Xcode, CoreBluetooth

---

## 重命名映射总览

### 文件/目录重命名

| 原路径 | 新路径 |
|--------|--------|
| `BLEUnlock/` (目录) | `FUnlock/` |
| `BLEUnlock/BLE.swift` | `FUnlock/FUn.swift` |
| `BLEUnlock/BluetoothManager.swift` | `FUnlock/FUnManager.swift` |
| `BLEUnlock/BLEUnlock.entitlements` | `FUnlock/FUnlock.entitlements` |
| `BLEUnlockTests/BLEUnlockTests.swift` | `FUnlockTests/FUnlockTests.swift` |

### 代码符号重命名

| 原名 | 新名 | 类型 |
|------|------|------|
| `BLE` | `FUn` | class |
| `BLEDelegate` | `FUnDelegate` | protocol |
| `BluetoothManager` | `FUnManager` | class |
| `ble` (实例变量) | `fun` | variable |
| `BLEUnlockTests` | `FUnlockTests` | test class |
| `BLEUnlock.checkUpdate()` | `FUnlock.checkUpdate()` | 模块引用 |

### Xcode 项目配置重命名

| 配置项 | 旧值 | 新值 |
|--------|------|------|
| Target name | `BLEUnlock` | `FUnlock` |
| Product name | `BLEUnlock` | `FUnlock` |
| Entitlements path | `BLEUnlock/BLEUnlock.entitlements` | `FUnlock/FUnlock.entitlements` |
| Info.plist path | `BLEUnlock/Info.plist` | `FUnlock/Info.plist` |
| Bridging header path | `BLEUnlock/BLEUnlock-Bridging-Header.h` | `FUnlock/FUnlock-Bridging-Header.h` |

### 保持不变

- `"com.bleunlock.ble"` — dispatch queue label
- `"https://api.github.com/repos/ts1/BLEUnlock/releases/latest"` — 外部 API URL
- `"https://gitee.com/fuhahah/bleunlock/releases"` — 外部 URL
- `"bleunlock-update"` / `"bleunlock-lock"` — 通知 identifier
- `"关于 BLEUnlock"` — UI 显示文本
- `com.apple.Bluetooth.plist` — 系统文件路径
- `com.apple.MobileBluetooth.*` — 系统数据库路径
- `LEDeviceInfo` — 结构体名（无 BLE 前缀）
- `Launcher/` — 独立 target，不改

---

### Task 1: 重命名文件和目录

**Files:** 文件系统操作

- [ ] **Step 1: 重命名主目录**

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock
mv BLEUnlock FUnlock
```

- [ ] **Step 2: 重命名 BLE.swift → FUn.swift**

```bash
mv FUnlock/BLE.swift FUnlock/FUn.swift
```

- [ ] **Step 3: 重命名 BluetoothManager.swift → FUnManager.swift**

```bash
mv FUnlock/BluetoothManager.swift FUnlock/FUnManager.swift
```

- [ ] **Step 4: 重命名 BLEUnlock.entitlements → FUnlock.entitlements**

```bash
mv FUnlock/BLEUnlock.entitlements FUnlock/FUnlock.entitlements
```

- [ ] **Step 5: 重命名测试目录和文件**

```bash
mv BLEUnlockTests FUnlockTests
mv FUnlockTests/BLEUnlockTests.swift FUnlockTests/FUnlockTests.swift
```

- [ ] **Step 6: 重命名 bridging header**

```bash
mv FUnlock/BLEUnlock-Bridging-Header.h FUnlock/FUnlock-Bridging-Header.h
```

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: rename BLEUnlock directories and files to FUnlock"
```

---

### Task 2: 更新 Xcode 项目配置（project.pbxproj）

**Files:**
- Modify: `BLEUnlock.xcodeproj/project.pbxproj`

所有 `BLEUnlock` → `FUnlock`，`BLE.swift` → `FUn.swift`，`BluetoothManager.swift` → `FUnManager.swift`

- [ ] **Step 1: 重命名 Target 和 Product**

替换 `project.pbxproj` 中所有以下内容（用 `replace_all`）：

```
BLEUnlock.app → FUnlock.app
BLEUnlock.entitlements → FUnlock.entitlements
BLEUnlock-Bridging-Header.h → FUnlock-Bridging-Header.h
BLE.swift → FUn.swift
path = BLEUnlock; → path = FUnlock;
name = BLEUnlock; → name = FUnlock;
productName = BLEUnlock; → productName = FUnlock;
/* BLEUnlock */, → /* FUnlock */,
/* Build configuration list for PBXProject "BLEUnlock" */ → /* Build configuration list for PBXProject "FUnlock" */
/* Build configuration list for PBXNativeTarget "BLEUnlock" */ → /* Build configuration list for PBXNativeTarget "FUnlock" */
BLEUnlock/BLEUnlock.entitlements → FUnlock/FUnlock.entitlements
BLEUnlock/Info.plist → FUnlock/Info.plist
"BLEUnlock/BLEUnlock-Bridging-Header.h" → "FUnlock/FUnlock-Bridging-Header.h"
/* BLEUnlock */ = { → /* FUnlock */ = {
```

- [ ] **Step 2: 验证 pbxproj 中无残留 BLE**

```bash
grep "BLE" BLEUnlock.xcodeproj/project.pbxproj
```

Expected: 仅剩 `CLANG_ENABLE_MODULES` 等无关行

- [ ] **Step 3: Commit**

```bash
git add BLEUnlock.xcodeproj/project.pbxproj
git commit -m "refactor: update Xcode project for FUnlock naming"
```

---

### Task 3: 重命名 FUn.swift 中的类型（原 BLE.swift）

**Files:**
- Modify: `FUnlock/FUn.swift`

- [ ] **Step 1: 修改协议名 `BLEDelegate` → `FUnDelegate`**

`FUnlock/FUn.swift:94`:
```swift
// 旧：
protocol BLEDelegate {
// 新：
protocol FUnDelegate {
```

- [ ] **Step 2: 修改类名 `class BLE` → `class FUn`**

`FUnlock/FUn.swift:103`:
```swift
// 旧：
class BLE: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
// 新：
class FUn: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
```

- [ ] **Step 3: 修改 delegate 属性类型**

`FUnlock/FUn.swift:109`:
```swift
// 旧：
var delegate: BLEDelegate?
// 新：
var delegate: FUnDelegate?
```

- [ ] **Step 4: 修改 print 日志**

`FUnlock/FUn.swift:192`:
```swift
// 旧：
print("[BLE] Found known peripheral: \(peripheral.identifier) state=\(peripheral.state)")
// 新：
print("[FUn] Found known peripheral: \(peripheral.identifier) state=\(peripheral.state)")
```

- [ ] **Step 5: Commit**

```bash
git add FUnlock/FUn.swift
git commit -m "refactor: rename BLE class → FUn, BLEDelegate → FUnDelegate"
```

---

### Task 4: 重命名 FUnManager.swift 中的类型（原 BluetoothManager.swift）

**Files:**
- Modify: `FUnlock/FUnManager.swift`

- [ ] **Step 1: 修改类名**

`FUnlock/FUnManager.swift:74`:
```swift
// 旧：
final class BluetoothManager: ObservableObject {
// 新：
final class FUnManager: ObservableObject {
```

- [ ] **Step 2: 修改 MARK 注释**

`FUnlock/FUnManager.swift:71`:
```swift
// 旧：
// MARK: - BluetoothManager
// 新：
// MARK: - FUnManager
```

- [ ] **Step 3: 修改 init 参数和属性名 `ble` → `fun`**

`FUnlock/FUnManager.swift:89,99-102`:
```swift
// 旧：
let ble: BLE
// ...
init(ble: BLE) {
    self.ble = ble
    self.lockRSSI = ble.lockRSSI
    self.unlockRSSI = ble.unlockRSSI
}
// 新：
let fun: FUn
// ...
init(fun: FUn) {
    self.fun = fun
    self.lockRSSI = fun.lockRSSI
    self.unlockRSSI = fun.unlockRSSI
}
```

- [ ] **Step 4: 全局替换 `ble.` → `fun.`（FUnManager.swift 内所有实例引用）**

使用 `replace_all` 批量替换。涉及行：109, 116, 124, 128, 179, 213, 234, 273, 274, 281, 282, 283, 317, 319, 320, 585, 603, 604, 605, 606, 607, 608, 609

- [ ] **Step 5: 修改 MARK 注释**

`FUnlock/FUnManager.swift:209`:
```swift
// 旧：
// MARK: - BLE 设备事件
// 新：
// MARK: - FUn 设备事件
```

- [ ] **Step 6: 修改 `BLEUnlock.checkUpdate()`**

`FUnlock/FUnManager.swift:597`:
```swift
// 旧：
BLEUnlock.checkUpdate()
// 新：
FUnlock.checkUpdate()
```

- [ ] **Step 7: Commit**

```bash
git add FUnlock/FUnManager.swift
git commit -m "refactor: rename BluetoothManager → FUnManager, ble → fun"
```

---

### Task 5: 更新 AppDelegate.swift

**Files:**
- Modify: `FUnlock/AppDelegate.swift`

- [ ] **Step 1: 修改协议遵从**

`FUnlock/AppDelegate.swift:16`:
```swift
// 旧：
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, BLEDelegate {
// 新：
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, FUnDelegate {
```

- [ ] **Step 2: 修改实例化**

`FUnlock/AppDelegate.swift:26`:
```swift
// 旧：
let ble = BLE()
// 新：
let fun = FUn()
```

- [ ] **Step 3: 修改 MARK 注释**

`FUnlock/AppDelegate.swift:31`:
```swift
// 旧：
// MARK: - BLEDelegate（UI 更新 + 转发设备事件）
// 新：
// MARK: - FUnDelegate（UI 更新 + 转发设备事件）
```

- [ ] **Step 4: 全局替换 `ble.` → `fun.`（AppDelegate.swift 内）**

使用 `replace_all` 批量替换。涉及行：87, 93, 138, 139, 140, 141, 142, 143, 146, 147, 153, 157, 200, 205

- [ ] **Step 5: 修改 BluetoothManager 引用**

`FUnlock/AppDelegate.swift:27`:
```swift
// 旧：
var manager: BluetoothManager!
// 新：
var manager: FUnManager!
```

`FUnlock/AppDelegate.swift:146`:
```swift
// 旧：
manager = BluetoothManager(ble: ble)
// 新：
manager = FUnManager(fun: fun)
```

- [ ] **Step 6: 修改 MenuDashboardView 调用**

`FUnlock/AppDelegate.swift:157`:
```swift
// 旧：
let dashboard = MenuDashboardView(manager: manager, ble: ble)
// 新：
let dashboard = MenuDashboardView(manager: manager, fun: fun)
```

- [ ] **Step 7: 修改 `BLEUnlock.checkUpdate()`**

`FUnlock/AppDelegate.swift:211`:
```swift
// 旧：
BLEUnlock.checkUpdate()
// 新：
FUnlock.checkUpdate()
```

- [ ] **Step 8: Commit**

```bash
git add FUnlock/AppDelegate.swift
git commit -m "refactor: update AppDelegate for FUn/FUnManager naming"
```

---

### Task 6: 更新 MenuDashboardView.swift

**Files:**
- Modify: `FUnlock/MenuDashboardView.swift`

- [ ] **Step 1: 修改类型引用**

`FUnlock/MenuDashboardView.swift:9-10`:
```swift
// 旧：
@ObservedObject var manager: BluetoothManager
@ObservedObject var ble: BLE
// 新：
@ObservedObject var manager: FUnManager
@ObservedObject var fun: FUn
```

- [ ] **Step 2: 修改 `ble.` → `fun.`**

`FUnlock/MenuDashboardView.swift:353`:
```swift
// 旧：
.onChange(of: passiveMode) { v in ble.setPassiveMode(v) }
// 新：
.onChange(of: passiveMode) { v in fun.setPassiveMode(v) }
```

- [ ] **Step 3: Commit**

```bash
git add FUnlock/MenuDashboardView.swift
git commit -m "refactor: update MenuDashboardView for FUn/FUnManager naming"
```

---

### Task 7: 更新 CalibrationWizardView.swift

**Files:**
- Modify: `FUnlock/CalibrationWizardView.swift`

- [ ] **Step 1: 修改类型引用**

`FUnlock/CalibrationWizardView.swift:8`:
```swift
// 旧：
@ObservedObject var manager: BluetoothManager
// 新：
@ObservedObject var manager: FUnManager
```

- [ ] **Step 2: Commit**

```bash
git add FUnlock/CalibrationWizardView.swift
git commit -m "refactor: update CalibrationWizardView for FUnManager naming"
```

---

### Task 8: 更新测试类

**Files:**
- Modify: `FUnlockTests/FUnlockTests.swift`

- [ ] **Step 1: 修改测试类名**

`FUnlockTests/FUnlockTests.swift:4`:
```swift
// 旧：
class BLEUnlockTests: XCTestCase {
// 新：
class FUnlockTests: XCTestCase {
```

- [ ] **Step 2: Commit**

```bash
git add FUnlockTests/FUnlockTests.swift
git commit -m "refactor: rename BLEUnlockTests → FUnlockTests"
```

---

### Task 9: 编译验证

- [ ] **Step 1: 编译项目**

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock && xcodebuild build -project BLEUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: BUILD SUCCEEDED

- [ ] **Step 2: 检查残留的 BLE 代码引用**

```bash
grep -rn "BLE\|BluetoothManager\|ble\." FUnlock/*.swift FUnlockTests/*.swift | grep -v "// " | grep -v "CoreBluetooth\|CBPeripheral\|CBCentral\|CBL\|kCB\|com\.apple\.Bluetooth\|NSBluetoothAlways\|MobileBluetooth"
```

Expected: 无匹配

- [ ] **Step 3: 修复残留（如有）**

根据 grep 结果逐行修复。

---

### Task 10: 运行测试

- [ ] **Step 1: 运行单元测试**

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock && xcodebuild test -project BLEUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: All tests passed

---

## 自检清单

1. **目录结构**：`FUnlock/` 目录包含所有源文件，`FUnlockTests/` 包含测试
2. **Xcode 项目**：pbxproj 中所有路径指向 `FUnlock/`，target 名为 `FUnlock`
3. **类型一致性**：`FUn`（类）、`FUnDelegate`（协议）、`FUnManager`（类）拼写一致
4. **实例变量**：`fun` 在 AppDelegate、FUnManager、MenuDashboardView 中一致
5. **init 签名**：`FUnManager(init fun: FUn)` 与 `FUnManager(fun: fun)` 匹配
6. **模块引用**：`FUnlock.checkUpdate()` 调用正确
7. **未改内容**：bundle ID、dispatch queue label、外部 URL、通知 identifier 保持不变
