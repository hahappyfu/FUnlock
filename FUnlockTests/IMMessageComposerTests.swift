// FUnlockTests/IMMessageComposerTests.swift
import XCTest
@testable import FUnlock

final class IMMessageComposerTests: XCTestCase {

    // MARK: - 标题

    func testLockedComposeTitle() {
        let (title, body) = IMMessageComposer.compose(.locked(reason: "lost", rssi: -88, deviceName: "iPhone"))
        XCTAssertEqual(title, t("im_title_locked"))
        XCTAssertTrue(body.contains("iPhone"), "正文应包含设备名，实际: \(body)")
        XCTAssertTrue(body.contains("-88"), "正文应包含信号，实际: \(body)")
    }

    func testUnlockedComposeTitle() {
        let (title, _) = IMMessageComposer.compose(.unlocked(rssi: -42, deviceName: "iPhone"))
        XCTAssertEqual(title, t("im_title_unlocked"))
    }

    func testComposeTestEventTitle() {
        let (title, _) = IMMessageComposer.compose(.test)
        XCTAssertEqual(title, t("im_title_unlocked"), "测试事件应与解锁共用文案")
    }

    // MARK: - 时间格式

    func testComposeTodayTime() {
        let (_, body) = IMMessageComposer.compose(.locked(reason: "lost", rssi: -88, deviceName: "iPhone"), now: Date())
        let todayPrefix = t("im_body_time_today").replacingOccurrences(of: "%@", with: "")
        XCTAssertTrue(body.hasPrefix(todayPrefix), "今天应使用 today 文案，实际: \(body)")
    }

    func testComposeYesterdayTime() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let (_, body) = IMMessageComposer.compose(.locked(reason: "lost", rssi: -88, deviceName: "iPhone"), now: yesterday)
        let yesterdayPrefix = t("im_body_time_yesterday").replacingOccurrences(of: "%@", with: "")
        XCTAssertTrue(body.hasPrefix(yesterdayPrefix), "昨天应使用 yesterday 文案，实际: \(body)")
    }

    func testComposeTimeHHmm() {
        let fixed = Date(timeIntervalSince1970: 0) // 1970-01-01 08:00:00 +0800
        let (_, body) = IMMessageComposer.compose(.unlocked(rssi: -42, deviceName: "iPhone"), now: fixed)
        XCTAssertTrue(body.contains("08:00"), "时间应为 HH:mm 格式，实际: \(body)")
    }

    // MARK: - 降级文案

    func testComposeNilDeviceName() {
        let (_, body) = IMMessageComposer.compose(.locked(reason: "lost", rssi: -88, deviceName: nil))
        XCTAssertFalse(body.contains("iPhone"), "设备名为空时应省略，实际: \(body)")
    }

    func testComposeNilRssi() {
        let (_, body) = IMMessageComposer.compose(.locked(reason: "lost", rssi: nil, deviceName: "iPhone"))
        XCTAssertFalse(body.contains("dBm"), "信号无值时应省略，实际: \(body)")
    }

    func testComposeBothNil() {
        let (_, body) = IMMessageComposer.compose(.unlocked(rssi: nil, deviceName: nil))
        XCTAssertFalse(body.contains("dBm"), "无信号不应含 dBm，实际: \(body)")
    }

    func testComposeDeviceSignalCombined() {
        let (_, body) = IMMessageComposer.compose(.locked(reason: "lost", rssi: -88, deviceName: "iPhone"))
        let expected = "iPhone \(String(format: t("im_body_signal"), -88))"
        XCTAssertTrue(body.contains(expected), "设备名与信号应合并为一段，实际: \(body)")
    }

    func testComposeRssiRounded() {
        let (_, body) = IMMessageComposer.compose(.locked(reason: "lost", rssi: -88.4, deviceName: "iPhone"))
        XCTAssertTrue(body.contains("-88"), "信号应取整显示，实际: \(body)")
        XCTAssertFalse(body.contains("-88.4"))
    }

    // MARK: - normalizeRecipient

    func testNormalizePhoneWith86() {
        XCTAssertEqual(IMMessageComposer.normalizeRecipient("+86 138-1234 5678"), "8613812345678")
    }

    func testNormalizeLocalPhoneStays() {
        XCTAssertEqual(IMMessageComposer.normalizeRecipient("138-1234 5678"), "13812345678")
    }

    func testNormalizeEmail() {
        XCTAssertEqual(IMMessageComposer.normalizeRecipient(" abc@icloud.com "), "abc@icloud.com")
    }

    func testNormalizeEmpty() {
        XCTAssertEqual(IMMessageComposer.normalizeRecipient("   "), "")
    }
}
