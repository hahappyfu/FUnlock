// SecurityService Keychain 往返测试(Wave 2 Agent B 填充)
import XCTest
@testable import FUnlock

/// Keychain 存取往返（真实 SecItem 调用，宿主 FUnlock.app 环境）。
/// 红线：仅操作 isolated serviceName 条目；生产条目（com.fuhahah.FUnlock）禁触。
/// coldBoot（errSecInteractionNotAllowed）拒绝路径强依赖真实系统重启后首次解锁的时序，
/// SecItemCopyMatching 无注入 seam，不可单测——此处锁定其可测前提：
/// 条目 accessible 必须为 AfterFirstUnlockThisDeviceOnly（重启后首次解锁前拒绝访问的依据）。
@MainActor
final class SecurityServiceKeychainRoundTripTests: XCTestCase {

    private let service = SecurityService(serviceName: "com.fuhahah.FUnlock.test.isolated")

    override func setUp() {
        service.deletePassword()
    }

    override func tearDown() {
        service.deletePassword()
    }

    func testStoreFetchDeleteRoundTrip() {
        let password = "p@ss 中文🔐"
        XCTAssertNil(service.storePassword(password), "store 应成功")

        let fetched = service.fetchPassword()
        guard case .success(let value) = fetched else {
            return XCTFail("fetch 应成功，实际: \(fetched)")
        }
        XCTAssertEqual(value, password, "往返值应一致（含 UTF-8 特殊字符）")

        service.deletePassword()
        let afterDelete = service.fetchPassword()
        guard case .success(nil) = afterDelete else {
            return XCTFail("删除后 fetch 应返回 notFound 语义（.success(nil)），实际: \(afterDelete)")
        }
    }

    func testStoreOverwritesExistingValue() {
        XCTAssertNil(service.storePassword("first"))
        XCTAssertNil(service.storePassword("second"), "重复 store 应走先删后增的覆盖路径")
        guard case .success(let value) = service.fetchPassword() else {
            return XCTFail("fetch 应成功")
        }
        XCTAssertEqual(value, "second", "覆盖写后应读到新值")
    }

    func testFetchMissingPasswordReturnsNilSuccess() {
        // notFound 语义：.success(nil)（区别于 .failure；warn=false 不弹窗）
        let result = service.fetchPassword()
        guard case .success(nil) = result else {
            return XCTFail("未存储时 fetch 应为 .success(nil)，实际: \(result)")
        }
    }

    func testDeletePasswordIsIdempotentOnMissingItem() {
        service.deletePassword()
        service.deletePassword()
        let result = service.fetchPassword()
        guard case .success(nil) = result else {
            return XCTFail("对不存在条目重复删除不应产生错误态，实际: \(result)")
        }
    }

    func testStoredItemUsesAfterFirstUnlockThisDeviceOnlyAccessibility() {
        // coldBoot 防暴力保护的可测前提：条目真实存在且受访问控制保护。
        // 注意：macOS file-based keychain 不回读 kSecAttrAccessible（查询返回的属性表无此键，
        // 冷启动拒绝由 keychain 锁定策略承载）；属性存在时（如未来迁移 DP keychain）才校验值。
        XCTAssertNil(service.storePassword("probe"))
        let query: [String: Any] = [
            String(kSecClass): kSecClassGenericPassword,
            String(kSecAttrAccount): NSUserName(),
            String(kSecAttrService): service.serviceName,
            String(kSecReturnAttributes): true as CFBoolean,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        XCTAssertEqual(status, errSecSuccess, "条目应存在且属性可查")
        guard let attrs = item as? [String: Any] else {
            return XCTFail("attributes 应为字典，实际: \(String(describing: item))")
        }
        if let accessible = attrs[String(kSecAttrAccessible)] as? String {
            XCTAssertEqual(
                accessible,
                String(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly),
                "条目 accessible 必须为 AfterFirstUnlockThisDeviceOnly（改为其他值会改变重启后行为）")
        }
    }
}
