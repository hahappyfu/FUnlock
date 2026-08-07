// FUnlockTests/iMessageNotifierTests.swift
import XCTest
@testable import FUnlock

final class iMessageNotifierTests: XCTestCase {

    override func tearDown() {
        // 清理测试写入的 defaults，避免污染真实配置
        UserDefaults.standard.removeObject(forKey: "iMessageNotify")
        UserDefaults.standard.removeObject(forKey: "iMessageNotifyRecipient")
        iMessageNotifier.shared.scriptRunner = nil
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

    // MARK: - sendTestNotification

    func testTestNotificationFailsFastWhenDisabled() {
        UserDefaults.standard.set(false, forKey: "iMessageNotify")
        UserDefaults.standard.set("15167104090", forKey: "iMessageNotifyRecipient")
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
        UserDefaults.standard.set(true, forKey: "iMessageNotify")
        UserDefaults.standard.removeObject(forKey: "iMessageNotifyRecipient")
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
        UserDefaults.standard.set(true, forKey: "iMessageNotify")
        UserDefaults.standard.set("15167104090", forKey: "iMessageNotifyRecipient")
        iMessageNotifier.shared.scriptRunner = { _, _ in nil } // 模拟发送成功
        let exp = expectation(description: "success")
        iMessageNotifier.shared.sendTestNotification(title: "t", message: "m") { result in
            if case .success = result {} else { XCTFail("应成功") }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testSendTestNotificationFailurePropagates() {
        UserDefaults.standard.set(true, forKey: "iMessageNotify")
        UserDefaults.standard.set("13812304090", forKey: "iMessageNotifyRecipient")
        iMessageNotifier.shared.scriptRunner = { _, _ in "Messages 未授权" }
        let exp = expectation(description: "failure")
        iMessageNotifier.shared.sendTestNotification(title: "t", message: "m") { result in
            switch result {
            case .failure(let msg): XCTAssertTrue(msg.message.contains("未授权"))
            case .success: XCTFail("应失败")
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    func testTestNotificationBypassDebounce() {
        UserDefaults.standard.set(true, forKey: "iMessageNotify")
        UserDefaults.standard.set("15167104090", forKey: "iMessageNotifyRecipient")
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