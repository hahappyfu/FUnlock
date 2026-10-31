// FUnlockTests/BarkNotifierTests.swift
// Bark 推送通道测试：规范化 / URL 组装 / send 防抖 / 测试通知 / 注入点。
import XCTest
@testable import FUnlock

final class BarkNotifierTests: XCTestCase {

    private var testConfigStore: ConfigStore!
    private var capturedRequests: [URLRequest] = []
    private var fakeNow = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        super.setUp()
        testConfigStore = ConfigStore(suiteName: "com.fuhahah.FUnlock.test-bark")
        BarkNotifier.shared.configStore = testConfigStore
        capturedRequests = []
    }

    override func tearDown() {
        // 清理独立测试套件的配置，绝不触碰或删除用户真实偏好
        testConfigStore.defaults.removePersistentDomain(forName: "com.fuhahah.FUnlock.test-bark")
        BarkNotifier.shared.configStore = .shared
        BarkNotifier.shared.nowProvider = Date.init
        BarkNotifier.shared.requestSender = nil
        BarkNotifier.shared.resetDebounceForTesting()
        super.tearDown()
    }

    // MARK: - 测试工具

    private func enableBark() {
        testConfigStore.set(true, forKey: "barkNotify")
    }

    private func installSender(status: Int = 200) {
        capturedRequests = []
        BarkNotifier.shared.requestSender = { [weak self] req in
            self?.capturedRequests.append(req)
            return (status, Data())
        }
        BarkNotifier.shared.nowProvider = { [weak self] in self?.fakeNow ?? Date() }
    }

    /// 等待 utility 串行队列上的请求落定（RunLoop 让出主线程）。
    private func drainQueue(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Task 1 纯函数

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

    // MARK: - send 门控与防抖

    func testDisabledGateSkipsSend() {
        installSender()
        BarkNotifier.shared.send(.locked(reason: "manual", rssi: nil, deviceName: nil))
        drainQueue()
        XCTAssertTrue(capturedRequests.isEmpty)
    }

    func testEmptyKeyFallsBackToDefault() {
        enableBark()
        installSender()
        BarkNotifier.shared.send(.test)
        drainQueue()
        XCTAssertEqual(capturedRequests.count, 1)
        XCTAssertEqual(capturedRequests[0].url?.absoluteString,
                       BarkNotifier.Defaults.server + "/" + BarkNotifier.Defaults.key)
    }

    func testServerFallbackAndServerNormalization() {
        enableBark()
        installSender()
        BarkNotifier.shared.send(.test)
        drainQueue()
        XCTAssertEqual(capturedRequests.count, 1)
        XCTAssertEqual(capturedRequests[0].url?.host, URL(string: BarkNotifier.Defaults.server)?.host)

        capturedRequests.removeAll()
        BarkNotifier.shared.resetDebounceForTesting()
        testConfigStore.set("https://x.dev/", forKey: "barkNotifyServer")
        BarkNotifier.shared.send(.test)
        drainQueue()
        XCTAssertEqual(capturedRequests[0].url?.absoluteString,
                       "https://x.dev/\(BarkNotifier.Defaults.key)")
    }

    func testDebouncePerEventType() {
        enableBark()
        installSender()
        BarkNotifier.shared.send(.locked(reason: "r", rssi: nil, deviceName: nil))
        fakeNow = fakeNow.addingTimeInterval(10)
        BarkNotifier.shared.send(.locked(reason: "r", rssi: nil, deviceName: nil))  // 窗口内吞掉
        BarkNotifier.shared.send(.unlocked(rssi: nil, deviceName: nil))             // 不同类型独立窗口
        drainQueue()
        XCTAssertEqual(capturedRequests.count, 2)

        fakeNow = fakeNow.addingTimeInterval(40)
        BarkNotifier.shared.send(.locked(reason: "r", rssi: nil, deviceName: nil))  // 窗口过期可再发
        drainQueue()
        XCTAssertEqual(capturedRequests.count, 3)
    }

    func testFailureConsumesDebounceWindow() {
        enableBark()
        installSender(status: 503)
        BarkNotifier.shared.send(.locked(reason: "r", rssi: nil, deviceName: nil))
        drainQueue()
        fakeNow = fakeNow.addingTimeInterval(10)
        BarkNotifier.shared.send(.locked(reason: "r", rssi: nil, deviceName: nil))
        drainQueue()
        XCTAssertEqual(capturedRequests.count, 1, "失败同样占用 30s 防抖窗口")
    }

    // MARK: - 请求载荷

    func testRequestPayload() throws {
        enableBark()
        installSender()
        BarkNotifier.shared.send(.unlocked(rssi: -60, deviceName: "iPhone"))
        drainQueue()
        let req = try XCTUnwrap(capturedRequests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.timeoutInterval, 10)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(json.count, 4)
        XCTAssertEqual(json["group"] as? String, "funlock")
        XCTAssertEqual(json["level"] as? String, "timeSensitive")
        XCTAssertFalse((json["title"] as? String ?? "").isEmpty)
        XCTAssertFalse((json["body"] as? String ?? "").isEmpty)
    }

    // MARK: - sendTestNotification

    @MainActor
    func testSendTestNotificationBypassesDebounce() {
        enableBark()
        installSender()
        let first = expectation(description: "first completion")
        let second = expectation(description: "second completion")
        BarkNotifier.shared.sendTestNotification(title: "T", message: "M") { _ in first.fulfill() }
        BarkNotifier.shared.sendTestNotification(title: "T", message: "M") { _ in second.fulfill() }
        wait(for: [first, second], timeout: 2.0)
        XCTAssertEqual(capturedRequests.count, 2, "测试通知绕过防抖、可连续发送")
        BarkNotifier.shared.send(.test)
        drainQueue()
        XCTAssertEqual(capturedRequests.count, 3, "测试通知不写防抖窗口，send(.test) 仍立即可发")
    }

    @MainActor
    func testSendTestNotificationErrorBranches() {
        enableBark()
        installSender()
        // 空白 server 会被 getter 回退到 Defaults.server，需用「规范化后非空但 URL 非法」的值触发 nil 分支
        testConfigStore.set("ht tp://invalid server", forKey: "barkNotifyServer")
        let failureExp = expectation(description: "failure completion")
        var failureMessage: String?
        BarkNotifier.shared.sendTestNotification(title: "T", message: "M") { result in
            if case .failure(let error) = result { failureMessage = error.message }
            failureExp.fulfill()
        }
        wait(for: [failureExp], timeout: 2.0)
        XCTAssertTrue(failureMessage?.contains("服务器") ?? false, "实际: \(failureMessage ?? "nil")")

        installSender(status: 200)
        testConfigStore.set(BarkNotifier.Defaults.server, forKey: "barkNotifyServer")
        let successExp = expectation(description: "success completion")
        var succeeded = false
        BarkNotifier.shared.sendTestNotification(title: "T", message: "M") { result in
            if case .success = result { succeeded = true }
            successExp.fulfill()
        }
        wait(for: [successExp], timeout: 2.0)
        XCTAssertTrue(succeeded)
    }
}
