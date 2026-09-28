import XCTest
@testable import FUnlock

// MARK: - Keychain 安全收紧：冷启动错误码捕获测试

/// 测试 KeychainError 枚举、冷启动检测、以及 SecurityService 返回值类型变更
class KeychainSecurityTests: XCTestCase {

    // MARK: - KeychainError 枚举

    func testColdBootErrorDescription() {
        let error = KeychainError.coldBoot
        XCTAssertTrue(error.description.contains("冷启动"), "coldBoot 描述应包含'冷启动'")
        XCTAssertTrue(error.description.contains("手动解锁"), "coldBoot 描述应包含'手动解锁'")
    }

    func testOtherErrorDescriptionWithMessage() {
        let error = KeychainError.other(errSecDuplicateItem, "duplicate")
        XCTAssertEqual(error.description, "duplicate", "有消息时应使用消息内容")
    }

    func testOtherErrorDescriptionWithoutMessage() {
        let error = KeychainError.other(errSecParam, nil)
        XCTAssertEqual(error.description, "Keychain 错误 Status \(errSecParam)",
                       "无消息时应显示 Status + code")
    }

    // MARK: - KeychainError.isColdBoot

    func testColdBootIsColdBootTrue() {
        let error = KeychainError.coldBoot
        XCTAssertTrue(error.isColdBoot, "coldBoot 的 isColdBoot 应为 true")
    }

    func testOtherErrorIsColdBootFalse() {
        let error = KeychainError.other(errSecItemNotFound, nil)
        XCTAssertFalse(error.isColdBoot, "other 错误的 isColdBoot 应为 false")
    }

    // MARK: - KeychainError.osStatus

    func testColdBootOsStatusIsNil() {
        let error = KeychainError.coldBoot
        XCTAssertNil(error.osStatus, "coldBoot 的 osStatus 应为 nil")
    }

    func testOtherErrorOsStatusReturnsCode() {
        let error = KeychainError.other(errSecInteractionNotAllowed, nil)
        XCTAssertEqual(error.osStatus, errSecInteractionNotAllowed,
                       "other 错误的 osStatus 应返回存储的 OSStatus")
    }

    // MARK: - KeychainError 符合 Error 协议

    func testColdBootConformsToError() {
        let error: Error = KeychainError.coldBoot
        XCTAssertTrue(error is KeychainError, "KeychainError.coldBoot 应符合 Error 协议")
    }

    // MARK: - SecurityService 可用性常量

    func testAccessibleAfterFirstUnlockConstantExists() {
        // 验证 kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly 是有效常量
        let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // 该常量应为非 nil CFString
        XCTAssertNotNil(accessibility, "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly 应存在")
    }

    // MARK: - 冷启动语义验证

    func testColdBootMeansUserHasNotUnlockedSinceRestart() {
        // 验证冷启动错误的语义：设备重启后用户未手动解锁一次
        let error = KeychainError.coldBoot
        XCTAssertTrue(error.description.contains("重启"), "冷启动错误应提及重启场景")
        XCTAssertTrue(error.isColdBoot, "应通过 isColdBoot 便捷属性识别冷启动")
    }

    // MARK: - storePassword 使用新 accessibility 常量

    func testStorePasswordDoesNotReturnErrorOnSuccess() {
        // 安全隔离：使用独立测试 serviceName，防止删除或污染真实 Keychain 密码
        let service = SecurityService(serviceName: "com.fuhahah.FUnlock.test.isolated")
        let testPassword = "test_keychain_security_\(UUID().uuidString)"
        let storeResult = service.storePassword(testPassword)
        // 成功时返回 nil（无错误）
        XCTAssertNil(storeResult, "storePassword 成功时应返回 nil")
        // 清理：删除测试密码
        service.deletePassword()
    }

    func testDeletePasswordDoesNotCrash() {
        let service = SecurityService(serviceName: "com.fuhahah.FUnlock.test.isolated")
        // deletePassword 不返回值，不应崩溃
        service.deletePassword()
        // 调用两次也不应崩溃
        service.deletePassword()
    }

    // MARK: - handlePasswordChanged 适配 Result 类型

    @MainActor
    func testHandlePasswordChangedDoesNotCrashWithNoPassword() {
        // 安全隔离：使用独立测试 serviceName
        let service = SecurityService(serviceName: "com.fuhahah.FUnlock.test.isolated")
        service.deletePassword()
        // 不应崩溃
        service.handlePasswordChanged()
    }
}
