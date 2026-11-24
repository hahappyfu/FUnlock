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

    // MARK: - Data(base64) 与全量 key 往返

    /// 全量 key 的真实类型清单(从各写入调用点核实):
    /// Bool → set(_:forKey:) 各开关;Int → 阈值/秒数;String → 设备/SSID/收件人/档案 ID;
    /// Data → profiles(ProfileManager.save);Double → lastUpdateCheck(checkUpdate.swift
    /// defaults.set(lastCheckAt),UpdateChecker 以 defaults.double(forKey:) 读回)
    private static let boolKeys = [
        "enabled", "launchAtLogin", "lockOnIdle", "passiveMode",
        "wakeOnProximity", "wakeWithoutUnlocking", "sleepDisplay", "screensaver",
        "pauseOnWiFi", "pauseItunes", "iMessageNotify", "manualLockNoAutoUnlock",
        "hasCompletedOnboarding", "hasShownGuide", "hasCheckedAccessibility",
        "permissionOnboarded", "barkNotify",
    ]
    private static let intKeys: [String: Int] = [
        "lockRSSI": -75, "unlockRSSI": -62, "wakeAdvance": 12, "preUnlockTrigger": 8,
        "thresholdRSSI": -90, "timeout": 45, "lockDelay": 7, "unlockMargin": 3,
    ]
    private static let stringKeys: [String: String] = [
        "device": "AA:BB:CC:DD:EE:FF", "deviceName": "iPhone 15",
        "pauseOnWiFiSSID": "Home-5G", "iMessageNotifyRecipient": "user@icloud.com",
        "activeProfileID": "work-profile",
        "barkNotifyServer": "https://api.day.app",
    ]
    /// 敏感键（Task 14 起不再参与导出/导入往返；单独用 testExportRedacts… 覆盖）
    private static let sensitiveKeysList = ["barkNotifyKey"]
    private static let dataKey = "profiles"
    private static let doubleKey = "lastUpdateCheck"

    /// key 清单防漂移:全量往返的分组清单必须与 ConfigStore.exportableKeys 完全一致,
    /// 新增 key 漏登记会静默绕过往返校验
    func testRoundtripKeyListsCoverAllExportableKeys() {
        var all = Set(Self.boolKeys)
        all.formUnion(Self.intKeys.keys)
        all.formUnion(Self.stringKeys.keys)
        all.insert(Self.dataKey)
        all.insert(Self.doubleKey)
        // 敏感键仍登记在 exportableKeys（白名单判定用），但导出/导入路径跳过
        all.formUnion(Self.sensitiveKeysList)
        XCTAssertEqual(all, Set(ConfigStore.exportableKeys),
                       "全量往返 key 清单必须与 exportableKeys 一一对应")
    }

    /// Data 经 "_b64:" base64 前缀导出 → 导入后逐字节还原
    func testDataRoundtripThroughExportImport() {
        let payload = Data("{\"id\":\"work-profile\",\"unlockRSSI\":-62}".utf8)
        store.set(payload, forKey: Self.dataKey)

        guard let json = store.exportAllSettings() else {
            XCTFail("exportAllSettings 应成功生成 JSON")
            return
        }
        XCTAssertTrue(json.contains("_b64:"), "Data 值导出应带 _b64: base64 前缀")

        let newSuite = "ConfigStoreTests-DataRT-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: newSuite) }
        let newStore = ConfigStore(suiteName: newSuite)

        XCTAssertNotNil(newStore.importAllSettings(json: json))
        XCTAssertEqual(newStore.defaults.data(forKey: Self.dataKey), payload,
                       "Data(base64) 导出→导入应逐字节还原")
    }

    /// 全量 key 往返:设置全部 31 个业务 key → 导出 → 清空 → 导入 → 逐 key 相等
    /// (按生产读取访问器断言:bool/integer/string/getData)
    func testFullKeyRoundtripExportWipeImport() {
        for (i, key) in Self.boolKeys.enumerated() { store.set(i % 2 == 0, forKey: key) }
        for (key, value) in Self.intKeys { store.set(value, forKey: key) }
        for (key, value) in Self.stringKeys { store.set(value, forKey: key) }
        store.set(Data("{\"id\":\"work-profile\"}".utf8), forKey: Self.dataKey)
        // lastUpdateCheck 生产写入路径是裸 defaults.set(Double)(checkUpdate.swift)
        store.defaults.set(1_759_000_000.5, forKey: Self.doubleKey)

        guard let json = store.exportAllSettings() else {
            XCTFail("exportAllSettings 应成功生成 JSON")
            return
        }

        // 清空全部业务 key
        for key in ConfigStore.exportableKeys {
            store.defaults.removeObject(forKey: key)
        }
        for key in ConfigStore.exportableKeys {
            XCTAssertNil(store.defaults.object(forKey: key), "清空后 \(key) 应不存在")
        }

        let stats = store.importAllSettings(json: json)
        XCTAssertNotNil(stats, "合法导出文件应可导入")
        // 敏感键不参与导出/导入：applied = 总数 - 敏感键数
        let nonSensitiveCount = ConfigStore.exportableKeys.count - ConfigStore.sensitiveKeys.count
        XCTAssertEqual(stats?.applied, nonSensitiveCount,
                       "应还原全部 \(nonSensitiveCount) 个非敏感业务 key")

        // 逐 key 相等(布尔用 true/false 混合值防跨 key 串值)
        for (i, key) in Self.boolKeys.enumerated() {
            XCTAssertEqual(store.bool(forKey: key), i % 2 == 0, "布尔 key \(key) 往返不一致")
        }
        for (key, value) in Self.intKeys {
            XCTAssertEqual(store.defaults.integer(forKey: key), value, "整数 key \(key) 往返不一致")
        }
        for (key, value) in Self.stringKeys {
            XCTAssertEqual(store.string(forKey: key), value, "字符串 key \(key) 往返不一致")
        }
        XCTAssertEqual(store.defaults.data(forKey: Self.dataKey),
                       Data("{\"id\":\"work-profile\"}".utf8), "Data key \(Self.dataKey) 往返不一致")

        // finding(2026-09-28): lastUpdateCheck 生产写入为 Double,导出统一 "\(value)"
        // 字符串化,导入 decodeSettingValue 只还原 Bool/Int/Data/String → Double 变 String。
        // 影响评估:UIDefaults 的 double(forKey:) 对数值字符串可强制转换,UpdateChecker
        // 功能无损;缺陷仅为类型保真(object(forKey:) as? Double 失败)。
        // 修复 decodeSettingValue 支持 Double 后,应将本断言改为还原 Double 且数值相等。
        let imported = store.defaults.object(forKey: Self.doubleKey)
        XCTAssertTrue(imported is String,
                      "已知类型漂移:Double 经 export→import 变为 String(见 finding);若本断言失败说明已修复,请同步改断言")
        XCTAssertEqual(store.defaults.double(forKey: Self.doubleKey), 1_759_000_000.5, accuracy: 0.001,
                       "数值字符串经 double(forKey:) 强制转换仍可读回,更新检查节流功能不受影响")
    }

    /// finding(2026-09-28): 值字符串化丢类型 — 纯数字/带符号数字字符串(如全数字 SSID、
    /// "+86" 开头手机号)导出后被 decodeSettingValue 还原为 Int(string→Int 类型漂移)。
    /// 影响评估:string(forKey:) 对数值可强制转换读回,pauseOnWiFiSSID 匹配功能无损;
    /// 仅 object(forKey:) as? String 精确转型分支受影响。同根因见 lastUpdateCheck(Double→String)。
    /// finding(2026-09-28) 已在 Task 17 修复：stringKeys（SSID/手机号）导入后保持 String。
    /// 旧缺陷：纯数字/带符号数字字符串导出后被还原为 Int（类型漂移、+ 号丢失）。
    func testImportNumericStringLosesStringType() {
        store.set("12345678", forKey: "pauseOnWiFiSSID")

        guard let json = store.exportAllSettings() else {
            XCTFail("exportAllSettings 应成功生成 JSON")
            return
        }
        store.defaults.removeObject(forKey: "pauseOnWiFiSSID")

        XCTAssertNotNil(store.importAllSettings(json: json))
        XCTAssertTrue(store.defaults.object(forKey: "pauseOnWiFiSSID") is String,
                      "Task 17 修复后：纯数字 SSID 必须保持 String 类型")
        XCTAssertEqual(store.defaults.string(forKey: "pauseOnWiFiSSID"), "12345678")

        // 旧缺陷第二形态（已修复）：带 + 号的手机号不得被解析为 Int
        store.set("+8613800000000", forKey: "iMessageNotifyRecipient")
        guard let json2 = store.exportAllSettings() else {
            XCTFail("exportAllSettings 应成功生成 JSON")
            return
        }
        store.defaults.removeObject(forKey: "iMessageNotifyRecipient")
        XCTAssertNotNil(store.importAllSettings(json: json2))
        XCTAssertTrue(store.defaults.object(forKey: "iMessageNotifyRecipient") is String,
                      "Task 17 修复后：手机号必须保持 String 类型")
        XCTAssertEqual(store.defaults.string(forKey: "iMessageNotifyRecipient"), "+8613800000000",
                       "Task 17 修复后：+ 号在往返中保持不丢")
    }

    /// finding(2026-09-28)修复后表征: "_b64:" 前缀但 base64 解码失败时,decodeSettingValue
    /// 保持原字符串落盘(导出→导入幂等,不扩散成其他类型),但会写 debug 告警日志;
    /// 读取方 defaults.data(forKey:) 返回 nil(如 profiles → JSON 解析失败回退默认档案)。
    func testImportMalformedBase64KeepsStringWithWarning() {
        let dict: [String: String] = [
            "profiles": "_b64:###not-base64###",
            "_exportedKeys": "profiles",
        ]
        let json = String(data: try! JSONEncoder().encode(dict), encoding: .utf8)!

        let stats = store.importAllSettings(json: json)
        XCTAssertNotNil(stats, "含已知业务 key 的导入应被接受")
        XCTAssertNil(store.defaults.data(forKey: Self.dataKey), "损坏 base64 不应还原出 Data")
        XCTAssertEqual(store.defaults.string(forKey: Self.dataKey), "_b64:###not-base64###",
                       "解码失败应保持原字符串落盘(幂等),仅告警不改变值")
    }

    /// 导入越界阈值钳制:unlock 低于下界 -95 → 钳制到 -95;
    /// lock 高于 unlock → 强制钳到 unlock-1(序关系优先于原值)
    func testImportClampsOutOfRangeRSSIValues() {
        let dict: [String: String] = [
            "unlockRSSI": "-500",
            "lockRSSI": "-40",
            "_exportedKeys": "unlockRSSI,lockRSSI",
        ]
        let json = String(data: try! JSONEncoder().encode(dict), encoding: .utf8)!

        let stats = store.importAllSettings(json: json)
        XCTAssertNotNil(stats)
        XCTAssertEqual(store.defaults.integer(forKey: "unlockRSSI"),
                       SignalHysteresisEngine.rssiRange.lowerBound,
                       "低于下界的解锁阈值应被钳制到 -95")
        let importedLock = store.defaults.integer(forKey: "lockRSSI")
        XCTAssertLessThan(importedLock, store.defaults.integer(forKey: "unlockRSSI"),
                          "锁定阈值必须被强制钳制在解锁阈值以下")
        // 说明:钳制只作用于 Int 型 RSSI 阈值;Data 值(profiles)无范围语义,
        // 不参与钳制,其导入防御缺陷见 testImportMalformedBase64DegradesToStringSilently
    }

    // MARK: - Task 14：敏感键脱敏导出与 HTTPS 导入校验

    /// 导出排除 barkNotifyKey（值与 _exportedKeys 均不含）；导入不覆盖本机 Key、拒绝 http 服务器
    func testExportRedactsBarkKeyAndImportRejectsHTTPServerWhilePreservingLocalKey() {
        store.set("my-secret-key", forKey: "barkNotifyKey")
        store.set("https://api.day.app", forKey: "barkNotifyServer")
        guard let json = store.exportAllSettings() else {
            return XCTFail("导出应成功")
        }
        XCTAssertFalse(json.contains("my-secret-key"), "导出不得包含 Bark Key 明文")
        XCTAssertFalse(json.contains("barkNotifyKey"), "导出清单也不得含敏感键名")

        let malicious = """
        {"enabled":"true","barkNotifyKey":"attacker","barkNotifyServer":"http://evil.com","_exportedKeys":"enabled,barkNotifyKey,barkNotifyServer"}
        """
        _ = store.importAllSettings(json: malicious)
        XCTAssertEqual(store.string(forKey: "barkNotifyKey"), "my-secret-key",
                       "导入不得覆盖本机已有 Bark Key")
        XCTAssertNotEqual(store.string(forKey: "barkNotifyServer"), "http://evil.com",
                          "明文 http 服务器必须被拒绝写入")
    }

    // MARK: - Task 17：导出/导入类型精确还原

    /// 纯数字字符串（SSID/手机号/设备名）不得被误转 Int；Bool 不得变成 "1"/"0"
    func testExportImportPreservesNumericStringsAndBooleans() {
        store.set("123456", forKey: "pauseOnWiFiSSID")
        store.set("13800138000", forKey: "iMessageNotifyRecipient")
        store.set("42", forKey: "deviceName")
        store.set(true, forKey: "enabled")
        store.set(false, forKey: "passiveMode")
        store.set(-65, forKey: "unlockRSSI")

        guard let json = store.exportAllSettings() else { return XCTFail("导出应成功") }
        let roundtripSuite = "com.fuhahah.FUnlock.test-roundtrip-\(UUID().uuidString)"
        let imported = ConfigStore(suiteName: roundtripSuite)
        defer { imported.defaults.removePersistentDomain(forName: roundtripSuite) }
        _ = imported.importAllSettings(json: json)

        XCTAssertTrue(imported.object(forKey: "pauseOnWiFiSSID") is String)
        XCTAssertEqual(imported.string(forKey: "pauseOnWiFiSSID"), "123456")
        XCTAssertTrue(imported.object(forKey: "iMessageNotifyRecipient") is String)
        XCTAssertEqual(imported.string(forKey: "iMessageNotifyRecipient"), "13800138000")
        XCTAssertTrue(imported.object(forKey: "deviceName") is String, "纯数字设备名必须保持 String")
        XCTAssertTrue(imported.bool(forKey: "enabled"))
        XCTAssertTrue(imported.defaults.object(forKey: "enabled") is Bool, "Bool 导入后仍须是 Bool 类型")
        XCTAssertFalse(imported.bool(forKey: "passiveMode"))
        XCTAssertEqual(imported.object(forKey: "unlockRSSI") as? Int, -65)
    }

    /// 旧版导出文件用 "1"/"0" 表示布尔：导入需兼容还原为 Bool
    func testImportLegacyNumericBoolStrings() {
        let legacy = """
        {"enabled":"1","passiveMode":"0","launchAtLogin":"1","_exportedKeys":""}
        """
        XCTAssertNotNil(store.importAllSettings(json: legacy))
        XCTAssertTrue(store.bool(forKey: "enabled"))
        XCTAssertTrue(store.defaults.object(forKey: "enabled") is Bool, "旧版数字字符串应还原为 Bool true")
        XCTAssertFalse(store.bool(forKey: "passiveMode"))
        XCTAssertTrue(store.bool(forKey: "launchAtLogin"))
    }

    /// 回归：XCTest 进程中 ConfigStore.shared 必须自动隔离到独立测试域，不得写入本机生产配置域
    func testSharedStoreIsIsolatedFromProductionSuiteUnderXCTest() {
        XCTAssertNotEqual(ConfigStore.defaultSuiteName, ConfigStore.suiteName,
                          "XCTest 进程下 defaultSuiteName 必须与生产 suiteName 分离")
        let canaryKey = "__xctest_isolation_canary_\(UUID().uuidString)"
        ConfigStore.shared.set("isolated", forKey: canaryKey)
        defer { ConfigStore.shared.removeObject(forKey: canaryKey) }

        let prodDefaults = UserDefaults(suiteName: ConfigStore.suiteName)
        XCTAssertNil(prodDefaults?.object(forKey: canaryKey),
                     "写入 ConfigStore.shared 绝不能穿透到生产配置域 \(ConfigStore.suiteName)")
    }
}
