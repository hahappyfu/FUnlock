// FUnlockTests/ConfigStoreTests.swift
import XCTest
@testable import FUnlock

final class ConfigStoreTests: XCTestCase {
    private var store: ConfigStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ConfigStoreTests-\(UUID().uuidString)"
        store = ConfigStore(suiteName: suiteName)
    }

    override func tearDown() {
        // 清理当前 suite 域的持久化文件（removePersistentDomain 按域名生效，与实例无关）
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        store = nil
        suiteName = nil
        super.tearDown()
    }

    /// 迁移：standard 有旧值 → 搬到 suite（用独立测试 key，不碰真实生产 key）
    func testMigrateMovesLegacyValues() {
        // 准备旧值：备份 standard 原值，结束后恢复，避免破坏真实配置
        let legacyKey = "testMigrateMovesLegacyValues_key"
        let original = UserDefaults.standard.object(forKey: legacyKey)
        UserDefaults.standard.set("legacy", forKey: legacyKey)
        defer { restore(original, forKey: legacyKey) }

        store.migrateIfNeeded(fromKeys: [legacyKey])

        XCTAssertEqual(store.defaults.string(forKey: legacyKey), "legacy",
                       "迁移后 suite 应包含旧值")
    }

    /// 幂等：第二次 migrateIfNeeded 不再覆盖
    func testMigrateIsIdempotent() {
        let legacyKey = "testMigrateIsIdempotent_key"
        let original = UserDefaults.standard.object(forKey: legacyKey)
        UserDefaults.standard.set("v1", forKey: legacyKey)
        defer { restore(original, forKey: legacyKey) }

        store.migrateIfNeeded(fromKeys: [legacyKey])
        store.defaults.set("v2", forKey: legacyKey) // 用户在 suite 中改了值
        store.migrateIfNeeded(fromKeys: [legacyKey])

        XCTAssertEqual(store.defaults.string(forKey: legacyKey), "v2",
                       "已迁移后再次调用不应覆盖 suite 中用户新值")
    }

    /// 把 standard 中某 key 恢复为原值（nil 表示原本不存在 → 删除）
    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// 读写
    func testSetGet() {
        store.set(42, forKey: "intKey")
        XCTAssertEqual(store.get("intKey", fallback: 0), 42)
        store.set("hello", forKey: "strKey")
        XCTAssertEqual(store.get("strKey", fallback: ""), "hello")
    }

    /// 布尔默认值测试：未配置时正确返回业务默认值（enabled/lockOnIdle 为 true，其余为 false）
    func testBoolDefaultValues() {
        XCTAssertTrue(store.bool(forKey: "enabled"), "enabled 键未配置时应默认返回 true")
        XCTAssertTrue(store.bool(forKey: "lockOnIdle"), "lockOnIdle 键未配置时应默认返回 true")
        XCTAssertFalse(store.bool(forKey: "passiveMode"), "passiveMode 键未配置时应默认返回 false")
    }

    /// 导出与导入测试：基本类型与 Data(base64) 正确还原，并能正确更新
    func testExportAndImportAllSettings() {
        store.set("iPhone 15", forKey: "deviceName")
        store.set(-65, forKey: "unlockRSSI")
        store.set(-80, forKey: "lockRSSI")
        store.set(true, forKey: "enabled")

        guard let json = store.exportAllSettings() else {
            XCTFail("exportAllSettings 应成功生成 JSON")
            return
        }

        // 创建另一个隔离 store 导入
        let newSuite = "ConfigStoreTests-Import-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: newSuite) }
        let newStore = ConfigStore(suiteName: newSuite)

        let stats = newStore.importAllSettings(json: json)
        XCTAssertNotNil(stats, "导入合法 JSON 应返回成功统计")
        XCTAssertEqual(newStore.defaults.string(forKey: "deviceName"), "iPhone 15")
        XCTAssertEqual(newStore.defaults.integer(forKey: "unlockRSSI"), -65)
        XCTAssertEqual(newStore.defaults.integer(forKey: "lockRSSI"), -80)
        XCTAssertTrue(newStore.bool(forKey: "enabled"))
    }

    /// 导入阈值防御校验：非法负迟滞（lock >= unlock）导入时自动钳制为 lock < unlock
    func testImportSettingsThresholdSanitization() {
        let maliciousDict: [String: String] = [
            "unlockRSSI": "-70",
            "lockRSSI": "-50", // 非法：锁定阈值反而比解锁阈值更近
            "deviceName": "TestPhone",
            "_exportedKeys": "unlockRSSI,lockRSSI,deviceName"
        ]
        let data = try! JSONEncoder().encode(maliciousDict)
        let json = String(data: data, encoding: .utf8)!

        let stats = store.importAllSettings(json: json)
        XCTAssertNotNil(stats)
        let importedUnlock = store.defaults.integer(forKey: "unlockRSSI")
        let importedLock = store.defaults.integer(forKey: "lockRSSI")
        XCTAssertEqual(importedUnlock, -70)
        XCTAssertLessThan(importedLock, importedUnlock, "导入时锁定阈值必须被强制钳制在解锁阈值以下（lock < unlock）")
    }

    /// 导入时 keysToRemove 只能删除已知业务 key，无法删除未授权的恶意 key
    func testImportCannotDeleteArbitraryKeys() {
        let secretKey = "super_secret_internal_key"
        store.defaults.set("important_data", forKey: secretKey)

        let fakeDict: [String: String] = [
            "deviceName": "MyDevice",
            "_exportedKeys": "deviceName,\(secretKey)" // 试图通过伪造 exportedKeys 删除敏感 key
        ]
        let data = try! JSONEncoder().encode(fakeDict)
        let json = String(data: data, encoding: .utf8)!

        let stats = store.importAllSettings(json: json)
        XCTAssertNotNil(stats)
        XCTAssertEqual(store.defaults.string(forKey: secretKey), "important_data",
                       "importAllSettings 必须过滤非 exportableKeys，防止恶意擦除任意 key")
    }
}
