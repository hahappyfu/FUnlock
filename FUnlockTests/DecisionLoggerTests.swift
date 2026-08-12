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

    func testCoalescedEventNotAppendedToFile() {
        // 合并事件不应追加写盘，保证重启后 readTail 不会载入重复记录
        logger.record(category: .user, outcome: .success, reason: .userLocked)
        currentTime = currentTime.addingTimeInterval(0.01)
        logger.record(category: .user, outcome: .success, reason: .userLocked)
        logger.flushSync()
        let reloaded = DecisionLogger.readTail(from: logger.logFile, max: 100)
        XCTAssertEqual(reloaded.count, 1, "合并事件不得写入重复行")
    }

    func testReasonChangeNeverCoalesced() {
        logger.record(category: .unlock, outcome: .skipped, reason: .noPresence)
        currentTime = currentTime.addingTimeInterval(1)
        logger.record(category: .unlock, outcome: .skipped, reason: .signalBelowThreshold)
        XCTAssertEqual(logger.events.count, 2)
    }

    func testRingCapacityRespected() {
        // 使用不同原因避免同因合并
        let reasons: [DecisionReason] = [.noPresence, .signalBelowThreshold, .unlockCooldownActive,
                                         .lockBufferActive, .manualLockActive]
        for i in 0..<600 {
            currentTime = currentTime.addingTimeInterval(1)
            let reason = reasons[i % reasons.count]
            logger.record(category: .unlock, outcome: .skipped, reason: reason)
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

@MainActor
final class UnlockDecisionInstrumentationTests: XCTestCase {
    var logger: DecisionLogger!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnlockDecisionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        logger = DecisionLogger(testLogDirectory: tempDir)
    }

    override func tearDown() {
        logger.clear()
        logger = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func runAttempt(_ mutate: (FUnManager) -> Void) throws -> DecisionLogger {
        let fun = FUn()
        let manager = FUnManager(fun: fun, nowProvider: { Date() }, decisionLogger: logger)
        mutate(manager)
        manager.attemptAutoUnlock()
        return logger
    }

    func testNoPresenceRecordsDecision() throws {
        let events = try runAttempt { $0.fun.presence = false }
        let unlockEvents = events.events.filter { $0.category == .unlock }
        XCTAssertFalse(unlockEvents.isEmpty, "presence=false 必须记录解锁决策")
        XCTAssertEqual(unlockEvents.last?.outcome, .skipped)
        XCTAssertEqual(unlockEvents.last?.reason, .noPresence)
    }

    func testUnlockDisabledRecordsDecision() throws {
        // unlockRSSI == UNLOCK_DISABLED 时 onDeviceApproached 记录 .unlockDisabled 事件
        // 需要先设置 presence = true，否则会先记录 .noPresence
        let events = try runAttempt {
            $0.fun.presence = true
            $0.fun.unlockRSSI = 1 // UNLOCK_DISABLED = 1
        }
        let unlockEvents = events.events.filter { $0.category == .unlock }
        XCTAssertFalse(unlockEvents.isEmpty, "UNLOCK_DISABLED 时必须记录解锁决策")
        XCTAssertEqual(unlockEvents.last?.outcome, .skipped)
        XCTAssertEqual(unlockEvents.last?.reason, .unlockDisabled)
    }

    func testManualUnlockRecordsUserUnlocked() throws {
        // 手动解锁（isAutoUnlocking = false）：onUnlock 应记录 userUnlocked，
        // 防止修复自动解锁误标后把手动解锁分支也误删
        let fun = FUn()
        let manager = FUnManager(fun: fun, nowProvider: { Date() }, decisionLogger: logger)
        manager.onUnlock()
        let userEvents = logger.events.filter { $0.category == .user }
        XCTAssertTrue(userEvents.contains { $0.reason == .userUnlocked },
                      "手动解锁必须记录 userUnlocked")
    }
}
