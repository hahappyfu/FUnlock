# 日志规范化改造 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 新建 AppLog 统一门面，一次调用双通道落盘（os.log + debug.log），迁移全部约 190 处日志调用点为 key=value 结构化格式。

**架构：** `AppLog` 静态门面（debug/info/error/fault × 5 个 category），内部同时写 os.Logger（复用现有 `Log.sm/ble/dev` 实例）和 `DebugLog`（复用现有串行队列与滚动）。`timingLog` 保留独立文件仅改格式；`DecisionLogger`/`TelemetryLogger` 完全不动。

**技术栈：** Swift 6 / SwiftUI 菜单栏应用，XCTest，os.Logger，文件日志（已有 `DebugLog` + `LogRotator`）。

**规格：** `docs/superpowers/specs/2026-10-16-logging-normalization-design.md`（执行者两份都读）

## 全局约束

- debug.log 行格式：`[yyyy-MM-dd HH:mm:ss.SSS] [CATEGORY] event=xxx key=value`，CATEGORY ∈ SM/BLE/UNLOCK/LOCK/APP
- value 含空格加双引号：`detail="屏幕已解锁"`；nil 字段省略
- event 命名：动词短语 camelCase；正向与拒绝拆开（`unlockStart` / `unlockSkip(reason=...)`）
- level：debug=高频原始数据；info=状态流转与业务分支；error=异常失败；fault=需人工介入
- 不引入日志框架依赖；不改日志文件位置与滚动策略；不动 DecisionLogger/TelemetryLogger
- 涉及密码内容的日志（原代码有 `PASSWORD:` 脱敏逻辑，SystemInteractionService.swift:35）迁移时保持脱敏
- 本项目是 Xcode 工程（非 SPM）。每个迁移任务后必须编译通过 + 测试全绿（基线：444 通过 + 1 跳过 = 0 失败）才可 commit
  - 构建：`xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | tail -5`
  - 测试：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | tail -6`
- commit 末尾加：`Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

## 迁移映射表（所有任务通用）

| 原调用 | 新调用 |
|--------|--------|
| `Log.sm.debug("[SM] displaySleep")` | `AppLog.info(.sm, "displaySleep")` |
| `Log.sm.debug("EVENT: onDisplayWake screen=\(s) system=\(t)")` | `AppLog.info(.sm, "displayWake", [("screen", "\(s)"), ("system", "\(t)")])` |
| `Log.sm.debug("SKIP: screen not locked")` | `AppLog.info(.sm, "unlockSkip", [("reason", "screenNotLocked")])` |
| `logDebug(component: "BLE", "[BLE] displaySleep — screen=\(s)")` | `AppLog.debug(.ble, "displaySleep", [("screen", "\(s)")])` |
| `logDebug(component: "AppDelegate", "[DIAG] ... bluetooth authorization=\(a)")` | `AppLog.info(.app, "launch", [("btAuth", "\(a)")])` |
| `lockLog("[LOCK] onDeviceApproached ...")` | `AppLog.debug(.lock, "deviceApproached", [...])` |
| `Log.ble.debug("...")`（RSSI 原始数据） | `AppLog.debug(.ble, "rssiUpdate", [...])` |
| `Log.sm.error("CGEvent 失败 ...")` | `AppLog.error(.sm, "cgEventFail", [...])` |

category 选择：状态机/系统事件→`.sm`；蓝牙扫描信号→`.ble`；解锁编排（UnlockOrchestrator*、tryUnlock、门控）→`.unlock`；锁屏判定→`.lock`；生命周期/权限/配置/SQLite→`.app`。

保留不动：`throttledBleLog`（内部改调 AppLog，签名不变）、`timingLog`（任务 8 改格式）、`DebugLog` 枚举本体、`LogRotator`。

---

### 任务 1：AppLog 门面 + 单元测试（TDD）

**文件：**
- 创建：`FUnlock/AppLog.swift`
- 测试：`FUnlockTests/AppLogTests.swift`

- [ ] **步骤 1：编写失败的测试**

```swift
import XCTest
@testable import FUnlock

final class AppLogTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // 重定向到临时目录，读回验证
        DebugLog.testLogDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("applog-tests-\(UUID().uuidString)")
    }
    override func tearDown() {
        if let dir = DebugLog.testLogDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        DebugLog.testLogDirectory = nil
        super.tearDown()
    }

    private func readLogFile() throws -> String {
        DebugLog.flush()
        return try String(contentsOf: DebugLog.logFileURL, encoding: .utf8)
    }

    func testFormatKeyValue() throws {
        AppLog.info(.sm, "displayWake", [("screen", "locked(away)"), ("isSelfWake", "true")])
        let content = try readLogFile()
        XCTAssertTrue(content.contains("[SM] event=displayWake screen=locked(away) isSelfWake=true\n"))
    }

    func testNilFieldOmitted() throws {
        AppLog.debug(.ble, "rssiUpdate", [("rssi", "-65"), ("name", nil)])
        let content = try readLogFile()
        XCTAssertTrue(content.contains("[BLE] event=rssiUpdate rssi=-65\n"))
        XCTAssertFalse(content.contains("name"))
    }

    func testQuotedValueWithSpaces() throws {
        AppLog.info(.unlock, "unlockSkip", [("reason", "screenNotLocked"), ("detail", "屏幕已解锁")])
        let content = try readLogFile()
        XCTAssertTrue(content.contains("[UNLOCK] event=unlockSkip reason=screenNotLocked detail=\"屏幕已解锁\"\n"))
    }

    func testNoFields() throws {
        AppLog.info(.sm, "displaySleep")
        let content = try readLogFile()
        XCTAssertTrue(content.contains("[SM] event=displaySleep\n"))
    }

    func testAllCategoriesMapped() throws {
        AppLog.debug(.ble, "probe"); AppLog.info(.lock, "probe")
        AppLog.error(.unlock, "probe"); AppLog.fault(.app, "probe")
        let content = try readLogFile()
        for tag in ["[BLE]", "[LOCK]", "[UNLOCK]", "[APP]"] {
            XCTAssertTrue(content.contains("\(tag) event=probe"))
        }
    }
}
```

- [ ] **步骤 2：运行测试验证失败**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -only-testing:FUnlockTests/AppLogTests 2>&1 | tail -8`
预期：FAIL，"cannot find 'AppLog' in scope"

- [ ] **步骤 3：编写实现**

```swift
import Foundation
import os

/// 日志 category：收敛原 component 标签与 os.Logger category
enum AppCategory {
    case sm, ble, unlock, lock, app

    /// debug.log 中的标签
    var tag: String {
        switch self {
        case .sm: "SM"; case .ble: "BLE"; case .unlock: "UNLOCK"
        case .lock: "LOCK"; case .app: "APP"
        }
    }
}

/// 统一日志门面：一次调用同时写 os.log 与 debug.log
/// - debug 高频原始数据（RSSI、didDiscover）
/// - info   状态机流转与业务分支（SKIP、displaySleep/Wake）
/// - error  异常与权限失败
/// - fault  需人工介入的严重异常
enum AppLog {
    private static func osLogger(for category: AppCategory) -> Logger {
        switch category {
        case .sm: Log.sm
        case .ble: Log.ble
        case .unlock, .lock: Log.sm   // UNLOCK/LOCK 映射到状态机 Logger，避免新建 subsystem category
        case .app: Log.dev
        }
    }

    /// key=value 拼接：nil 字段省略，含空白的 value 加双引号
    static func message(_ event: String, _ fields: [(String, String?)]) -> String {
        var parts = ["event=\(event)"]
        for (key, value) in fields {
            guard let value else { continue }
            let quoted = value.contains(" ") ? "\"\(value)\"" : value
            parts.append("\(key)=\(quoted)")
        }
        return parts.joined(separator: " ")
    }

    static func debug(_ category: AppCategory, _ event: String, _ fields: [(String, String?)] = []) {
        log(category, event, fields, level: .debug)
    }
    static func info(_ category: AppCategory, _ event: String, _ fields: [(String, String?)] = []) {
        log(category, event, fields, level: .info)
    }
    static func error(_ category: AppCategory, _ event: String, _ fields: [(String, String?)] = []) {
        log(category, event, fields, level: .error)
    }
    static func fault(_ category: AppCategory, _ event: String, _ fields: [(String, String?)] = []) {
        log(category, event, fields, level: .fault)
    }

    private static func log(_ category: AppCategory, _ event: String,
                            _ fields: [(String, String?)], level: OSLogType) {
        let msg = message(event, fields)
        DebugLog.log(component: category.tag, msg)
        let logger = osLogger(for: category)
        switch level {
        case .debug: logger.debug("\(msg, privacy: .public)")
        case .info: logger.info("\(msg, privacy: .public)")
        case .error: logger.error("\(msg, privacy: .public)")
        case .fault: logger.fault("\(msg, privacy: .public)")
        default: logger.debug("\(msg, privacy: .public)")
        }
    }
}
```

（本项目 xcodeproj 用显式 file membership 而非文件夹自动收录：需要把 `AppLog.swift` 与 `AppLogTests.swift` 加入对应 target 的 Compile Sources。用 `xcodebuild build` 确认。）

- [ ] **步骤 4：运行测试验证通过**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -only-testing:FUnlockTests/AppLogTests 2>&1 | tail -8`
预期：5 个测试全 PASS

- [ ] **步骤 5：Commit**

```bash
git add FUnlock/AppLog.swift FUnlockTests/AppLogTests.swift
git commit -m "feat(log): 新增 AppLog 统一日志门面（os.log + debug.log 双写，key=value 格式）"
```

---

### 任务 2：迁移解锁编排（UnlockOrchestrator 两个文件）

**文件：**
- 修改：`FUnlock/UnlockOrchestrator.swift`（Log.* 18 处 + logDebug + timingLog 调用保留）
- 修改：`FUnlock/UnlockOrchestrator+AutoUnlock.swift`（Log.* 22 处）

- [ ] **步骤 1：迁移全部调用点**

按迁移映射表，category 用 `.unlock`（门控/注入/验证/重试）。示例：

```swift
// 原：
Log.sm.debug("SKIP: screen not locked"); recordUnlock(.info, reason: .screenNotLocked, detail: "屏幕已解锁")
// 新：
AppLog.info(.unlock, "unlockSkip", [("reason", "screenNotLocked")]); recordUnlock(.info, reason: .screenNotLocked, detail: "屏幕已解锁")

// 原：
logDebug(component: "FUnManager", "tryUnlock() START - screen=\(m.state.screen), locked=\(locked)")
// 新：
AppLog.info(.unlock, "unlockStart", [("screen", "\(m.state.screen)"), ("locked", "\(locked)")])
```

`timingLog` 调用此任务不动（任务 8 统一改）。注意 `recordUnlock` 等 DecisionLogger/TelemetryLogger 调用一行都不要碰。

- [ ] **步骤 2：验证**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | tail -6`
预期：编译 0 错误；444 个测试全 PASS（1 跳过）（这两个文件多线程路径有测试覆盖，若某个测试断言了日志文本需同步更新断言）。

- [ ] **步骤 3：Commit**

```bash
git add FUnlock/UnlockOrchestrator.swift FUnlock/UnlockOrchestrator+AutoUnlock.swift
git commit -m "refactor(log): UnlockOrchestrator 日志迁移至 AppLog"
```

---

### 任务 3：迁移状态机事件与锁屏（Events/Coordinator/Manager）

**文件：**
- 修改：`FUnlock/FUnManager+Events.swift`（Log.* 13 处 + logDebug + lockLog）
- 修改：`FUnlock/FUnLockCoordinator.swift`（Log.* 8 处 + lockLog）
- 修改：`FUnlock/FUnManager.swift`（Log.* 1 处）

- [ ] **步骤 1：迁移全部调用点**

系统事件入口（onDisplaySleep/onDisplayWake/onSystemSleep/onSystemWake/onUnlock）用 `.sm`；onDeviceApproached/onDeviceLeft 及锁屏判定用 `.lock`。`onDisplaySleep` 原来写 3 行日志收敛为 AppLog.info(.sm, "displaySleep") 一行（原 `[SM] displaySleep`、`EVENT: ...`、`[BLE] ...` 三条信息重复）。

- [ ] **步骤 2：验证**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | tail -6`
预期：编译 0 错误，全 PASS。

- [ ] **步骤 3：Commit**

```bash
git add FUnlock/FUnManager+Events.swift FUnlock/FUnLockCoordinator.swift FUnlock/FUnManager.swift
git commit -m "refactor(log): 状态机事件与锁屏日志迁移至 AppLog"
```

---

### 任务 4：迁移 BLE 层（Scanner/Handler/FUn/SignalProcessor）

**文件：**
- 修改：`FUnlock/BLEScanner.swift`（Log.* 2 + logDebug）
- 修改：`FUnlock/BLEPeripheralHandler.swift`（Log.* 6）
- 修改：`FUnlock/FUn.swift`（Log.* 2 + logDebug + lockLog 定义处：`lockLog` 改为转调 `AppLog.debug(.lock, ...)`，函数暂留待任务 9 删）
- 修改：`FUnlock/FUnSignalProcessor.swift`（Log.* 1 + logDebug）

- [ ] **步骤 1：迁移全部调用点**

RSSI 采样、didDiscover 等高频数据 → `AppLog.debug(.ble, ...)`；扫描启停/模式切换 → `AppLog.info(.ble, ...)`。`throttledBleLog` 内部 `Log.ble.debug` 改为 `AppLog.debug(.ble, "throttled", ...)`——不行，它接收任意文案，改为：`throttledBleLog` 保留原 `Log.ble.debug("\(msg)")` 改为调用 `AppLog.debug(.ble, "raw", [("msg", msg)])`？——**不要这样**。`throttledBleLog` 的调用方（BLEScanner/FUnSignalProcessor 共 3 处）在本任务内一并迁移为 `AppLog.debug(.ble, event, fields)` + 调用方自行判断节流场景（保留 throttledBleLog 函数但内部改 `AppLog.debug(.ble, "throttledLog", [("msg", msg)])` 会破坏格式约定；正确做法：调用点直接传 event/fields，函数签名改为 `throttledBleLog(_ key: String, interval: TimeInterval = 1.0, _ category: AppCategory = .ble, _ event: String, _ fields: [(String, String?)] = [])`，内部节流后调 `AppLog.debug(category, event, fields)`）。

- [ ] **步骤 2：验证**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | tail -6`
预期：编译 0 错误，全 PASS（`UIAndUtilityTests` 覆盖 throttledBleLog）。

- [ ] **步骤 3：Commit**

```bash
git add FUnlock/BLEScanner.swift FUnlock/BLEPeripheralHandler.swift FUnlock/FUn.swift FUnlock/FUnSignalProcessor.swift
git commit -m "refactor(log): BLE 层日志迁移至 AppLog，throttledBleLog 签名结构化"
```

---

### 任务 5：迁移系统交互与安全服务

**文件：**
- 修改：`FUnlock/SystemInteractionService.swift`（Log.* 10 + logDebug + logBoth）
- 修改：`FUnlock/SecurityService.swift`（Log.* 3）
- 修改：`FUnlock/iMessageNotifier.swift`、`FUnlock/WiFiMonitor.swift`（各 Log.* 1）

- [ ] **步骤 1：迁移全部调用点**

删除 `logBoth`（SystemInteractionService.swift:34-38），原双写调用点直接用 AppLog（天然双写）。**保持密码脱敏**：原 `logBoth` 把 `PASSWORD: ` 替换掉才落盘——迁移后任何字段值不得含明文密码，原含 `PASSWORD` 的日志行改为只记 `passwordLength` 或删除该字段。

注入/AppleScript/CGEvent 相关 → `.unlock`；屏幕状态检测 → `.sm`；安全服务 → `.app`。

- [ ] **步骤 2：验证**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | tail -6`
预期：编译 0 错误，全 PASS。

- [ ] **步骤 3：Commit**

```bash
git add FUnlock/SystemInteractionService.swift FUnlock/SecurityService.swift FUnlock/iMessageNotifier.swift FUnlock/WiFiMonitor.swift
git commit -m "refactor(log): 系统交互与安全服务迁移至 AppLog，删除 logBoth 双写胶水"
```

---

### 任务 6：迁移 App 层与杂项（AppDelegate/ConfigStore/LEDeviceInfo/DecisionLogger/BasicSettingsView）

**文件：**
- 修改：`FUnlock/AppDelegate.swift`（logDebug）
- 修改：`FUnlock/ConfigStore.swift`（logDebug）
- 修改：`FUnlock/LEDeviceInfo.swift`（Log.dev 4 处：DB 打开/prepare 失败 → `.app`，error 级）
- 修改：`FUnlock/DecisionLogger.swift`（Log.* 4 处——**只改日志调用，DecisionLogger 业务逻辑不动**）
- 修改：`FUnlock/BasicSettingsView.swift`（Log.* 1）

- [ ] **步骤 1：迁移全部调用点**

全部用 `.app`。`[DIAG]` 前缀的启动/权限日志 → `AppLog.info(.app, "launch", ...)` / `AppLog.error(.app, "btAuth", ...)`。

- [ ] **步骤 2：验证**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | tail -6`
预期：编译 0 错误，全 PASS。

- [ ] **步骤 3：Commit**

```bash
git add -A FUnlock/
git commit -m "refactor(log): App 层与杂项日志迁移至 AppLog"
```

---

### 任务 7：清理旧入口（删 logDebug/lockLog/Log 旧用法）

**文件：**
- 修改：`FUnlock/DebugLog.swift`（删顶层 `logDebug` 函数，`DebugLog` 枚举保留）
- 修改：`FUnlock/FUn.swift`（删顶层 `lockLog` 函数）
- 修改：`FUnlock/Log.swift`（保留枚举与实例——AppLog 内部还在用；仅确认文件头注释更新为"仅供 AppLog 内部使用"）

- [ ] **步骤 1：确认无残留调用**

运行：`grep -rn "logDebug(\|lockLog(" --include='*.swift' FUnlock FUnlockTests | grep -v "DebugLog.swift\|FUn.swift:5"`
预期：无输出（或仅剩定义本身）。若有残留，先迁移再删。

- [ ] **步骤 2：删除旧函数并更新 Log.swift 注释**

- [ ] **步骤 3：验证**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | tail -6`
预期：编译 0 错误，全 PASS。

- [ ] **步骤 4：Commit**

```bash
git add FUnlock/DebugLog.swift FUnlock/FUn.swift FUnlock/Log.swift
git commit -m "refactor(log): 删除 logDebug/lockLog 旧入口，Log 收编为 AppLog 内部依赖"
```

---

### 任务 8：timingLog 格式对齐

**文件：**
- 修改：`FUnlock/FUnlockUtils.swift`（仅 timingLog 函数注释，格式由调用方拼接）
- 修改：`FUnlock/UnlockOrchestrator.swift`、`FUnlock/UnlockOrchestrator+AutoUnlock.swift`、`FUnlock/SystemInteractionService.swift`、`FUnlock/FUnManager+Events.swift` 中的 `timingLog("...")` 调用（36 处）

- [ ] **步骤 1：改调用点格式**

`timingLog` 函数本体、限流、滚动逻辑一行不动。只改调用文案：

```swift
// 原：timingLog("tryUnlock enter")
// 新：timingLog("event=tryUnlockEnter")
// 原：timingLog("guardFetchPassword | locked=\(locked) frontmost=\(x)")
// 新：timingLog("event=guardFetchPassword locked=\(locked) frontmost=\(x)")
```

- [ ] **步骤 2：验证**

运行：`xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' 2>&1 | tail -6`
预期：编译 0 错误，全 PASS。

- [ ] **步骤 3：Commit**

```bash
git add -A FUnlock/
git commit -m "refactor(log): timingLog 调用文案对齐 event=key=value 格式"
```

---

### 任务 9：文档 + 终验

**文件：**
- 创建：`docs/logging.md`

- [ ] **步骤 1：写文档**

内容（一页）：category 词汇表（5 个 + 各自涵盖的模块）、level 判定标准、event 命名约定、debug.log 行格式说明、排查示例：

```bash
grep 'event=displayWake' ~/Library/Logs/FUnlock/debug.log
grep 'event=unlockSkip reason=' ~/Library/Logs/FUnlock/debug.log
grep '\[UNLOCK\]' ~/Library/Logs/FUnlock/debug.log
```

- [ ] **步骤 2：终验**

运行：`grep -rn "Log\.\(sm\|ble\|dev\)\." --include='*.swift' FUnlock | grep -v AppLog.swift | grep -v "Log.swift"` 然后跑上面的 xcodebuild test
预期：grep 无输出（旧调用清零）；447 个测试全 PASS。

- [ ] **步骤 3：Commit**

```bash
git add docs/logging.md
git commit -m "docs: 新增日志规范文档（category/level/event 约定与排查指南）"
```

---

## 自检记录

- 规格覆盖：统一门面（任务 1）、迁移 190 处（任务 2-6）、删旧入口（任务 7）、timingLog（任务 8）、文档（任务 9）、双通道/格式测试（任务 1 测试）✓
- 规格中「裸 Logger( 13 处」经核实：除 Log.swift 定义外仅 DecisionLogger/TelemetryLogger 各 1 处为 os.Logger 实例定义（这两个文件不动，其中 DecisionLogger 的 4 处 Log.* 调用在任务 6 迁移）；`print(` 经核实 FUnlock target 内为 0 处 ✓
- 类型一致性：AppCategory/AppLog 签名在任务 1 定义，任务 2-8 全部沿用同一签名；throttledBleLog 新签名只在任务 4 出现一次 ✓
