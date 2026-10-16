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
