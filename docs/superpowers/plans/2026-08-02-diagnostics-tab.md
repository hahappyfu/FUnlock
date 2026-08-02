# 「诊断」Tab —— 解锁/锁屏决策时间线 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增「诊断」侧边栏 Tab，用 `DecisionLogger` 把 `FUnManager` 的解锁/锁屏决策原因（SKIP 分支 + 结果 + 系统事件）变成结构化决策时间线，内存环形缓冲 + `~/Library/Logs/FUnlock/decisions.jsonl` 跨启动持久化，并提供上下文操作按钮。

**Architecture:** 纯观察式记录，不改变任何决策行为。`DecisionLogger`（@MainActor ObservableObject，仿 `TelemetryLogger` 的 testLogDirectory/nowProvider 注入）持有 `RingBuffer<DecisionEvent>`(500) + 同因合并（3s 窗口）+ 异步 JSONL 持久化 + 1MB 轮转。`FUnManager` 在每个 SKIP 分支/结果处调用 `record`。`DiagnosticsView` 渲染时间线 + 过滤器 + 由 `DecisionReason.action` 派生的操作按钮。不碰 `events.log`/`ScriptRunner`/统计口径。

**Tech Stack:** Swift 5.7+ / macOS 13 / SwiftUI / Combine / XCTest

## Global Constraints

- 部署目标 macOS 13.0+，Swift 5.7+（沿用现有项目配置，不升级）
- Bundle ID 固定：`com.fuhahah.FUnlock`；默认分支 `main`
- 不引入新的第三方依赖
- 新增代码遵循现有注入模式：`nowProvider: () -> Date`（参考 `FUnlockStateMachine.init(nowProvider:)`）、`testLogDirectory`（参考 `TelemetryLogger`）
- 测试禁止触碰真实 `~/Library/Logs/FUnlock/`、真实 Keychain、真实蓝牙写入路径（只读 `FUn()` 的 CBCentralManager 与 `CGSessionCopyCurrentDictionary` 是现有测试已接受的代价）
- 持久化 JSON 字段白名单：`id/timestamp/category/outcome/reason/rssi/device/screen/detail`，绝不写入密码
- 日志统一走 `Log.swift` 的 `os.Logger`，生产代码禁止新增 `print()`/`_log()` 文件写

---

### Task 1: DecisionLogger 引擎（模型 + 记录器 + 测试）

**Files:**
- Create: `FUnlock/DecisionLogger.swift`
- Create: `FUnlockTests/DecisionLoggerTests.swift`
- Modify: `FUnlock.xcodeproj/project.pbxproj`（注册以上两个文件到 FUnlock 与 FUnlockTests target）

**Interfaces:**
- Produces: `DecisionCategory`(unlock/lock/system/user)、`DecisionOutcome`(success/skipped/failed/blocked/info)、`DecisionReason`(CaseIterable, Codable)、`ActionHint`(Equatable, 含 `labelKey`)、`DecisionEvent`(Codable, Identifiable)、`DecisionLogger`(@MainActor ObservableObject，`static let shared`、`init(testLogDirectory:nowProvider:)`、`record(category:outcome:reason:rssi:device:screen:detail:)`、`loadHistory()`、`clear()`、`flushSync()`、`static readTail(from:max:)`、`var events`、`var logFile`、`var coalescingWindow`、`var maxFileSize`、`var testLogDirectory`)、`DecisionReason.titleKey/action`（Task 2 补齐）
- Consumes: 既有 `RingBuffer`（`FUnlock/RingBuffer.swift`，`append/_ = toArray()/clear`）

- [ ] **Step 1: 创建 `FUnlock/DecisionLogger.swift`（完整文件）**

```swift
// DecisionLogger.swift
// 决策记录器：把「为什么没解锁 / 为什么锁屏」变成结构化决策事件，
// 内存环形缓冲 + JSON Lines 持久化，供「诊断」Tab 与后续数据驱动调参使用。

import Foundation
import Combine

// MARK: - 事件模型

enum DecisionCategory: String, Codable, CaseIterable {
    case unlock, lock, system, user
}

enum DecisionOutcome: String, Codable {
    case success, skipped, failed, blocked, info
}

/// 结构化决策原因（解锁跳过 / 锁屏跳过 / 结果 / 系统事件）
enum DecisionReason: String, Codable, CaseIterable {
    // 解锁跳过
    case noPresence
    case signalBelowThreshold
    case unlockCooldownActive
    case lockBufferActive
    case manualLockActive
    case wifiPaused
    case disabled
    case unlockDisabled
    case stateMachineBlocked
    case axRevoked
    case noPassword
    case keychainColdBoot
    case notSecureForInjection
    case displaySleeping
    case systemNotReady
    case wakeWithoutUnlocking
    case recentlyUnlocked
    case screenNotLocked
    // 锁屏跳过
    case inputActive
    case gracePeriod
    case signalBelowLockThreshold
    // 结果
    case unlockSuccess
    case unlockFailed
    case unlockTimeout
    case passwordMismatch
    case lockedAway
    case lockedLost
    // 系统 / 用户
    case displaySleep
    case displayWake
    case systemSleep
    case systemWake
    case userUnlocked
    case userLocked
}

/// 操作提示：由 reason 派生，UI 据此渲染按钮
enum ActionHint: Equatable {
    case lowerUnlockThreshold
    case openAccessibilitySettings
    case reEnterPassword
    case goToTab(String)   // MenuTab.rawValue
    case resetStateMachine

    var labelKey: String {
        switch self {
        case .lowerUnlockThreshold: return "action_lower_unlock_threshold"
        case .openAccessibilitySettings: return "action_open_accessibility"
        case .reEnterPassword: return "action_reenter_password"
        case .goToTab: return "action_go_to_settings"
        case .resetStateMachine: return "action_reset_state_machine"
        }
    }
}

struct DecisionEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let category: DecisionCategory
    let outcome: DecisionOutcome
    let reason: DecisionReason?
    let rssi: Int?
    let device: String?
    let screen: String?
    let detail: String

    init(id: UUID = UUID(), timestamp: Date, category: DecisionCategory,
         outcome: DecisionOutcome, reason: DecisionReason?, rssi: Int?,
         device: String?, screen: String?, detail: String = "") {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.outcome = outcome
        self.reason = reason
        self.rssi = rssi
        self.device = device
        self.screen = screen
        self.detail = detail
    }
}

// MARK: - 记录器

@MainActor
final class DecisionLogger: ObservableObject {
    static let shared = DecisionLogger()

    /// 内存环形缓冲容量
    static let capacity = 500
    /// 同因合并窗口：连续相同 (category, outcome, reason) 在该秒数内只更新时间戳
    var coalescingWindow: TimeInterval = 3.0
    /// 持久化文件轮转上限
    var maxFileSize: UInt64 = 1 * 1024 * 1024
    /// 测试覆盖：非 nil 时读写该目录，避免污染用户真实决策日志
    var testLogDirectory: URL?

    @Published private(set) var events: [DecisionEvent] = []

    private var ring = RingBuffer<DecisionEvent>(capacity: DecisionLogger.capacity)
    private let queue = DispatchQueue(label: "com.funlock.decisions", qos: .utility)
    private var nowProvider: () -> Date = { Date() }

    init(testLogDirectory: URL? = nil, nowProvider: @escaping () -> Date = { Date() }) {
        self.testLogDirectory = testLogDirectory
        self.nowProvider = nowProvider
    }

    // MARK: - 路径

    var logDirectory: URL {
        if let testDir = testLogDirectory { return testDir }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/FUnlock")
    }

    var logFile: URL {
        logDirectory.appendingPathComponent("decisions.jsonl")
    }

    // MARK: - 记录

    func record(category: DecisionCategory,
                outcome: DecisionOutcome,
                reason: DecisionReason?,
                rssi: Int? = nil,
                device: String? = nil,
                screen: String? = nil,
                detail: String = "") {
        let now = nowProvider()

        // 同因合并：连续相同 (category, outcome, reason) 且间隔 < 窗口 → 只更新时间戳
        if var last = events.last,
           last.category == category,
           last.outcome == outcome,
           last.reason == reason,
           now.timeIntervalSince(last.timestamp) < coalescingWindow {
            last.timestamp = now
            if let newRSSI = rssi { last.rssi = newRSSI }
            if let newDevice = device { last.device = newDevice }
            if let newScreen = screen { last.screen = newScreen }
            last.detail = detail
            events[events.count - 1] = last
            return
        }

        let event = DecisionEvent(timestamp: now, category: category, outcome: outcome,
                                  reason: reason, rssi: rssi, device: device,
                                  screen: screen, detail: detail)
        ring.append(event)
        events = ring.toArray()

        let latest = events
        let file = logFile
        let maxSize = maxFileSize
        queue.async {
            Self.write(event, latest: latest, to: file, maxFileSize: maxSize)
        }
    }

    // MARK: - 历史加载

    /// 首次打开「诊断」Tab 时读取文件尾部灌入内存（events 非空时幂等跳过）
    func loadHistory() {
        guard events.isEmpty else { return }
        let file = logFile
        queue.async {
            let loaded = Self.readTail(from: file, max: DecisionLogger.capacity)
            Task { @MainActor [weak self] in
                guard let self, self.events.isEmpty else { return }
                for e in loaded { self.ring.append(e) }
                self.events = self.ring.toArray()
            }
        }
    }

    // MARK: - 清空

    func clear() {
        ring.clear()
        events = []
        let file = logFile
        queue.async {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// 等待持久化队列排空（测试专用）
    func flushSync() {
        queue.sync {}
    }

    // MARK: - 持久化（静态实现，仅处理值类型，无 self 捕获）

    private static func write(_ event: DecisionEvent, latest: [DecisionEvent], to url: URL, maxFileSize: UInt64) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        appendLine(event, to: url)

        // 轮转：超过上限 → 用当前缓冲的最新事件重写文件
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64,
           size > maxFileSize {
            try? FileManager.default.removeItem(at: url)
            for e in latest {
                appendLine(e, to: url)
            }
        }
    }

    private static func appendLine(_ event: DecisionEvent, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: url)
        }
    }

    /// 读取文件尾部最多 max 条（按时间顺序返回）
    static func readTail(from url: URL, max: Int) -> [DecisionEvent] {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var result: [DecisionEvent] = []
        for line in content.components(separatedBy: .newlines).suffix(max) {
            guard let lineData = line.data(using: .utf8),
                  let event = try? decoder.decode(DecisionEvent.self, from: lineData) else { continue }
            result.append(event)
        }
        return result
    }
}
```

- [ ] **Step 2: 注册 `DecisionLogger.swift` 与 `DecisionLoggerTests.swift` 到 pbxproj**

编辑 `FUnlock.xcodeproj/project.pbxproj`，插入以下内容（保持现有缩进风格，`\t` 制表符）：

**(a) PBXBuildFile 区**（`3D2CF85B...` 等条目之间任插两行）：
```
		DL0000020000000100000001 /* DecisionLogger.swift in Sources */ = {isa = PBXBuildFile; fileRef = DL0000010000000100000001 /* DecisionLogger.swift */; };
		DT0000020000000100000001 /* DecisionLoggerTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = DT0000010000000100000001 /* DecisionLoggerTests.swift */; };
```

**(b) PBXFileReference 区**（`TL0000010000000100000002 ... TelemetryLogger.swift` 之后）：
```
		DL0000010000000100000001 /* DecisionLogger.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DecisionLogger.swift; sourceTree = "<group>"; };
		DT0000010000000100000001 /* DecisionLoggerTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DecisionLoggerTests.swift; sourceTree = "<group>"; };
```

**(c) PBXGroup — FUnlock 组**（`3DD4B652...` 的 children 内 `TL0000010000000100000002 /* TelemetryLogger.swift */,` 之后加一行）：
```
				DL0000010000000100000001 /* DecisionLogger.swift */,
```

**(d) PBXGroup — FUnlockTests 组**（`AA000010226C1DF200000014 ... FUnlockTests` 的 children 内 `AA000023226C1DF200000001 /* FUnlockStateMachineTests.swift */,` 之后加一行）：
```
				DT0000010000000100000001 /* DecisionLoggerTests.swift */,
```

**(e) PBXSourcesBuildPhase — FUnlock target**（`TL0000010000000100000001 /* TelemetryLogger.swift in Sources */,` 之后加一行）：
```
				DL0000020000000100000001 /* DecisionLogger.swift in Sources */,
```

**(f) PBXSourcesBuildPhase — FUnlockTests target**（`AA000022226C1DF200000001 /* FUnlockStateMachineTests.swift in Sources */,` 之后加一行）：
```
				DT0000020000000100000001 /* DecisionLoggerTests.swift in Sources */,
```

- [ ] **Step 3: 创建 `FUnlockTests/DecisionLoggerTests.swift`（完整文件）**

```swift
// FUnlockTests/DecisionLoggerTests.swift
import XCTest
@testable import FUnlock

@MainActor
final class DecisionLoggerTests: XCTestCase {
    private var tempDir: URL!
    private var logger: DecisionLogger!
    private var currentTime: Date!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DecisionLoggerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        logger = DecisionLogger(testLogDirectory: tempDir,
                                nowProvider: { [weak self] in self?.currentTime ?? Date() })
    }

    override func tearDownWithError() throws {
        logger = nil
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testRecordAppendsAndPublishes() {
        logger.record(category: .unlock, outcome: .skipped, reason: .noPresence)
        logger.record(category: .unlock, outcome: .success, reason: .unlockSuccess,
                      rssi: -52, device: "iPhone", detail: "ok")
        XCTAssertEqual(logger.events.count, 2)
        XCTAssertEqual(logger.events.last?.reason, .unlockSuccess)
        XCTAssertEqual(logger.events.last?.rssi, -52)
    }

    func testCoalescesIdenticalWithinWindow() {
        logger.record(category: .unlock, outcome: .skipped, reason: .noPresence)
        currentTime = currentTime.addingTimeInterval(2)
        logger.record(category: .unlock, outcome: .skipped, reason: .noPresence)
        XCTAssertEqual(logger.events.count, 1, "3 秒内相同原因应合并")

        currentTime = currentTime.addingTimeInterval(4)
        logger.record(category: .unlock, outcome: .skipped, reason: .noPresence)
        XCTAssertEqual(logger.events.count, 2, "超过窗口应新增")
    }

    func testReasonChangeNeverCoalesced() {
        logger.record(category: .unlock, outcome: .skipped, reason: .noPresence)
        currentTime = currentTime.addingTimeInterval(1)
        logger.record(category: .unlock, outcome: .skipped, reason: .signalBelowThreshold)
        XCTAssertEqual(logger.events.count, 2)
    }

    func testRingCapacityRespected() {
        for _ in 0..<600 {
            currentTime = currentTime.addingTimeInterval(1)
            logger.record(category: .unlock, outcome: .skipped, reason: .noPresence)
        }
        XCTAssertEqual(logger.events.count, 500, "环形缓冲最多保留 500 条")
    }

    func testPersistenceRoundTrip() {
        logger.record(category: .unlock, outcome: .skipped, reason: .signalBelowThreshold,
                      rssi: -72, device: "iPhone", detail: "signal")
        logger.record(category: .lock, outcome: .success, reason: .lockedAway,
                      rssi: -85, device: "iPhone")
        logger.flushSync()

        let reloaded = DecisionLogger.readTail(from: logger.logFile, max: 100)
        XCTAssertEqual(reloaded.count, 2)
        XCTAssertEqual(reloaded.first?.reason, .signalBelowThreshold)
        XCTAssertEqual(reloaded.first?.rssi, -72)
        XCTAssertEqual(reloaded.last?.reason, .lockedAway)
    }

    func testRotationKeepsRecentEvents() {
        logger.maxFileSize = 50   // 单条 JSON 超过 50 字节 → 每次写入都触发轮转
        for _ in 0..<10 {
            currentTime = currentTime.addingTimeInterval(1)
            logger.record(category: .unlock, outcome: .skipped, reason: .noPresence)
        }
        logger.flushSync()
        let reloaded = DecisionLogger.readTail(from: logger.logFile, max: 100)
        XCTAssertFalse(reloaded.isEmpty, "轮转后文件应仍可读")
        XCTAssertEqual(reloaded.last?.reason, .noPresence)
    }

    func testClearRemovesFileAndMemory() {
        logger.record(category: .unlock, outcome: .success, reason: .unlockSuccess)
        logger.flushSync()
        logger.clear()
        logger.flushSync()
        XCTAssertTrue(logger.events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logger.logFile.path))
    }

    func testSerializedKeysAreWhitelisted() {
        let event = DecisionEvent(timestamp: Date(), category: .unlock, outcome: .skipped,
                                  reason: .noPresence, rssi: -60, device: "iPhone",
                                  screen: "locked(away)", detail: "no presence")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(event),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return XCTFail("无法编码 DecisionEvent")
        }
        let allowed = Set(["id", "timestamp", "category", "outcome", "reason",
                           "rssi", "device", "screen", "detail"])
        XCTAssertEqual(Set(json.keys), allowed, "新增字段需同步更新白名单，防止误写敏感数据")
    }
}
```

- [ ] **Step 4: 运行定向测试（应先全绿）**

Run:
```
xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -only-testing:FUnlockTests/DecisionLoggerTests CODE_SIGNING_ALLOWED=NO
```
Expected: 8 个用例全部 PASS，且 `~/Library/Logs/FUnlock/` 无新文件（测试全部走 tempDir）。

- [ ] **Step 5: Commit**

```bash
git add FUnlock/DecisionLogger.swift FUnlockTests/DecisionLoggerTests.swift FUnlock.xcodeproj/project.pbxproj
git commit -m "feat: DecisionLogger 决策记录器（环形缓冲 + 同因合并 + JSONL 持久化 + 轮转）"
```

---

### Task 2: 原因 → 文案/操作映射

**Files:**
- Modify: `FUnlock/DecisionLogger.swift`（文件末尾追加扩展）
- Create: `FUnlockTests/ReasonActionMappingTests.swift`
- Modify: `FUnlock.xcodeproj/project.pbxproj`（注册映射测试文件）

**Interfaces:**
- Produces: `DecisionReason.titleKey: String`、`DecisionReason.action: ActionHint?`（编译期 switch 全覆盖）
- Consumes: `DecisionReason`、`ActionHint`（Task 1）

- [ ] **Step 1: 在 `FUnlock/DecisionLogger.swift` 末尾追加映射扩展（完整代码）**

```swift
// MARK: - 原因 → 文案 / 操作映射

extension DecisionReason {
    /// 本地化 key（各语言见 Base.lproj / zh-Hans.lproj）
    var titleKey: String {
        switch self {
        case .noPresence: return "reason_no_presence"
        case .signalBelowThreshold: return "reason_signal_below_threshold"
        case .unlockCooldownActive: return "reason_unlock_cooldown"
        case .lockBufferActive: return "reason_lock_buffer"
        case .manualLockActive: return "reason_manual_lock"
        case .wifiPaused: return "reason_wifi_paused"
        case .disabled: return "reason_disabled"
        case .unlockDisabled: return "reason_unlock_disabled"
        case .stateMachineBlocked: return "reason_state_machine"
        case .axRevoked: return "reason_ax_revoked"
        case .noPassword: return "reason_no_password"
        case .keychainColdBoot: return "reason_keychain_cold_boot"
        case .notSecureForInjection: return "reason_not_secure"
        case .displaySleeping: return "reason_display_sleeping"
        case .systemNotReady: return "reason_system_not_ready"
        case .wakeWithoutUnlocking: return "reason_wake_without_unlock"
        case .recentlyUnlocked: return "reason_recently_unlocked"
        case .screenNotLocked: return "reason_screen_not_locked"
        case .inputActive: return "reason_input_active"
        case .gracePeriod: return "reason_grace_period"
        case .signalBelowLockThreshold: return "reason_signal_below_lock_threshold"
        case .unlockSuccess: return "reason_unlock_success"
        case .unlockFailed: return "reason_unlock_failed"
        case .unlockTimeout: return "reason_unlock_timeout"
        case .passwordMismatch: return "reason_password_mismatch"
        case .lockedAway: return "reason_locked_away"
        case .lockedLost: return "reason_locked_lost"
        case .displaySleep: return "reason_display_sleep"
        case .displayWake: return "reason_display_wake"
        case .systemSleep: return "reason_system_sleep"
        case .systemWake: return "reason_system_wake"
        case .userUnlocked: return "reason_user_unlocked"
        case .userLocked: return "reason_user_locked"
        }
    }

    /// 操作提示（无操作时为 nil）
    var action: ActionHint? {
        switch self {
        case .signalBelowThreshold: return .lowerUnlockThreshold
        case .manualLockActive: return .goToTab("lock")
        case .wifiPaused: return .goToTab("network")
        case .disabled: return .goToTab("basic")
        case .unlockDisabled: return .goToTab("unlock")
        case .stateMachineBlocked: return .resetStateMachine
        case .axRevoked: return .openAccessibilitySettings
        case .noPassword: return .reEnterPassword
        case .keychainColdBoot: return .reEnterPassword
        case .unlockFailed: return .reEnterPassword
        case .passwordMismatch: return .reEnterPassword
        case .signalBelowLockThreshold: return .goToTab("unlock")
        default: return nil
        }
    }
}
```

- [ ] **Step 2: 创建 `FUnlockTests/ReasonActionMappingTests.swift`（完整文件）**

```swift
// FUnlockTests/ReasonActionMappingTests.swift
import XCTest
@testable import FUnlock

final class ReasonActionMappingTests: XCTestCase {
    func testEveryReasonHasNonEmptyTitleKey() {
        for reason in DecisionReason.allCases {
            XCTAssertFalse(reason.titleKey.isEmpty, "\(reason.rawValue) 缺少 titleKey")
        }
    }

    func testSpecificActionMappings() {
        XCTAssertEqual(DecisionReason.signalBelowThreshold.action, .lowerUnlockThreshold)
        XCTAssertEqual(DecisionReason.axRevoked.action, .openAccessibilitySettings)
        XCTAssertEqual(DecisionReason.unlockFailed.action, .reEnterPassword)
        XCTAssertEqual(DecisionReason.noPassword.action, .reEnterPassword)
        XCTAssertEqual(DecisionReason.stateMachineBlocked.action, .resetStateMachine)
        XCTAssertEqual(DecisionReason.manualLockActive.action, .goToTab("lock"))
        XCTAssertEqual(DecisionReason.wifiPaused.action, .goToTab("network"))
        XCTAssertEqual(DecisionReason.unlockDisabled.action, .goToTab("unlock"))
        XCTAssertNil(DecisionReason.noPresence.action)
        XCTAssertNil(DecisionReason.unlockSuccess.action)
    }

    func testActionHintLabelKeys() {
        let hints: [ActionHint] = [.lowerUnlockThreshold, .openAccessibilitySettings,
                                   .reEnterPassword, .goToTab("lock"), .resetStateMachine]
        for hint in hints {
            XCTAssertFalse(hint.labelKey.isEmpty, "\(hint) 缺少 labelKey")
        }
    }
}
```

- [ ] **Step 3: 注册 `ReasonActionMappingTests.swift` 到 pbxproj**

编辑 `FUnlock.xcodeproj/project.pbxproj`（四处）：
```
PBXBuildFile 区：
		RM0000020000000100000001 /* ReasonActionMappingTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = RM0000010000000100000001 /* ReasonActionMappingTests.swift */; };
PBXFileReference 区：
		RM0000010000000100000001 /* ReasonActionMappingTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ReasonActionMappingTests.swift; sourceTree = "<group>"; };
PBXGroup — FUnlockTests 组（在 `DT0000010000000100000001 /* DecisionLoggerTests.swift */,` 之后）：
				RM0000010000000100000001 /* ReasonActionMappingTests.swift */,
PBXSourcesBuildPhase — FUnlockTests target（在 `DT0000020000000100000001 /* DecisionLoggerTests.swift in Sources */,` 之后）：
				RM0000020000000100000001 /* ReasonActionMappingTests.swift in Sources */,
```

- [ ] **Step 4: 运行定向测试（应先全绿）**

Run:
```
xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -only-testing:FUnlockTests/ReasonActionMappingTests -only-testing:FUnlockTests/DecisionLoggerTests CODE_SIGNING_ALLOWED=NO
```
Expected: 3 + 8 用例全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add FUnlock/DecisionLogger.swift FUnlockTests/ReasonActionMappingTests.swift FUnlock.xcodeproj/project.pbxproj
git commit -m "feat: 决策原因→文案/操作映射（编译期全覆盖 + 映射测试）"
```

---

### Task 3: FUnManager 埋点（17 处 SKIP 分支 + 结果 + 系统事件）

**Files:**
- Modify: `FUnlock/FUnManager.swift`
- Modify: `FUnlockTests/DecisionLoggerTests.swift`（追加 `UnlockDecisionInstrumentationTests`）
- Test: `FUnlockTests/DecisionLoggerTests.swift`

**Interfaces:**
- Consumes: `DecisionLogger`（Task 1）、`DecisionReason`（Task 1）
- Produces: `FUnManager.init(fun:nowProvider:decisionLogger:)`、`FUnManager.attemptAutoUnlock()` 改为 internal（`private` → `func`，仅为了测试驱动决策路径）

**背景约束：** 每个 SKIP 分支在保留原 `Log.sm.debug` 的同时追加一次 `recordUnlock(...)`。`attemptAutoUnlock()` 从 `private` 改为 internal（项目内 `@testable` 测试可直接调用，参考现有测试对 `FUn` 的真实使用）。

- [ ] **Step 1: 给 FUnManager 加 `decisionLogger` 依赖注入**

在 `FUnManager.swift` 的 `// MARK: Dependencies` 区（`let stateMachine: FUnlockStateMachine` 之后）新增属性：
```swift
    let decisionLogger: DecisionLogger
```

把 init 签名与内部赋值改为（`FUnManager.swift:157`）：
```swift
    init(fun: FUn, nowProvider: @escaping () -> Date = { Date() }, decisionLogger: DecisionLogger = .shared) {
        self.fun = fun
        self.stateMachine = FUnlockStateMachine(nowProvider: nowProvider)
        self.nowProvider = nowProvider
        self.decisionLogger = decisionLogger
        self.lockRSSI = fun.lockRSSI
        self.unlockRSSI = fun.unlockRSSI
```

在 `// MARK: - 冷却与缓冲策略` 区（`lastUnlockTime` 声明之后）新增私有记录辅助方法：
```swift
    // MARK: - 决策记录辅助

    private func recordUnlock(_ outcome: DecisionOutcome = .skipped, reason: DecisionReason?, detail: String = "") {
        decisionLogger.record(category: .unlock, outcome: outcome, reason: reason,
                              rssi: rssi, device: monitoredDeviceName,
                              screen: state.screen.description, detail: detail)
    }

    private func recordLock(_ reason: DecisionReason, detail: String = "") {
        decisionLogger.record(category: .lock, outcome: .success, reason: reason,
                              rssi: rssi, device: monitoredDeviceName,
                              screen: state.screen.description, detail: detail)
    }

    private func recordSystem(_ reason: DecisionReason) {
        decisionLogger.record(category: .system, outcome: .info, reason: reason,
                              rssi: rssi, device: monitoredDeviceName,
                              screen: state.screen.description)
    }

    private func recordUser(_ reason: DecisionReason) {
        decisionLogger.record(category: .user, outcome: .success, reason: reason,
                              rssi: rssi, device: monitoredDeviceName,
                              screen: state.screen.description)
    }
```

- [ ] **Step 2: `attemptAutoUnlock` 改 internal**

`FUnManager.swift:478`：
```swift
    private func attemptAutoUnlock() {
```
改为：
```swift
    func attemptAutoUnlock() {
```

- [ ] **Step 3: 给每个 SKIP 分支加记录（逐条替换，原日志行保留）**

下列每项均为「在 `Log.sm.debug(...)` 之后补一行 `recordUnlock(...)`」；对多行 guard 用替换。逐条应用：

**(1) `FUnManager.swift:483` 无在场**
```swift
        guard fun.presence else { Log.sm.debug("SKIP: no presence"); recordUnlock(reason: .noPresence); return }
```

**(2) `FUnManager.swift:484` 自动解锁禁用**
```swift
        guard fun.unlockRSSI != fun.UNLOCK_DISABLED else { Log.sm.debug("SKIP: unlock disabled"); recordUnlock(reason: .unlockDisabled); return }
```

**(3) `FUnManager.swift:486` 状态机未就绪**
```swift
        guard stateMachine.canAttemptUnlock else { Log.sm.debug("SKIP: state machine not ready (degraded/cooldown)"); recordUnlock(reason: .stateMachineBlocked); return }
```

**(4) `FUnManager.swift:489-493` 锁屏缓冲**
```swift
        let sinceLock = now.timeIntervalSince(lastLockTime)
        guard sinceLock >= lockBufferDuration else {
            Log.sm.debug("SKIP: lock buffer active (locked \(String(format: "%.1f", sinceLock))s ago)")
            recordUnlock(reason: .lockBufferActive, detail: "locked \(String(format: "%.1f", sinceLock))s ago")
            return
        }
```

**(5) `FUnManager.swift:496-499` 解锁冷却**
```swift
        if isUnlockCooldownActive() {
            Log.sm.debug("SKIP: unlock cooldown active (\(String(format: "%.1f", self.now.timeIntervalSince(self.lastUnlockTime)))s since last unlock)")
            recordUnlock(reason: .unlockCooldownActive, detail: "\(String(format: "%.1f", self.now.timeIntervalSince(self.lastUnlockTime)))s since last unlock")
            return
        }
```

**(6) `FUnManager.swift:502-508` Wi-Fi 暂停**
```swift
        if prefs.bool(forKey: "pauseOnWiFi") {
            let targetSSID = prefs.string(forKey: "pauseOnWiFiSSID") ?? ""
            if !targetSSID.isEmpty, let currentSSID = WiFiMonitor.shared.currentSSID, currentSSID == targetSSID {
                Log.sm.debug("SKIP: pauseOnWiFi matched SSID '\(targetSSID)'")
                recordUnlock(reason: .wifiPaused, detail: "SSID '\(targetSSID)'")
                return
            }
        }
```

**(7) `FUnManager.swift:510-513` 手动锁屏保护**
```swift
        if prefs.bool(forKey: "manualLockNoAutoUnlock") && state.intent.isManualLockActive {
            Log.sm.debug("SKIP: manualLock active, waiting for manual unlock")
            recordUnlock(reason: .manualLockActive)
            return
        }
```

**(8) `FUnManager.swift:531` 并行唤醒时系统未就绪**
```swift
                    guard self.isSystemReadyForUnlock() else { Log.sm.debug("SKIP: system not ready in parallel wake task"); recordUnlock(reason: .systemNotReady); return }
```

**(9) `FUnManager.swift:540` 唤醒不自动解锁**
```swift
        guard !self.prefs.bool(forKey: "wakeWithoutUnlocking") else { Log.sm.debug("SKIP: wakeWithoutUnlocking"); recordUnlock(reason: .wakeWithoutUnlocking); return }
```

**(10) `FUnManager.swift:541` 仍处于显示器休眠**
```swift
        guard self.state.screen != .displaySleeping else { Log.sm.debug("SKIP: still displaySleeping"); recordUnlock(reason: .displaySleeping); return }
```

**(11) `FUnManager.swift:550` 延迟解锁任务内系统未就绪**
```swift
            guard self.isSystemReadyForUnlock() else { Log.sm.debug("SKIP: system not ready in delayed unlock task"); recordUnlock(reason: .systemNotReady); return }
```

**(12) `FUnManager.swift:563` 屏幕已解锁**
```swift
        guard locked else { Log.sm.debug("SKIP: screen not locked"); recordUnlock(.info, reason: .screenNotLocked, detail: "already unlocked"); return }
```

**(13) `FUnManager.swift:567` tryUnlock 内状态机拒绝**
```swift
        guard smAllowed else { Log.sm.debug("SKIP: state machine denied unlock attempt"); recordUnlock(reason: .stateMachineBlocked); return }
```

**(14) `FUnManager.swift:570-573` 刚解锁过**
```swift
        guard sinceUnlock > 3 else {
            Log.sm.debug("SKIP: recently unlocked (\(String(format:"%.1f", sinceUnlock))s ago)")
            recordUnlock(reason: .recentlyUnlocked, detail: "\(String(format: "%.1f", sinceUnlock))s ago")
            return
        }
```

**(15) `FUnManager.swift:574-582` Keychain 错误 / 无密码**（替换整个 if/else 块）
```swift
        guard case .success(let password) = fetchResult, let password = password else {
            if case .failure(let error) = fetchResult {
                Log.sm.debug("SKIP: Keychain error - \(error)")
                recordUnlock(reason: .keychainColdBoot, detail: "\(error)")
            } else {
                Log.sm.debug("SKIP: no password")
                recordUnlock(reason: .noPassword)
            }
            return
        }
```

**(16) `FUnManager.swift:588` 注入前安全校验失败**
```swift
        guard secure else { Log.sm.debug("SKIP: screen no longer secure for injection"); recordUnlock(reason: .notSecureForInjection); return }
```

**(17) `FUnManager.swift:600-602` CGEvent 注入失败 → AX 权限被撤**
```swift
        if !posted {
            Log.sm.debug("WARN: CGEvent post failed — Accessibility permission likely revoked")
            recordUnlock(.blocked, reason: .axRevoked, detail: "CGEvent post failed")
            sys.showAXRevokedAlertIfNeeded(lastAlertTime: &lastAXRevokedAlertTime)
        } else {
```

**(18) 注入成功 → 乐观解锁成功（`FUnManager.swift:604` `recordUnlockAttempt()` 之后加一行）**
```swift
            recordUnlockAttempt()
            recordUnlock(.success, reason: .unlockSuccess)
```

**(19) 双验证仍锁定（`FUnManager.swift:633` `Log.sm.debug("dual verify: still locked ...")` 之后加一行）**
```swift
            recordUnlock(.failed, reason: .unlockFailed, detail: "attempt #\(self.consecutiveUnlockAttempts)/\(self.maxUnlockAttempts)")
```

**(20) 达到失败上限 → 密码不匹配（`FUnManager.swift:645-648`，在 `showPasswordMismatchAlert()` 前加一行）**
```swift
                        if self.consecutiveUnlockAttempts >= self.maxUnlockAttempts {
                            recordUnlock(.blocked, reason: .passwordMismatch, detail: "too many failed attempts")
                            sys.showPasswordMismatchAlert()
                            self.consecutiveUnlockAttempts = 0
                        }
```

- [ ] **Step 4: 给 lock / system / user 事件加记录**

**(a) `onDeviceLeft`（`FUnManager.swift:357-358` 的 `ScriptRunner` 两行之后加）：**
```swift
        ScriptRunner.shared.runScript(reason, rssi: rssi, deviceName: monitoredDeviceName)
        ScriptRunner.shared.logEvent("locked: \(reason)", rssi: rssi)
        let lockReason: DecisionReason = (reason == "lost") ? .lockedLost : .lockedAway
        recordLock(lockReason)
```

**(b) `onDisplaySleep`（`FUnManager.swift:212` 日志行之后加）：**
```swift
        Log.sm.debug("[SM] displaySleep")
        recordSystem(.displaySleep)
```

**(c) `onDisplayWake`（`FUnManager.swift:217` 日志行之后加）：**
```swift
        Log.sm.debug("[SM] displayWake")
        recordSystem(.displayWake)
```

**(d) `onSystemSleep`（`FUnManager.swift:229` 日志行之后加）：**
```swift
        Log.sm.debug("[SM] systemSleep")
        recordSystem(.systemSleep)
```

**(e) `onSystemWake`（`FUnManager.swift:235` 日志行之后加）：**
```swift
        Log.sm.debug("[SM] systemWake")
        recordSystem(.systemWake)
```

**(f) `onUnlock`（`FUnManager.swift:263` `lastUnlockTime = now` 之后加）：**
```swift
        lastUnlockTime = now
        recordUser(.userUnlocked)
```

**(g) `onSystemScreenLocked`（`FUnManager.swift:311` else 分支的 `state.intent = .manualLock(deadline: deadline)` 之后加）：**
```swift
            state.intent = .manualLock(deadline: deadline)
            recordUser(.userLocked)
```

- [ ] **Step 5: 追加集成测试到 `FUnlockTests/DecisionLoggerTests.swift`（文件末尾追加，完整代码）**

```swift
/// 集成测试：驱动 FUnManager 决策路径，断言 SKIP 分支产生对应决策事件
@MainActor
final class UnlockDecisionInstrumentationTests: XCTestCase {
    private var tempDir: URL!
    private var logger: DecisionLogger!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnlockDecisionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        logger = DecisionLogger(testLogDirectory: tempDir, nowProvider: { Date() })
    }

    override func tearDownWithError() throws {
        logger = nil
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testNoPresenceRecordsDecision() {
        let fun = FUn()
        let manager = FUnManager(fun: fun, decisionLogger: logger)
        fun.presence = false
        manager.attemptAutoUnlock()
        XCTAssertEqual(logger.events.last?.reason, .noPresence)
    }

    func testUnlockDisabledRecordsDecision() {
        let fun = FUn()
        let manager = FUnManager(fun: fun, decisionLogger: logger)
        fun.presence = true
        fun.unlockRSSI = fun.UNLOCK_DISABLED
        manager.attemptAutoUnlock()
        XCTAssertEqual(logger.events.last?.reason, .unlockDisabled)
    }
}
```

> 说明：`FUn()` 会创建真实 `CBCentralManager`（现有 `FUnlockTests.swift` 已接受该代价）。`attemptAutoUnlock` 首个守卫即 `presence`，因此 `testNoPresence` 在触及 `AXIsProcessTrusted()` 之前就返回，行为确定。`testUnlockDisabled` 的第二个守卫在 `AXIsProcessTrusted()` 调用之后（`FUnManager.swift:482`），测试环境返回 false 或 true 均不影响结果——`unlockRSSI == UNLOCK_DISABLED` 守卫在尝试解锁前短路。

- [ ] **Step 6: 编译 + 定向测试**

Run:
```
xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: 编译通过（确认 20 处埋点后无语法错误）。

Run:
```
xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' -only-testing:FUnlockTests/UnlockDecisionInstrumentationTests -only-testing:FUnlockTests/DecisionLoggerTests CODE_SIGNING_ALLOWED=NO
```
Expected: 2 + 8 用例全部 PASS。

- [ ] **Step 7: Commit**

```bash
git add FUnlock/FUnManager.swift FUnlockTests/DecisionLoggerTests.swift
git commit -m "feat: FUnManager 决策路径埋点（17 处 SKIP + 结果 + 系统/用户事件）"
```

---

### Task 4: 诊断 Tab UI

**Files:**
- Create: `FUnlock/DiagnosticsView.swift`
- Modify: `FUnlock/MenuDashboardView.swift`
- Modify: `FUnlock/SystemInteractionService.swift`
- Modify: `FUnlock.xcodeproj/project.pbxproj`（注册 `DiagnosticsView.swift`）

**Interfaces:**
- Consumes: `DecisionLogger.shared`、`DecisionEvent`、`DecisionReason.titleKey/action`、`ActionHint.labelKey`（Task 1-2）、`FUnManager.setUnlockRSSI`、`FUnManager.fun.UNLOCK_DISABLED`、`SystemInteractionService.shared.openAccessibilitySettings()`（本任务新增）、`SecurityService.shared.askPassword()`、`FUnManager.stateMachine.resetToActive()`
- Produces: `DiagnosticsView(manager:onNavigate:)`；`MenuTab.diagnostics`；`DecisionCategory.filterKey`

- [ ] **Step 1: 创建 `FUnlock/DiagnosticsView.swift`（完整文件）**

```swift
// DiagnosticsView.swift
// 「诊断」Tab：解锁/锁屏决策时间线，基于 DecisionLogger 渲染原因与操作按钮

import SwiftUI

extension DecisionCategory {
    /// 过滤器 chip 的本地化 key
    var filterKey: String {
        switch self {
        case .unlock: return "diagnostics_filter_unlock"
        case .lock: return "diagnostics_filter_lock"
        case .system: return "diagnostics_filter_system"
        case .user: return "diagnostics_filter_user"
        }
    }
}

struct DiagnosticsView: View {
    @ObservedObject var manager: FUnManager
    @ObservedObject var logger: DecisionLogger
    let onNavigate: (MenuTab) -> Void

    @State private var filter: DecisionCategory?

    init(manager: FUnManager, logger: DecisionLogger = DecisionLogger.shared,
         onNavigate: @escaping (MenuTab) -> Void) {
        self.manager = manager
        self.logger = logger
        self.onNavigate = onNavigate
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private var filteredEvents: [DecisionEvent] {
        guard let filter else { return logger.events }
        return logger.events.filter { $0.category == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            filterChips
            if filteredEvents.isEmpty {
                emptyState
            } else {
                timeline
            }
            clearFooter
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if logger.events.isEmpty { logger.loadHistory() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(t("diagnostics"))
                    .font(.system(size: 15, weight: .bold))
                Text(t("diagnostics_subtitle"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - 过滤器

    private var filterChips: some View {
        HStack(spacing: 6) {
            chipButton(title: t("diagnostics_all"), isSelected: filter == nil) {
                filter = nil
            }
            ForEach(DecisionCategory.allCases, id: \.self) { cat in
                chipButton(title: t(cat.filterKey), isSelected: filter == cat) {
                    filter = cat
                }
            }
        }
    }

    private func chipButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 时间线

    private var timeline: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(filteredEvents.reversed()) { event in
                row(for: event)
            }
        }
    }

    private func row(for event: DecisionEvent) -> some View {
        let iconInfo = Self.icon(for: event)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: iconInfo.0)
                    .font(.system(size: 12))
                    .foregroundColor(iconInfo.1)
                    .frame(width: 18)
                Text(t(event.reason?.titleKey ?? event.outcome.rawValue))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(Self.timeString(event.timestamp))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            if !event.detail.isEmpty {
                Text(event.detail)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if let rssi = event.rssi {
                    Text("\(rssi) dBm").font(.system(size: 11)).foregroundColor(.secondary)
                }
                if let device = event.device {
                    Text(device).font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                if let action = event.reason?.action {
                    Button(t(action.labelKey)) { perform(action) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(7)
    }

    // MARK: - 操作

    private func perform(_ hint: ActionHint) {
        switch hint {
        case .lowerUnlockThreshold:
            let current = manager.unlockRSSI
            let next = current == manager.fun.UNLOCK_DISABLED ? -95 : max(current - 5, -100)
            manager.setUnlockRSSI(next)
        case .openAccessibilitySettings:
            SystemInteractionService.shared.openAccessibilitySettings()
        case .reEnterPassword:
            SecurityService.shared.askPassword()
        case .goToTab(let tabKey):
            if let tab = MenuTab(rawValue: tabKey) { onNavigate(tab) }
        case .resetStateMachine:
            manager.stateMachine.resetToActive()
        }
    }

    // MARK: - 空状态 / 清空

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 26))
                .foregroundColor(.secondary)
            Text(t("diagnostics_empty"))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Text(t("diagnostics_empty_hint"))
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var clearFooter: some View {
        HStack {
            Spacer()
            Button(t("diagnostics_clear")) { logger.clear() }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 渲染辅助

    static func icon(for event: DecisionEvent) -> (String, Color) {
        switch (event.category, event.outcome) {
        case (.unlock, .success): return ("lock.open.fill", .green)
        case (.unlock, .failed), (.unlock, .blocked): return ("exclamationmark.triangle.fill", .red)
        case (.unlock, .skipped): return ("lock.open", .secondary)
        case (.lock, .success): return ("lock.fill", .orange)
        case (.lock, _): return ("lock", .secondary)
        case (.system, _): return ("power", .blue)
        case (.user, _): return ("person.fill", .teal)
        }
    }

    static func timeString(_ date: Date) -> String {
        if date > Date().addingTimeInterval(-24 * 3600) {
            return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        }
        return date.formatted(.dateTime.month().day().hour().minute())
    }
}
```

- [ ] **Step 2: 给 `MenuDashboardView` 加第 8 个 Tab**

**（a）`MenuTab` 枚举（`MenuDashboardView.swift:10-32`）：**
```swift
    case network    = "network"
    case config     = "config"
```
改为：
```swift
    case network    = "network"
    case config     = "config"
    case diagnostics = "diagnostics"
```
并给 `icon` switch 加 case（`case .config: return "folder"` 之后）：
```swift
        case .diagnostics: return "waveform.path.ecg"
```

**（b）`contentView` 的 switch（`MenuDashboardView.swift:254-262`）：**
```swift
                case .network:   networkContent
                case .config:    configContent
```
改为：
```swift
                case .network:   networkContent
                case .config:    configContent
                case .diagnostics: DiagnosticsView(manager: manager, onNavigate: { selectedTab = $0 })
```

- [ ] **Step 3: 给 `SystemInteractionService` 加 `openAccessibilitySettings()`**

在 `FUnlock/SystemInteractionService.swift` 的 `showAXRevokedAlertIfNeeded` 方法之后追加：
```swift
    /// 打开系统「辅助功能」权限设置页
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
```
并把 `showAXRevokedAlertIfNeeded` 内部（`SystemInteractionService.swift:506-510`）替换为复用：
```swift
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
```

- [ ] **Step 4: 注册 `DiagnosticsView.swift` 到 pbxproj**

编辑 `FUnlock.xcodeproj/project.pbxproj`（四处）：
```
PBXBuildFile 区：
		DV0000020000000100000001 /* DiagnosticsView.swift in Sources */ = {isa = PBXBuildFile; fileRef = DV0000010000000100000001 /* DiagnosticsView.swift */; };
PBXFileReference 区：
		DV0000010000000100000001 /* DiagnosticsView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DiagnosticsView.swift; sourceTree = "<group>"; };
PBXGroup — FUnlock 组（在 `DL0000010000000100000001 /* DecisionLogger.swift */,` 之后）：
				DV0000010000000100000001 /* DiagnosticsView.swift */,
PBXSourcesBuildPhase — FUnlock target（在 `DL0000020000000100000001 /* DecisionLogger.swift in Sources */,` 之后）：
				DV0000020000000100000001 /* DiagnosticsView.swift in Sources */,
```

- [ ] **Step 5: 编译验证**

Run:
```
xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: 编译通过（若 `date.formatted(.dateTime...)` 在部署目标报 deprecation 警告，属预期，不影响构建）。

- [ ] **Step 6: Commit**

```bash
git add FUnlock/DiagnosticsView.swift FUnlock/MenuDashboardView.swift FUnlock/SystemInteractionService.swift FUnlock.xcodeproj/project.pbxproj
git commit -m "feat: 新增「诊断」Tab 决策时间线 UI + 上下文操作按钮"
```

---

### Task 5: 本地化（Base + zh-Hans）

**Files:**
- Modify: `FUnlock/Base.lproj/Localizable.strings`（追加）
- Modify: `FUnlock/zh-Hans.lproj/Localizable.strings`（追加）

> 说明：英文 = `Base.lproj`（本项目无 `en.lproj`）。其余语言（ja/de/sv/nb/da/tr）不新增 key，缺失时 `NSLocalizedString` 自动回退 Base。

- [ ] **Step 1: 追加英文 key 到 `FUnlock/Base.lproj/Localizable.strings`（文件末尾）**

```
"diagnostics" = "Diagnostics";
"diagnostics_subtitle" = "FUnlock decision timeline";
"diagnostics_all" = "All";
"diagnostics_filter_unlock" = "Unlock";
"diagnostics_filter_lock" = "Lock";
"diagnostics_filter_system" = "System";
"diagnostics_filter_user" = "User";
"diagnostics_empty" = "No decision records yet";
"diagnostics_empty_hint" = "Unlock and lock events are recorded here automatically.";
"diagnostics_clear" = "Clear Records";
"reason_no_presence" = "Device not in range";
"reason_signal_below_threshold" = "Signal below unlock threshold";
"reason_unlock_cooldown" = "Unlock cooldown active";
"reason_lock_buffer" = "Lock buffer active";
"reason_manual_lock" = "Manual lock protection active";
"reason_wifi_paused" = "Paused by matching Wi-Fi";
"reason_disabled" = "FUnlock is disabled";
"reason_unlock_disabled" = "Auto-unlock is disabled";
"reason_state_machine" = "Auto-unlock paused after repeated failures";
"reason_ax_revoked" = "Accessibility permission revoked";
"reason_no_password" = "No password stored";
"reason_keychain_cold_boot" = "Keychain locked after reboot";
"reason_not_secure" = "Screen not secure for injection";
"reason_display_sleeping" = "Display sleeping";
"reason_system_not_ready" = "System not ready";
"reason_wake_without_unlock" = "Wake without unlocking enabled";
"reason_recently_unlocked" = "Recently unlocked";
"reason_screen_not_locked" = "Screen already unlocked";
"reason_input_active" = "Input active, lock deferred";
"reason_grace_period" = "Lock grace period active";
"reason_signal_below_lock_threshold" = "Signal above lock threshold";
"reason_unlock_success" = "Unlocked";
"reason_unlock_failed" = "Unlock failed";
"reason_unlock_timeout" = "Unlock timed out";
"reason_password_mismatch" = "Password mismatch";
"reason_locked_away" = "Locked - device left";
"reason_locked_lost" = "Locked - device signal lost";
"reason_display_sleep" = "Display slept";
"reason_display_wake" = "Display woke";
"reason_system_sleep" = "System slept";
"reason_system_wake" = "System woke";
"reason_user_unlocked" = "Unlocked by user";
"reason_user_locked" = "Locked by user";
"action_lower_unlock_threshold" = "Lower unlock threshold";
"action_open_accessibility" = "Open Accessibility Settings";
"action_reenter_password" = "Re-enter Password";
"action_go_to_settings" = "Open Settings";
"action_reset_state_machine" = "Resume Auto-Unlock";
```

- [ ] **Step 2: 追加中文 key 到 `FUnlock/zh-Hans.lproj/Localizable.strings`（文件末尾）**

```
"diagnostics" = "诊断";
"diagnostics_subtitle" = "FUnlock 决策时间线";
"diagnostics_all" = "全部";
"diagnostics_filter_unlock" = "解锁";
"diagnostics_filter_lock" = "锁屏";
"diagnostics_filter_system" = "系统";
"diagnostics_filter_user" = "用户";
"diagnostics_empty" = "暂无决策记录";
"diagnostics_empty_hint" = "解锁和锁屏事件会自动记录在此。";
"diagnostics_clear" = "清空记录";
"reason_no_presence" = "设备不在范围内";
"reason_signal_below_threshold" = "信号未达解锁阈值";
"reason_unlock_cooldown" = "解锁冷却中";
"reason_lock_buffer" = "锁屏缓冲期内";
"reason_manual_lock" = "手动锁屏保护中";
"reason_wifi_paused" = "命中暂停 Wi-Fi";
"reason_disabled" = "FUnlock 已停用";
"reason_unlock_disabled" = "自动解锁已停用";
"reason_state_machine" = "连续失败后自动解锁已暂停";
"reason_ax_revoked" = "辅助功能权限被撤销";
"reason_no_password" = "未存储密码";
"reason_keychain_cold_boot" = "重启后钥匙串未解锁";
"reason_not_secure" = "当前界面不适合注入";
"reason_display_sleeping" = "显示器休眠中";
"reason_system_not_ready" = "系统未就绪";
"reason_wake_without_unlock" = "已启用唤醒不自动解锁";
"reason_recently_unlocked" = "刚刚解锁过";
"reason_screen_not_locked" = "屏幕已解锁";
"reason_input_active" = "输入活动中，暂缓锁屏";
"reason_grace_period" = "锁屏冷静期内";
"reason_signal_below_lock_threshold" = "信号高于锁屏阈值";
"reason_unlock_success" = "解锁成功";
"reason_unlock_failed" = "解锁失败";
"reason_unlock_timeout" = "解锁超时";
"reason_password_mismatch" = "密码不匹配";
"reason_locked_away" = "锁定 — 设备离开";
"reason_locked_lost" = "锁定 — 设备信号丢失";
"reason_display_sleep" = "显示器休眠";
"reason_display_wake" = "显示器唤醒";
"reason_system_sleep" = "系统休眠";
"reason_system_wake" = "系统唤醒";
"reason_user_unlocked" = "用户手动解锁";
"reason_user_locked" = "用户手动锁屏";
"action_lower_unlock_threshold" = "调低解锁阈值";
"action_open_accessibility" = "打开辅助功能设置";
"action_reenter_password" = "重新输入密码";
"action_go_to_settings" = "打开设置";
"action_reset_state_machine" = "恢复自动解锁";
```

- [ ] **Step 3: genstrings 校验 key 无遗漏**

Run:
```
genstrings -o /tmp/genstrings-check FUnlock/DiagnosticsView.swift FUnlock/DecisionLogger.swift FUnlock/FUnManager.swift
```
Expected: 生成文件中包含全部 `diagnostics_*` / `reason_*` / `action_*` key；与第 1/2 步新增的 key 集合一致（可用 `diff` 人工核对 key 名集合）。

- [ ] **Step 4: 编译验证 + Commit**

Run:
```
xcodebuild build -project FUnlock.xcodeproj -scheme FUnlock -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: Release 编译通过（确认 strings 无语法错误）。

```bash
git add FUnlock/Base.lproj/Localizable.strings FUnlock/zh-Hans.lproj/Localizable.strings
git commit -m "i18n: 新增诊断 Tab 文案（Base + zh-Hans，其余语言回退英文）"
```

---

### Task 6: 全量验证

**Files:**
- 无代码改动（验证 + 手动 QA）

- [ ] **Step 1: 全量单测**

Run:
```
xcodebuild test -project FUnlock.xcodeproj -scheme FUnlock -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```
Expected: 既有测试全部 PASS，新增 `DecisionLoggerTests`(8) + `ReasonActionMappingTests`(3) + `UnlockDecisionInstrumentationTests`(2) PASS，无新增失败。

- [ ] **Step 2: 手动 QA（真实 Mac 上运行 Debug 构建）**

逐项检查并在合适时机勾选：
- [ ] 侧边栏出现第 8 项「诊断」（图标 `waveform.path.ecg`），点击可进入。
- [ ] 空状态显示「暂无决策记录」。
- [ ] 设备远离再靠近：时间线出现「锁定 — 设备离开」→「解锁成功」，含 RSSI 与设备名。
- [ ] 在信号不足位置坐下：出现「信号未达解锁阈值」+「调低解锁阈值」按钮；点击后 `unlockRSSI` 降低 5，下次可解锁。
- [ ] 手动锁屏（⌘+Ctrl+Q）后设备靠近：出现「手动锁屏保护中」+「打开设置」按钮（跳「锁定」Tab）。
- [ ] 撤掉辅助功能权限后触发注入：出现「辅助功能权限被撤销」+「打开辅助功能设置」按钮（跳系统设置）。
- [ ] 重启 FUnlock：之前会话的决策记录仍在（跨启动持久化）。
- [ ] 触发大量同类事件（如持续不在场）：3 秒内只更新一条，不刷屏。
- [ ] 「清空记录」后时间线清空，重启后为空。
- [ ] 中文系统显示中文、日文系统回退英文，无 `key` 字面量。
- [ ] 确认 `~/Library/Logs/FUnlock/decisions.jsonl` 存在、可读、不含密码明文。
- [ ] 确认 `~/Library/Application Support/FUnlock/events.log` 内容与此功能无关（未被污染）。

- [ ] **Step 3: 收尾 Commit（如有 QA 期间的小修复）**

```bash
git add -A
git commit -m "chore: 诊断 Tab 手动 QA 修复"
```
（若 QA 无改动则跳过本步。）

---

## Self-Review

**Spec coverage:** 数据模型与原因分类 → Task 1（`DecisionEvent`/`DecisionReason`/`ActionHint`）+ Task 2（titleKey/action）；架构与数据流（ring 500 + JSONL + 轮转 + 同因合并 3s + 降级 + 测试注入）→ Task 1；FUnManager 埋点 → Task 3；诊断 Tab UI + 操作按钮 → Task 4；本地化 v1 只译 zh/en → Task 5；测试与验证 → Task 1/2/3/6。Spec 中「永久化失败静默降级」由 `try?`/FileHandle 静默路径实现（Task 1 `write`）；「隐私不落盘密码」由字段白名单 + Task 1 `testSerializedKeysAreWhitelisted` 保障。

**Placeholder scan:** 所有代码步骤均含完整代码或逐条精确替换。唯一依赖性说明为 Task 3 集成测试对真实 `FUn()` 的使用（与现有 `FUnlockTests` 一致，属已接受代价）。pbxproj 使用固定新 ID（`DL/DV/DT/RM` 前缀，24 字符，无冲突）。

**Type consistency:** `DecisionLogger.shared`（Task 1）被 Task 3/4 使用；`recordUnlock(_ outcome:reason:detail:)` 签名在 Task 3 全部 20 处一致；`DecisionReason.signalBelowThreshold.action == .lowerUnlockThreshold`（Task 2）与 `DiagnosticsView.perform`（Task 4）的 case 一一对应；`FUn.UNLOCK_DISABLED`（值 1，`FUn.swift:282`）在 Task 4 通过 `manager.fun.UNLOCK_DISABLED` 访问；`MenuTab(rawValue:)` 与 `goToTab(String)` 中传入的 `"lock"/"network"/"unlock"/"basic"` 均为 `MenuTab` 现有 rawValue（Task 4 已核对 `MenuDashboardView.swift:10-17`）。`ActionHint.labelKey` 引用的 5 个 action key 均在 Task 5 中补齐。
