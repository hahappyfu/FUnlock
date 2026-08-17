// FUnlockTests/iMessageNotifierTests.swift
import XCTest
@testable import FUnlock

final class iMessageNotifierTests: XCTestCase {

    override func tearDown() {
        // 清理测试写入的 defaults，避免污染真实配置
        ConfigStore.shared.defaults.removeObject(forKey: "iMessageNotify")
        ConfigStore.shared.defaults.removeObject(forKey: "iMessageNotifyRecipient")
        iMessageNotifier.shared.scriptRunner = nil
        iMessageNotifier.shared.resetDebounceForTesting()
        super.tearDown()
    }

    // MARK: - 错误映射

    func testPermissionDeniedMapsToChinese() {
        let info: [String: Any] = [
            "NSAppleScriptErrorNumber": -1743,
        ]
        let msg = iMessageNotifier.friendlyError(errorInfo: info)
        XCTAssertTrue(msg.contains("授权"), "未授权应提示授权，实际: \(msg)")
    }

    func testBuddyNotFoundMapsToRecipientInvalid() {
        let info: [String: Any] = [
            "NSAppleScriptErrorNumber": -1708,
            "NSAppleScriptErrorMessage": "chat... cannot find buddy \"abc\""
        ]
        let msg = iMessageNotifier.friendlyError(errorInfo: info)
        XCTAssertTrue(msg.contains("收件人"), "应提示收件人无效，实际: \(msg)")
    }

    func testGenericErrorReturnsMessage() {
        let info: [String: Any] = [
            "NSAppleScriptErrorNumber": -1,
            "NSAppleScriptErrorMessage": "boom"
        ]
        let msg = iMessageNotifier.friendlyError(errorInfo: info)
        XCTAssertTrue(msg.contains("boom"))
    }

    // MARK: - parseScriptError

    func testParseScriptErrorExtracts1743() {
        let output = "36:53: execution error: \u{201C}Messages\u{201D}\u{9047}\u{5230}\u{4E00}\u{4E2A}\u{9519}\u{8BEF}\u{FF1A}Not authorized to send Apple events to Messages. (-1743)"
        let msg = iMessageNotifier.parseScriptError(output: output)
        XCTAssertTrue(msg.contains("授权"), "应识别 -1743 为授权问题，实际: \(msg)")
    }

    func testParseScriptErrorExtractsBuddyNotFound() {
        let output = "execution error: cant find buddy \u{201C}abc\u{201D} (-1708)"
        let msg = iMessageNotifier.parseScriptError(output: output)
        XCTAssertTrue(msg.contains("收件人"), "buddy 缺失应映射为收件人无效，实际: \(msg)")
    }

    func testParseScriptErrorUnknownCodeKeepsMessage() {
        let output = "10:20: execution error: whatever happened. (-9999)"
        let msg = iMessageNotifier.parseScriptError(output: output)
        XCTAssertTrue(msg.contains("whatever happened"), "应保留原始信息，实际: \(msg)")
        XCTAssertTrue(msg.contains("-9999"), "应保留错误码，实际: \(msg)")
    }

    func testParseScriptErrorEmptyOutput() {
        let msg = iMessageNotifier.parseScriptError(output: "")
        XCTAssertTrue(msg.contains("osascript"), "空输出应提示 osascript 失败，实际: \(msg)")
    }

    // MARK: - send(_:) 事件 API

    func testLockedEventDebouncedByType() {
        ConfigStore.shared.defaults.set(true, forKey: "iMessageNotify")
        ConfigStore.shared.defaults.set("13800138000", forKey: "iMessageNotifyRecipient")
        var calls = 0
        iMessageNotifier.shared.scriptRunner = { _, _ in calls += 1; return nil }
        // 连续两次同类型事件：30s 防抖只放行一次
        iMessageNotifier.shared.send(.locked(reason: "lost", rssi: -88, deviceName: "iPhone"))
        iMessageNotifier.shared.send(.locked(reason: "lost", rssi: -88, deviceName: "iPhone"))
        // 不同类型互不影响
        iMessageNotifier.shared.send(.unlocked(rssi: -42, deviceName: "iPhone"))
        iMessageNotifier.shared.send(.test)
        let exp = expectation(description: "async")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(calls, 3, "同类型防抖仅 1 次，不同类型各 1 次，实际: \(calls)")
    }

    func testLockedEventDisabledNotSent() {
        ConfigStore.shared.defaults.set(false, forKey: "iMessageNotify")
        ConfigStore.shared.defaults.set("13800138000", forKey: "iMessageNotifyRecipient")
        var calls = 0
        iMessageNotifier.shared.scriptRunner = { _, _ in calls += 1; return nil }
        iMessageNotifier.shared.send(.locked(reason: "lost", rssi: -88, deviceName: "iPhone"))
        let exp = expectation(description: "async")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(calls, 0, "开关关闭时不应发送，实际: \(calls)")
    }

    func testLockedEventSilentFailure() {
        ConfigStore.shared.defaults.set(true, forKey: "iMessageNotify")
        ConfigStore.shared.defaults.set("13800138000", forKey: "iMessageNotifyRecipient")
        iMessageNotifier.shared.scriptRunner = { _, _ in "Messages 未授权：请授权" }
        // 真实路径失败应静默：不崩溃、不抛异常
        iMessageNotifier.shared.send(.locked(reason: "lost", rssi: -88, deviceName: "iPhone"))
        let exp = expectation(description: "async")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }

    func testLockedEventComposesLocalizedText() {
        ConfigStore.shared.defaults.set(true, forKey: "iMessageNotify")
        ConfigStore.shared.defaults.set("13800138000", forKey: "iMessageNotifyRecipient")
        var received = ""
        iMessageNotifier.shared.scriptRunner = { _, text in received = text; return nil }
        iMessageNotifier.shared.send(.locked(reason: "lost", rssi: -88, deviceName: "iPhone"))
        let exp = expectation(description: "async")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertTrue(received.contains(t("im_title_locked")), "应发送本地化标题，实际: \(received)")
        XCTAssertTrue(received.contains("iPhone"), "应包含设备名，实际: \(received)")
        XCTAssertTrue(received.contains("-88"), "应包含信号值，实际: \(received)")
        XCTAssertFalse(received.contains("reason="), "不应包含内部调试字段，实际: \(received)")
    }

    // MARK: - sendTestNotification

    func testTestNotificationFailsFastWhenDisabled() {
        ConfigStore.shared.defaults.set(false, forKey: "iMessageNotify")
        ConfigStore.shared.defaults.set("13800138000", forKey: "iMessageNotifyRecipient")
        let exp = expectation(description: "disabled")
        iMessageNotifier.shared.sendTestNotification(title: "🔒 测试", message: "锁定") { result in
            switch result {
            case .failure(let msg): XCTAssertTrue(msg.message.contains("开关"))
            case .success: XCTFail("开关关闭时不应发送")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testTestNotificationFailsWhenNoRecipient() {
        ConfigStore.shared.defaults.set(true, forKey: "iMessageNotify")
        ConfigStore.shared.defaults.removeObject(forKey: "iMessageNotifyRecipient")
        let exp = expectation(description: "noRecipient")
        iMessageNotifier.shared.sendTestNotification(title: "t", message: "m") { result in
            switch result {
            case .failure(let msg): XCTAssertTrue(msg.message.contains("收件人"))
            case .success: XCTFail("收件人为空时不应发送")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testTestNotificationSuccess() {
        ConfigStore.shared.defaults.set(true, forKey: "iMessageNotify")
        ConfigStore.shared.defaults.set("13800138000", forKey: "iMessageNotifyRecipient")
        iMessageNotifier.shared.scriptRunner = { _, _ in nil } // 模拟发送成功
        let exp = expectation(description: "success")
        iMessageNotifier.shared.sendTestNotification(title: "t", message: "m") { result in
            XCTAssertTrue(Thread.isMainThread, "completion 应回到主线程")
            if case .success = result {} else { XCTFail("应成功") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testSendTestNotificationFailurePropagates() {
        ConfigStore.shared.defaults.set(true, forKey: "iMessageNotify")
        ConfigStore.shared.defaults.set("13800138001", forKey: "iMessageNotifyRecipient")
        iMessageNotifier.shared.scriptRunner = { _, _ in "Messages 未授权" }
        let exp = expectation(description: "failure")
        iMessageNotifier.shared.sendTestNotification(title: "t", message: "m") { result in
            XCTAssertTrue(Thread.isMainThread, "completion 应回到主线程")
            switch result {
            case .failure(let msg): XCTAssertTrue(msg.message.contains("未授权"))
            case .success: XCTFail("应失败")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testTestNotificationBypassDebounce() {
        ConfigStore.shared.defaults.set(true, forKey: "iMessageNotify")
        ConfigStore.shared.defaults.set("13800138000", forKey: "iMessageNotifyRecipient")
        var calls = 0
        iMessageNotifier.shared.scriptRunner = { _, _ in calls += 1; return nil }
        let exp = expectation(description: "twice")
        var pending = 2
        for _ in 0..<2 {
            iMessageNotifier.shared.sendTestNotification(title: "t", message: "m") { result in
                pending -= 1
                if pending == 0 { exp.fulfill() }
            }
        }
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(calls, 2, "测试通知应绕过 30s 防抖，两次都执行")
    }
}