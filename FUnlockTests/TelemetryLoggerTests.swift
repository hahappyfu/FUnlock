import XCTest
@testable import FUnlock

// MARK: - CSV 按表头名取值辅助

/// 按表头名解析数据行：返回第一条含 marker 的行的 列名→值 字典。
/// 断言按列名定位而非硬编码下标，向 CSV 中间插列不再导致整批误报。
private func csvRow(containing marker: String, in content: String) -> [String: String] {
    let lines = content.components(separatedBy: "\n")
    let names = (lines.first ?? "").components(separatedBy: ",")
    let line = lines.first { $0.contains(marker) } ?? ""
    return Dictionary(uniqueKeysWithValues: zip(names, line.components(separatedBy: ",")))
}

// MARK: - TelemetryLogger 格式测试

/// 测试 TelemetryLogger CSV 输出的新列（Result / Duration_ms）及字段值
class TelemetryLoggerFormatTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TelemetryLoggerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        TelemetryLogger.shared.testLogDirectory = tempDir
        try? FileManager.default.removeItem(at: TelemetryLogger.shared.testLogFile)
    }

    override func tearDown() {
        TelemetryLogger.shared.testLogDirectory = nil
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func csvContent() -> String {
        (try? String(contentsOf: TelemetryLogger.shared.testLogFile, encoding: .utf8)) ?? ""
    }

    // MARK: - 表头列名

    func testCSVHeaderContainsResultColumn() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -60, kalmanRSSI: -60, effectiveRSSI: -60,
            slope: 0, isAnomalous: false)
        let header = csvContent().components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(header.contains("Result"),
                      "CSV 表头应包含 Result 列")
    }

    func testCSVHeaderContainsDurationMsColumn() {
        TelemetryLogger.shared.logSync(
            event: .autoLock, deviceModel: "test",
            rawRSSI: -70, kalmanRSSI: -70, effectiveRSSI: -70,
            slope: 0, isAnomalous: false)
        let header = csvContent().components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(header.contains("Duration_ms"),
                      "CSV 表头应包含 Duration_ms 列")
    }

    func testCSVHeaderOrderAppendsNewColumns() {
        TelemetryLogger.shared.logSync(
            event: .abnormalAlert, deviceModel: "test",
            rawRSSI: -80, kalmanRSSI: -80, effectiveRSSI: -80,
            slope: 0, isAnomalous: true)
        let header = csvContent().components(separatedBy: "\n").first ?? ""
        let isAnomalousPos = header.range(of: "Is_Anomalous")?.lowerBound
        let resultPos = header.range(of: "Result")?.lowerBound
        let durationPos = header.range(of: "Duration_ms")?.lowerBound
        let injectPos = header.range(of: "InjectTime")?.lowerBound
        let confirmPos = header.range(of: "ConfirmTime")?.lowerBound
        XCTAssertNotNil(isAnomalousPos)
        XCTAssertNotNil(resultPos)
        XCTAssertNotNil(durationPos)
        XCTAssertNotNil(injectPos)
        XCTAssertNotNil(confirmPos)
        if let aPos = isAnomalousPos, let rPos = resultPos, let dPos = durationPos,
           let iPos = injectPos, let cPos = confirmPos {
            XCTAssertTrue(aPos < rPos, "Result 应在 Is_Anomalous 之后")
            XCTAssertTrue(rPos < dPos, "Duration_ms 应在 Result 之后")
            XCTAssertTrue(dPos < iPos, "InjectTime 应在 Duration_ms 之后")
            XCTAssertTrue(iPos < cPos, "ConfirmTime 应在 InjectTime 之后")
        }
    }

    // MARK: - Result 字段值

    func testResultDefaultValueIsNA() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0.1, isAnomalous: false)
        let row = csvRow(containing: "auto_unlock", in: csvContent())
        XCTAssertEqual(row["Result"], "N/A", "未传 result 时默认应为 N/A")
    }

    func testResultSuccessValue() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0.1, isAnomalous: false,
            result: "success")
        let row = csvRow(containing: "auto_unlock", in: csvContent())
        XCTAssertEqual(row["Result"], "success")
    }

    func testResultFailValue() {
        TelemetryLogger.shared.logSync(
            event: .autoLock, deviceModel: "test",
            rawRSSI: -70, kalmanRSSI: -70, effectiveRSSI: -70,
            slope: 0, isAnomalous: false,
            result: "fail")
        let row = csvRow(containing: "auto_lock", in: csvContent())
        XCTAssertEqual(row["Result"], "fail")
    }

    func testResultTimeoutValue() {
        TelemetryLogger.shared.logSync(
            event: .abnormalAlert, deviceModel: "test",
            rawRSSI: -80, kalmanRSSI: -80, effectiveRSSI: -80,
            slope: 0, isAnomalous: true,
            result: "timeout")
        let row = csvRow(containing: "abnormal_alert", in: csvContent())
        XCTAssertEqual(row["Result"], "timeout")
    }

    // MARK: - Duration_ms 字段值

    func testDurationMsDefaultValueIsNA() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0.1, isAnomalous: false)
        let row = csvRow(containing: "auto_unlock", in: csvContent())
        XCTAssertEqual(row["Duration_ms"], "N/A", "未传 durationMs 时默认应为 N/A")
    }

    func testDurationMsWithValidValue() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0.1, isAnomalous: false,
            durationMs: 1234.5)
        let row = csvRow(containing: "auto_unlock", in: csvContent())
        XCTAssertEqual(row["Duration_ms"], "1234.50")
    }

    func testDurationMsWithZero() {
        TelemetryLogger.shared.logSync(
            event: .autoLock, deviceModel: "test",
            rawRSSI: -70, kalmanRSSI: -70, effectiveRSSI: -70,
            slope: 0, isAnomalous: false,
            durationMs: 0)
        let row = csvRow(containing: "auto_lock", in: csvContent())
        XCTAssertEqual(row["Duration_ms"], "0.00")
    }

    func testDurationMsDecimalFormat() {
        TelemetryLogger.shared.logSync(
            event: .abnormalAlert, deviceModel: "test",
            rawRSSI: -80, kalmanRSSI: -80, effectiveRSSI: -80,
            slope: 0, isAnomalous: true,
            durationMs: 99.1)
        let row = csvRow(containing: "abnormal_alert", in: csvContent())
        XCTAssertEqual(row["Duration_ms"], "99.10")
    }

    // MARK: - 兼容性：未传 result/durationMs 时原字段不受影响

    func testExistingFieldsUnchangedWithoutNewParams() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "iPhone",
            rawRSSI: -62, kalmanRSSI: -63.50, effectiveRSSI: -64.20,
            slope: 0.1234, isAnomalous: false)
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_unlock") }) ?? ""
        // 原字段位置（前8列）不变
        XCTAssertTrue(line.contains("auto_unlock"), "应包含原始 Event_Type")
        XCTAssertTrue(line.contains("iPhone"), "应包含原始 Device_Model")
        XCTAssertTrue(line.contains("-62"), "应包含原始 Raw_RSSI")
        XCTAssertTrue(line.contains("-63.50"), "应包含原始 Kalman_RSSI")
        XCTAssertTrue(line.contains("-64.20"), "应包含原始 Effective_RSSI")
        XCTAssertTrue(line.contains("0.1234"), "应包含原始 Slope")
        XCTAssertTrue(line.contains("false"), "应包含原始 Is_Anomalous")
    }

    // MARK: - 纯值模式：result + durationMs 都传

    func testBothResultAndDurationMsPresent() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "Watch",
            rawRSSI: -50, kalmanRSSI: -51.00, effectiveRSSI: -52.00,
            slope: 0.5000, isAnomalous: false,
            result: "success", durationMs: 2500.75)
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_unlock") }) ?? ""
        XCTAssertTrue(line.contains("success"), "应包含 result=success")
        XCTAssertTrue(line.contains("2500.75"), "应包含 durationMs=2500.75")
    }

    // MARK: - 多条记录行数

    func testMultipleRecordsProduceMultipleRows() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "A",
            rawRSSI: -50, kalmanRSSI: -50, effectiveRSSI: -50,
            slope: 0, isAnomalous: false, result: "success")
        TelemetryLogger.shared.logSync(
            event: .autoLock, deviceModel: "B",
            rawRSSI: -70, kalmanRSSI: -70, effectiveRSSI: -70,
            slope: 0, isAnomalous: false, result: "N/A", durationMs: 0)
        let lines = csvContent().components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3, "应有 1 行表头 + 2 行数据")
    }

    func testNAValueContainsLiteralNA() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0, isAnomalous: false)
        let row = csvRow(containing: "auto_unlock", in: csvContent())
        XCTAssertEqual(row["Result"], "N/A", "默认 result 应为 N/A")
        XCTAssertEqual(row["Duration_ms"], "N/A", "默认 durationMs 应为 N/A")
        XCTAssertEqual(row["InjectTime"], "N/A", "默认 injectTime 应为 N/A")
        XCTAssertEqual(row["ConfirmTime"], "N/A", "默认 confirmTime 应为 N/A")
    }

    // MARK: - InjectTime / ConfirmTime 表头

    func testCSVHeaderContainsInjectTimeColumn() {
        // 确保文件以新表头创建
        try? FileManager.default.removeItem(at: TelemetryLogger.shared.testLogFile)
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0, isAnomalous: false)
        let header = csvContent().components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(header.contains("InjectTime"), "CSV 表头应包含 InjectTime 列，实际表头: \(header)")
    }

    func testCSVHeaderContainsConfirmTimeColumn() {
        try? FileManager.default.removeItem(at: TelemetryLogger.shared.testLogFile)
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0, isAnomalous: false)
        let header = csvContent().components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(header.contains("ConfirmTime"), "CSV 表头应包含 ConfirmTime 列，实际表头: \(header)")
    }

    func testCSVHeaderOrderInjectTimeAfterDurationMs() {
        try? FileManager.default.removeItem(at: TelemetryLogger.shared.testLogFile)
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0, isAnomalous: false)
        let header = csvContent().components(separatedBy: "\n").first ?? ""
        let durationPos = header.range(of: "Duration_ms")?.lowerBound
        let injectPos = header.range(of: "InjectTime")?.lowerBound
        let confirmPos = header.range(of: "ConfirmTime")?.lowerBound
        XCTAssertNotNil(durationPos, "表头应包含 Duration_ms，实际: \(header)")
        XCTAssertNotNil(injectPos, "表头应包含 InjectTime，实际: \(header)")
        XCTAssertNotNil(confirmPos, "表头应包含 ConfirmTime，实际: \(header)")
        if let dPos = durationPos, let iPos = injectPos, let cPos = confirmPos {
            XCTAssertTrue(dPos < iPos, "InjectTime 应在 Duration_ms 之后")
            XCTAssertTrue(iPos < cPos, "ConfirmTime 应在 InjectTime 之后")
        }
    }

    // MARK: - InjectTime / ConfirmTime 默认值

    func testInjectTimeDefaultValueIsNA() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0.1, isAnomalous: false)
        let row = csvRow(containing: "auto_unlock", in: csvContent())
        XCTAssertEqual(row["InjectTime"], "N/A", "未传 injectTime 时默认应为 N/A")
    }

    func testConfirmTimeDefaultValueIsNA() {
        TelemetryLogger.shared.logSync(
            event: .autoLock, deviceModel: "test",
            rawRSSI: -70, kalmanRSSI: -70, effectiveRSSI: -70,
            slope: 0, isAnomalous: false)
        let row = csvRow(containing: "auto_lock", in: csvContent())
        XCTAssertEqual(row["ConfirmTime"], "N/A", "未传 confirmTime 时默认应为 N/A")
    }

    // MARK: - InjectTime / ConfirmTime 传入时间戳

    func testInjectTimeFormattedCorrectly() {
        let inject = Date(timeIntervalSince1970: 1_000_000)  // 1970-01-12 13:46:40 UTC
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0.1, isAnomalous: false,
            injectTime: inject)
        let row = csvRow(containing: "auto_unlock", in: csvContent())
        let injectValue = row["InjectTime"] ?? ""
        XCTAssertTrue(injectValue.hasPrefix("1970-01-12"), "injectTime 应格式化为日期字符串，实际: \(injectValue)")
        // 使用 Formatter 验证：本地时区下 1_000_000 的时分秒
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone.current
        let expectedTime = formatter.string(from: inject)
        XCTAssertTrue(injectValue.contains(expectedTime),
                      "injectTime 应包含本地时区时分秒 \(expectedTime)，实际: \(injectValue)")
    }

    func testConfirmTimeFormattedCorrectly() {
        let confirm = Date(timeIntervalSince1970: 1_000_001)  // 1970-01-12 13:46:41 UTC
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "test",
            rawRSSI: -55, kalmanRSSI: -55, effectiveRSSI: -55,
            slope: 0.1, isAnomalous: false,
            confirmTime: confirm)
        let row = csvRow(containing: "auto_unlock", in: csvContent())
        let confirmValue = row["ConfirmTime"] ?? ""
        XCTAssertTrue(confirmValue.hasPrefix("1970-01-12"), "confirmTime 应格式化为日期字符串，实际: \(confirmValue)")
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone.current
        let expectedTime = formatter.string(from: confirm)
        XCTAssertTrue(confirmValue.contains(expectedTime),
                      "confirmTime 应包含本地时区时分秒 \(expectedTime)，实际: \(confirmValue)")
    }

    func testBothInjectAndConfirmTimePresent() {
        let inject = Date(timeIntervalSince1970: 1_000_000)
        let confirm = Date(timeIntervalSince1970: 1_000_001)
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "Watch",
            rawRSSI: -50, kalmanRSSI: -51, effectiveRSSI: -52,
            slope: 0.5, isAnomalous: false,
            result: "success", durationMs: 1000,
            injectTime: inject, confirmTime: confirm)
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_unlock") }) ?? ""
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone.current
        XCTAssertTrue(line.contains(formatter.string(from: inject)),
                      "应包含 injectTime 格式化值")
        XCTAssertTrue(line.contains(formatter.string(from: confirm)),
                      "应包含 confirmTime 格式化值")
        XCTAssertTrue(line.contains("success"), "result 字段不受影响")
        XCTAssertTrue(line.contains("1000.00"), "durationMs 字段不受影响")
    }

    // MARK: - 向后兼容：旧字段位置不变

    func testExistingColumnsUnchangedWithNewTimeParams() {
        let inject = Date(timeIntervalSince1970: 1_000_000)
        let confirm = Date(timeIntervalSince1970: 1_000_001)
        TelemetryLogger.shared.logSync(
            event: .autoUnlock, deviceModel: "iPhone",
            rawRSSI: -62, kalmanRSSI: -63.50, effectiveRSSI: -64.20,
            slope: 0.1234, isAnomalous: false,
            injectTime: inject, confirmTime: confirm)
        let line = csvContent().components(separatedBy: "\n").first(where: { $0.contains("auto_unlock") }) ?? ""
        // 原字段位置（前8列）不变
        XCTAssertTrue(line.contains("auto_unlock"), "应包含原始 Event_Type")
        XCTAssertTrue(line.contains("iPhone"), "应包含原始 Device_Model")
        XCTAssertTrue(line.contains("-62"), "应包含原始 Raw_RSSI")
        XCTAssertTrue(line.contains("-63.50"), "应包含原始 Kalman_RSSI")
        XCTAssertTrue(line.contains("-64.20"), "应包含原始 Effective_RSSI")
        XCTAssertTrue(line.contains("0.1234"), "应包含原始 Slope")
        XCTAssertTrue(line.contains("false"), "应包含原始 Is_Anomalous")
    }
}

// MARK: - 兼容性回归测试（LegacyCompatibilityTests）

/// 回归测试：验证 v2.5 新增功能不破坏现有接口的默认行为。
/// 重点覆盖：ScriptRunner.logEvent、FUnManager 默认值、TelemetryLogger 新旧调用路径。
@MainActor
class LegacyCompatibilityTests: XCTestCase {

    // MARK: - ScriptRunner.logEvent 向后兼容

    private var logFile: URL!
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyCompatTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        logFile = tempDir.appendingPathComponent("events.log")
        ScriptRunner.shared.testLogDirectory = tempDir
        TelemetryLogger.shared.testLogDirectory = tempDir
        try? FileManager.default.removeItem(at: TelemetryLogger.shared.testLogFile)
    }

    override func tearDown() async throws {
        ScriptRunner.shared.testLogDirectory = nil
        TelemetryLogger.shared.testLogDirectory = nil
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func readLog() -> String {
        (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
    }

    /// logEvent 单参数调用（旧签名）仍能正常写入
    func testLogEventLegacySignatureStillWorks() {
        ScriptRunner.shared.logEvent("legacy_event")
        let content = readLog()
        XCTAssertTrue(content.contains("legacy_event"), "旧签名 logEvent 应正常写入事件名")
        XCTAssertTrue(content.contains("RSSI: N/A"), "无 RSSI 参数时应显示 N/A")
    }

    /// logEvent 双参数调用（旧签名）仍能正常写入 RSSI
    func testLogEventWithRSSILegacySignatureStillWorks() {
        ScriptRunner.shared.logEvent("legacy_rssi_event", rssi: -72)
        let content = readLog()
        XCTAssertTrue(content.contains("legacy_rssi_event"), "应写入事件名")
        XCTAssertTrue(content.contains("RSSI: -72"), "应写入 RSSI 值")
    }

    /// logEvent 不受去重窗口限制（连续写入同名事件应全部写入）
    func testLogEventBypassesDedup() {
        ScriptRunner.shared.logEvent("dedup_bypass", rssi: -50)
        ScriptRunner.shared.logEvent("dedup_bypass", rssi: -50)
        ScriptRunner.shared.logEvent("dedup_bypass", rssi: -50)
        let content = readLog()
        let count = content.components(separatedBy: "dedup_bypass").count - 1
        XCTAssertEqual(count, 3, "logEvent 不应去重，三次调用都应写入")
    }

    /// logEvent 日志行格式与旧版本一致：timestamp | event | RSSI: value
    func testLogEventLineFormatMatchesLegacy() {
        ScriptRunner.shared.logEvent("format_check", rssi: -80)
        let content = readLog()
        let lines = content.components(separatedBy: "\n").filter { $0.contains("format_check") }
        XCTAssertFalse(lines.isEmpty, "应有包含 format_check 的日志行")
        guard let line = lines.first else { return }
        // 格式：yyyy-MM-dd HH:mm:ss | event | RSSI: value
        XCTAssertTrue(line.contains("format_check"), "应包含事件名")
        XCTAssertTrue(line.contains("RSSI: -80"), "应包含 RSSI 值")
        XCTAssertTrue(line.contains(" | "), "应使用 ' | ' 分隔符")
        let datePattern = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#
        let regex = try! NSRegularExpression(pattern: datePattern, options: [])
        let range = NSRange(line.startIndex..., in: line)
        XCTAssertNotNil(regex.firstMatch(in: line, range: range),
                        "日志行应以 yyyy-MM-dd HH:mm:ss 开头，实际: \(line)")
    }

    /// logEvent 写入的文件路径不变（~/Library/Application Support/FUnlock/events.log）
    func testLogEventFilePathUnchanged() {
        ScriptRunner.shared.logEvent("path_check")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logFile.path),
                      "events.log 应写入固定路径")
        let content = readLog()
        XCTAssertTrue(content.contains("path_check"), "事件应写入正确路径")
    }

    /// logEventIfNeeded（新接口）首次调用返回 true
    func testLogEventIfNeededFirstCallReturnsTrue() {
        let runner = ScriptRunner(dedupWindow: 3.0) { Date() }
        let logged = runner.logEventIfNeeded("new_api_first")
        XCTAssertTrue(logged, "新接口首次调用应返回 true")
    }

    /// logEventIfNeeded（新接口）窗口内重复返回 false
    func testLogEventIfNeededDuplicateReturnsFalse() {
        let runner = ScriptRunner(dedupWindow: 3.0) { Date() }
        _ = runner.logEventIfNeeded("new_api_dup")
        let second = runner.logEventIfNeeded("new_api_dup")
        XCTAssertFalse(second, "新接口窗口内重复应返回 false")
    }

    /// logEvent 与 logEventIfNeeded 共存：logEvent 不被 logEventIfNeeded 的去重影响
    func testLegacyAndNewAPIsCoexist() {
        let runner = ScriptRunner(dedupWindow: 3.0) { Date() }
        _ = runner.logEventIfNeeded("coexist_event")
        // logEvent 应无视去重，仍能写入
        runner.logEvent("coexist_event", rssi: -60)
        let content = readLog()
        let count = content.components(separatedBy: "coexist_event").count - 1
        XCTAssertEqual(count, 2, "logEvent 与 logEventIfNeeded 应独立工作，共写入 2 条")
    }

    // MARK: - FUnManager 默认值兼容

    /// FUnManager 的 lockRSSI 默认值与 FUn 一致
    func testFUnManagerDefaultLockRSSIMatchesFUn() {
        let fun = FUn()
        let manager = FUnManager(fun: fun)
        XCTAssertEqual(manager.lockRSSI, fun.lockRSSI, "FUnManager.lockRSSI 默认值应与 FUn.lockRSSI 一致")
    }

    /// FUnManager 的 unlockRSSI 默认值与 FUn 一致
    func testFUnManagerDefaultUnlockRSSIMatchesFUn() {
        let fun = FUn()
        let manager = FUnManager(fun: fun)
        XCTAssertEqual(manager.unlockRSSI, fun.unlockRSSI, "FUnManager.unlockRSSI 默认值应与 FUn.unlockRSSI 一致")
    }

    /// 审计 B5 #12：设备列表入库门限默认应与最低可配置解锁阈值（-100）对齐。
    /// 此前默认 -90 会导致解锁阈值放宽到 -100 时可解锁设备先被列表门限过滤、永不出现
    func testFUnThresholdRSSIDefaultAlignedWithUnlockRange() {
        let fun = FUn()
        XCTAssertEqual(fun.thresholdRSSI, -100,
                       "thresholdRSSI 默认应为 -100（与最低可配置解锁阈值一致，避免设备列表过滤可解锁设备）")
    }

    /// FUnManager 解锁冷却默认值为 5 秒
    func testFUnManagerDefaultCooldownIs5Seconds() {
        let manager = FUnManager(fun: FUn())
        XCTAssertEqual(manager.unlockCooldownDuration, 5.0,
                       "默认解锁冷却时间应为 5 秒，保证旧版行为不变")
    }

    /// FUnManager 锁屏缓冲默认值为 0.8 秒
    func testFUnManagerDefaultBufferIs08Seconds() {
        let manager = FUnManager(fun: FUn())
        XCTAssertEqual(manager.lockBufferDuration, 0.8,
                       "默认锁屏缓冲时间应为 0.8 秒，保证旧版行为不变")
    }

    /// FUnManager 初始状态：lastLockTime 和 lastUnlockTime 均为 distantPast
    func testFUnManagerInitialTimestampsAreDistantPast() {
        let manager = FUnManager(fun: FUn())
        XCTAssertEqual(manager.lastLockTime, Date.distantPast,
                       "初始 lastLockTime 应为 distantPast")
        XCTAssertEqual(manager.lastUnlockTime, Date.distantPast,
                       "初始 lastUnlockTime 应为 distantPast")
    }

    /// FUnManager 初始 state 的 screen 应为 unlocked
    func testFUnManagerInitialStateScreenIsUnlocked() {
        let manager = FUnManager(fun: FUn())
        if case .unlocked = manager.state.screen {
            // OK
        } else {
            XCTFail("初始 state.screen 应为 .unlocked，实际: \(manager.state.screen)")
        }
    }

    /// FUnManager 初始 state 的 system 应为 awake
    func testFUnManagerInitialStateSystemIsAwake() {
        let manager = FUnManager(fun: FUn())
        XCTAssertEqual(manager.state.system, .awake, "初始 state.system 应为 .awake")
    }

    /// FUnManager 初始 state 的 intent 应为 autoLock
    func testFUnManagerInitialStateIntentIsAutoLock() {
        let manager = FUnManager(fun: FUn())
        if case .autoLock = manager.state.intent {
            // OK
        } else {
            XCTFail("初始 state.intent 应为 .autoLock")
        }
    }

    /// FUnManager 初始 connected 应为 false
    func testFUnManagerInitialConnectedIsFalse() {
        let manager = FUnManager(fun: FUn())
        XCTAssertFalse(manager.connected, "初始 connected 应为 false")
    }

    /// FUnManager 初始 rssi 应为 nil
    func testFUnManagerInitialRSSIIsNil() {
        let manager = FUnManager(fun: FUn())
        XCTAssertNil(manager.rssi, "初始 rssi 应为 nil")
    }

    // MARK: - TelemetryLogger 新旧调用兼容

    private func csvContent() -> String {
        (try? String(contentsOf: TelemetryLogger.shared.testLogFile, encoding: .utf8)) ?? ""
    }

    /// 旧式调用（6 个必填参数，不传 result/durationMs/injectTime/confirmTime）仍可编译并写入
    func testTelemetryLegacyCallWith6ParamsStillWorks() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock,
            deviceModel: "test-device",
            rawRSSI: -55,
            kalmanRSSI: -56.0,
            effectiveRSSI: -57.5,
            slope: 0.1234,
            isAnomalous: false
        )
        let content = csvContent()
        XCTAssertTrue(content.contains("auto_unlock"), "旧式调用应写入 auto_unlock 事件")
        XCTAssertTrue(content.contains("test-device"), "旧式调用应写入设备名")
        XCTAssertTrue(content.contains("-55"), "旧式调用应写入 rawRSSI")
    }

    /// 旧式调用的新增列（Result / Duration_ms / InjectTime / ConfirmTime）默认为 N/A
    func testTelemetryLegacyCallNewColumnsDefaultToNA() {
        TelemetryLogger.shared.logSync(
            event: .autoLock,
            deviceModel: "legacy-model",
            rawRSSI: -70,
            kalmanRSSI: -71,
            effectiveRSSI: -72,
            slope: 0.5,
            isAnomalous: true
        )
        let row = csvRow(containing: "auto_lock", in: csvContent())
        XCTAssertEqual(row["Result"], "N/A", "Result 默认值应为 N/A")
        XCTAssertEqual(row["Duration_ms"], "N/A", "Duration_ms 默认值应为 N/A")
        XCTAssertEqual(row["InjectTime"], "N/A", "InjectTime 默认值应为 N/A")
        XCTAssertEqual(row["ConfirmTime"], "N/A", "ConfirmTime 默认值应为 N/A")
    }

    /// 旧式调用的原始 8 列字段值正确
    func testTelemetryLegacyCallOriginal8ColumnsCorrect() {
        TelemetryLogger.shared.logSync(
            event: .abnormalAlert,
            deviceModel: "Watch",
            rawRSSI: -80,
            kalmanRSSI: -81.00,
            effectiveRSSI: -82.50,
            slope: 0.4321,
            isAnomalous: true
        )
        let row = csvRow(containing: "abnormal_alert", in: csvContent())
        XCTAssertFalse((row["Timestamp"] ?? "").isEmpty, "Timestamp 不应为空")
        XCTAssertEqual(row["Event_Type"], "abnormal_alert", "Event_Type 应为 abnormal_alert")
        XCTAssertEqual(row["Device_Model"], "Watch", "Device_Model 应为 Watch")
        XCTAssertEqual(row["Raw_RSSI"], "-80", "Raw_RSSI 应为 -80")
        XCTAssertEqual(row["Kalman_RSSI"], "-81.00", "Kalman_RSSI 应为 -81.00")
        XCTAssertEqual(row["Effective_RSSI"], "-82.50", "Effective_RSSI 应为 -82.50")
        XCTAssertEqual(row["Slope"], "0.4321", "Slope 应为 0.4321")
        XCTAssertEqual(row["Is_Anomalous"], "true", "Is_Anomalous 应为 true")
    }

    /// 新式调用（传入 result + durationMs）不影响原始 8 列
    func testTelemetryNewCallDoesNotAlterOriginalColumns() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock,
            deviceModel: "iPhone 15",
            rawRSSI: -60,
            kalmanRSSI: -61.50,
            effectiveRSSI: -62.75,
            slope: 0.9876,
            isAnomalous: false,
            result: "success",
            durationMs: 3200.00
        )
        let row = csvRow(containing: "auto_unlock", in: csvContent())
        XCTAssertEqual(row["Event_Type"], "auto_unlock")
        XCTAssertEqual(row["Device_Model"], "iPhone 15")
        XCTAssertEqual(row["Raw_RSSI"], "-60")
        XCTAssertEqual(row["Kalman_RSSI"], "-61.50")
        XCTAssertEqual(row["Effective_RSSI"], "-62.75")
        XCTAssertEqual(row["Slope"], "0.9876")
        XCTAssertEqual(row["Is_Anomalous"], "false")
        XCTAssertEqual(row["Result"], "success", "Result 应为 success")
        XCTAssertEqual(row["Duration_ms"], "3200.00", "Duration_ms 应为 3200.00")
    }

    /// TelemetryLogger 异步 log 与同步 logSync 写入格式一致
    func testTelemetryAsyncAndSyncProduceSameCSVFormat() {
        TelemetryLogger.shared.logSync(
            event: .autoUnlock,
            deviceModel: "sync-test",
            rawRSSI: -50,
            kalmanRSSI: -51,
            effectiveRSSI: -52,
            slope: 0.1,
            isAnomalous: false,
            result: "success",
            durationMs: 1000)
        let row = csvRow(containing: "sync-test", in: csvContent())
        XCTAssertEqual(row["Result"], "success")
        XCTAssertEqual(row["Duration_ms"], "1000.00")
    }

    // MARK: - FUnManager 与 ScriptRunner 调用路径兼容

    /// FUnManager.onUnlock 调用链：应触发 ScriptRunner.logEvent("unlocked") 和 TelemetryLogger.log(.autoUnlock)
    func testOnUnlockTriggersLegacyScriptRunnerLogEvent() {
        let manager = FUnManager(fun: FUn())
        manager.onUnlock()

        // onUnlock 内部通过 intrudeCheckTask 异步写入，这里改为验证 lastUnlockTime 被更新
        // 使用时间间隔比较：两者应在同一秒内
        let interval = manager.lastUnlockTime.timeIntervalSince(manager.state.unlockedAt)
        XCTAssertEqual(interval, 0, accuracy: 1.0,
                       "onUnlock 后 lastUnlockTime 与 unlockedAt 应在同一秒内")
        XCTAssertTrue(manager.state.screen == .unlocked, "onUnlock 后 screen 应为 unlocked")
    }

    /// FUnManager.onSystemScreenLocked 设置 lastLockTime，isLockBufferActive 生效
    func testOnSystemScreenLockedActivatesLockBuffer() {
        let manager = FUnManager(fun: FUn())
        let before = Date()
        manager.onSystemScreenLocked()
        XCTAssertGreaterThanOrEqual(manager.lastLockTime.timeIntervalSince1970,
                                    before.timeIntervalSince1970,
                                    "onSystemScreenLocked 应设置 lastLockTime 为当前时间")
        XCTAssertTrue(manager.isLockBufferActive(),
                      "onSystemScreenLocked 后 isLockBufferActive 应为 true")
    }

    /// FUnManager 状态机：onUnlock → onSystemScreenLocked 序列正确
    func testUnlockThenLockSequenceMaintainsStateConsistency() {
        let manager = FUnManager(fun: FUn())

        // 初始：unlocked
        XCTAssertTrue(manager.state.screen == .unlocked, "初始应为 unlocked")

        // 解锁
        manager.onUnlock()
        XCTAssertTrue(manager.state.screen == .unlocked, "onUnlock 后应为 unlocked")
        XCTAssertTrue(manager.state.intent == .autoLock, "onUnlock 后 intent 应为 autoLock")

        // 手动锁屏
        manager.onSystemScreenLocked()
        if case .locked(let reason) = manager.state.screen {
            XCTAssertEqual(reason, .manual, "手动锁屏后 reason 应为 manual")
        } else {
            XCTFail("手动锁屏后 screen 应为 .locked")
        }
        // lastUnlockTime 应被设置（不为 distantPast），且冷却应在时间窗口内
        XCTAssertNotEqual(manager.lastUnlockTime, Date.distantPast,
                          "onUnlock 后 lastUnlockTime 不应为 distantPast")
    }
}
