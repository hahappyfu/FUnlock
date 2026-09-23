// FUnlockTests/LogRotationTests.swift
// 日志滚动（LogRotator）单元测试 + 四个日志写入模块的集成验证：
// DebugLog(debug.log) / timingLog(timing.log) / TelemetryLogger(shadow_telemetry.csv) / ScriptRunner(events.log)

import XCTest
@testable import FUnlock

// MARK: - LogRotator 核心逻辑

final class LogRotatorTests: XCTestCase {
    private var tempDir: URL!
    private var file: URL!

    private var backup: URL {
        tempDir.appendingPathComponent("test.log.old")
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogRotatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        file = tempDir.appendingPathComponent("test.log")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDir.path)
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func writeFile(_ bytes: Int) throws {
        try Data(repeating: 0x41, count: bytes).write(to: file)
    }

    func testNoRotationBelowThreshold() throws {
        try writeFile(100)
        XCTAssertFalse(LogRotator.rotateIfNeeded(url: file, maxBytes: 1024))
        XCTAssertEqual(try Data(contentsOf: file).count, 100, "未超阈值不得改动原文件")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testRotatesAboveThreshold() throws {
        try writeFile(2048)
        XCTAssertTrue(LogRotator.rotateIfNeeded(url: file, maxBytes: 1024))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "轮转后应新建空文件")
        XCTAssertEqual(try Data(contentsOf: file).count, 0)
        XCTAssertEqual(try Data(contentsOf: backup).count, 2048, "原内容应完整归档到 .old")
    }

    func testExistingBackupIsOverwritten() throws {
        try Data("stale-backup".utf8).write(to: backup)
        try writeFile(2048)
        XCTAssertTrue(LogRotator.rotateIfNeeded(url: file, maxBytes: 1024))
        XCTAssertEqual(try Data(contentsOf: backup).count, 2048, "旧备份应被覆盖")
    }

    func testExactlyAtThresholdNotRotated() throws {
        try writeFile(1024)
        XCTAssertFalse(LogRotator.rotateIfNeeded(url: file, maxBytes: 1024), "严格大于阈值才轮转")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testMissingFileIsNoOp() {
        let missing = tempDir.appendingPathComponent("missing.log")
        XCTAssertFalse(LogRotator.rotateIfNeeded(url: missing, maxBytes: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "缺失文件不得被凭空创建")
    }

    func testDirectoryURLIsIgnored() throws {
        let dir = tempDir.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertFalse(LogRotator.rotateIfNeeded(url: dir, maxBytes: 1), "目录不参与轮转")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func testRotationFailureDegradesGracefully() throws {
        try XCTSkipIf(getuid() == 0, "root 不受目录权限限制")
        try writeFile(2048)
        // 目录只读 → rename 失败 → 静默返回 false，原文件不受损、不崩溃
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tempDir.path)
        XCTAssertFalse(LogRotator.rotateIfNeeded(url: file, maxBytes: 1024))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempDir.path)
        XCTAssertEqual(try Data(contentsOf: file).count, 2048, "轮转失败不得破坏原文件")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }
}

// MARK: - DebugLog（debug.log）

final class DebugLogRotationTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugLogRotationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        DebugLog.testLogDirectory = tempDir
        DebugLog.maxFileSize = 1024
    }

    override func tearDownWithError() throws {
        DebugLog.flush()
        DebugLog.testLogDirectory = nil
        DebugLog.maxFileSize = LogRotator.defaultMaxBytes
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testRotatesAndKeepsWriting() throws {
        let big = String(repeating: "x", count: 1500)
        DebugLog.log(component: "rotation-test", "big-one-\(big)")
        DebugLog.flush()
        DebugLog.log(component: "rotation-test", "after-rotation-marker")
        DebugLog.flush()

        let log = DebugLog.logFileURL
        let backup = tempDir.appendingPathComponent("debug.log.old")
        XCTAssertEqual(log.path, tempDir.appendingPathComponent("debug.log").path,
                       "测试路径不得落到真实日志目录")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "超限后应生成 .old 归档")

        let backupContent = try String(contentsOf: backup, encoding: .utf8)
        let currentContent = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(backupContent.contains("big-one-"), "旧内容应归档到 .old")
        XCTAssertTrue(currentContent.contains("after-rotation-marker"), "轮转后应继续写入新文件")
        XCTAssertFalse(currentContent.contains("big-one-"), "当前文件不应残留已归档内容")
    }
}

// MARK: - timingLog（timing.log）

final class TimingLogRotationTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimingLogRotationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        configureTimingLogForTesting(directory: tempDir, maxBytes: 1024)
    }

    override func tearDownWithError() throws {
        configureTimingLogForTesting(directory: nil)   // 关闭缓存句柄并恢复真实路径
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testRotatesAndKeepsHandleUsable() throws {
        let big = String(repeating: "y", count: 1500)
        timingLog("big-timing-\(big)")
        timingLog("after-rotation-timing")   // 写入前检测到超限 → 先轮转再写入新文件

        let log = tempDir.appendingPathComponent("timing.log")
        let backup = tempDir.appendingPathComponent("timing.log.old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "超限后应生成 .old 归档")

        let backupContent = try String(contentsOf: backup, encoding: .utf8)
        let currentContent = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(backupContent.contains("big-timing-"))
        XCTAssertTrue(currentContent.contains("after-rotation-timing"), "轮转后缓存句柄应恢复可写")
        XCTAssertFalse(currentContent.contains("big-timing-"))
    }
}

// MARK: - TelemetryLogger（shadow_telemetry.csv）

final class TelemetryLogRotationTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TelemetryLogRotationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        TelemetryLogger.shared.testLogDirectory = tempDir
        TelemetryLogger.shared.maxFileSize = 256
    }

    override func tearDownWithError() throws {
        TelemetryLogger.shared.testLogDirectory = nil
        TelemetryLogger.shared.maxFileSize = LogRotator.defaultMaxBytes
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func logOne(_ model: String) {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: model,
            rawRSSI: -60, kalmanRSSI: -60, effectiveRSSI: -60,
            slope: 0, isAnomalous: false)
    }

    func testRotatesToOldAndRewritesHeader() throws {
        for i in 0..<4 { logOne("pad-\(i)") }

        let log = TelemetryLogger.shared.testLogFile
        let backup = tempDir.appendingPathComponent("shadow_telemetry.csv.old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "超限后应生成 .old 归档")

        let backupContent = try String(contentsOf: backup, encoding: .utf8)
        let currentContent = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(backupContent.contains("pad-0"), "最早记录应进入 .old")
        XCTAssertTrue(currentContent.hasPrefix("Timestamp,"), "轮转后的新文件应重写 CSV 表头")
        XCTAssertTrue(currentContent.contains("pad-3"), "轮转后应继续写入新文件")
        XCTAssertFalse(currentContent.contains("pad-0"), "当前文件不应残留已归档记录")
    }
}

// MARK: - ScriptRunner（events.log）

final class ScriptRunnerLogRotationTests: XCTestCase {
    private var tempDir: URL!
    private var runner: ScriptRunner!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScriptRunnerLogRotationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        runner = ScriptRunner(dedupWindow: 0, nowProvider: { Date() })
        runner.testLogDirectory = tempDir
        runner.maxFileSize = 1024
    }

    override func tearDownWithError() throws {
        runner = nil
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testEventsLogRotatesToOld() throws {
        let big = String(repeating: "z", count: 1500)
        _ = runner.logEventIfNeeded("big-event", rssi: -50, extraFields: ["pad": big])
        _ = runner.logEventIfNeeded("after-rotation-event", rssi: -60)

        let log = tempDir.appendingPathComponent("events.log")
        let backup = tempDir.appendingPathComponent("events.log.old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "超限后应生成 .old 归档")

        let backupContent = try String(contentsOf: backup, encoding: .utf8)
        let currentContent = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(backupContent.contains("big-event"))
        XCTAssertTrue(currentContent.contains("after-rotation-event"), "轮转后应继续写入新文件")
        XCTAssertFalse(currentContent.contains("big-event"))
    }
}
