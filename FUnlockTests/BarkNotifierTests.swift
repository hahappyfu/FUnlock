// FUnlockTests/BarkNotifierTests.swift
// Bark 推送通道测试：规范化纯函数 / URL 组装（send 与防抖在 Task 2 扩展）。
import XCTest
@testable import FUnlock

final class BarkNotifierTests: XCTestCase {
    func testNormalizeServerTrimsAndStripsTrailingSlash() {
        XCTAssertEqual(BarkNotifier.normalizeServer(" https://api.day.app/ "), "https://api.day.app")
        XCTAssertEqual(BarkNotifier.normalizeServer("https://api.day.app///"), "https://api.day.app")
    }

    func testNormalizeKeyTrims() {
        XCTAssertEqual(BarkNotifier.normalizeKey(" abc\n "), "abc")
    }

    func testBuildURLEncodesKeyAndJoins() {
        let url = BarkNotifier.buildURL(server: "https://api.day.app/", key: "abcXYZ")
        XCTAssertEqual(url?.absoluteString, "https://api.day.app/abcXYZ")
        let encoded = BarkNotifier.buildURL(server: "https://api.day.app", key: "a b")
        XCTAssertEqual(encoded?.absoluteString, "https://api.day.app/a%20b")
        XCTAssertNil(BarkNotifier.buildURL(server: "\n", key: "abc"))
    }
}
