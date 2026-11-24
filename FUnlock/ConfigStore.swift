// FUnlock/ConfigStore.swift
import Foundation

/// 配置存储：独立 suite 域，与 bundle id 解耦。
/// 覆盖安装 app 后配置不丢失（偏好域不随 bundle 替换而重建）。
/// 所有配置读写走这里，不再直接使用 UserDefaults.standard。
///
/// 线程契约（@unchecked Sendable 依据）：实例唯一持有的引用 `defaults` 为 let
/// （初始化后不再变化），且 UserDefaults 自身文档明确线程安全（"UserDefaults is thread-safe"），
/// 故跨线程共享本类实例不会引入数据竞争。
final class ConfigStore: @unchecked Sendable {
    static let shared = ConfigStore(suiteName: ConfigStore.defaultSuiteName)

    /// 固定生产 suite 域名（不随 bundle id 变）
    static let suiteName = "com.fuhahah.Funlock.config"
    /// 运行时默认 suite 域名：XCTest 进程中自动隔离到独立测试域，防止单元测试污染本机真实配置
    static var defaultSuiteName: String {
        if NSClassFromString("XCTestCase") != nil {
            return "\(suiteName).xctest"
        }
        return suiteName
    }
    private static let didMigrateKey = "didMigrate"

    let defaults: UserDefaults

    /// 测试注入：允许指定 suite 名隔离
    init(suiteName: String = ConfigStore.defaultSuiteName) {
        // UserDefaults(suiteName:) 失败时回退 standard（理论不触发）
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    // MARK: - 迁移

    /// 一次性迁移：把旧 standard 的指定 key 搬到 suite。
    /// - Parameter keys: 需要迁移的业务 key 清单（不含系统 key）。
    func migrateIfNeeded(fromKeys keys: [String]) {
        guard !defaults.bool(forKey: ConfigStore.didMigrateKey) else { return }
        let standard = UserDefaults.standard
        // cfprefsd 缓存可能未就绪：阻塞同步磁盘，确保 standard 有值时能读到（避免空跑迁移）
        standard.synchronize()
        for key in keys {
            if let value = standard.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: ConfigStore.didMigrateKey)
    }

    // MARK: - 读写

    func get(_ key: String, fallback: Int) -> Int {
        defaults.object(forKey: key) as? Int ?? fallback
    }
    func get(_ key: String, fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }
    func get(_ key: String, fallback: String) -> String {
        defaults.object(forKey: key) as? String ?? fallback
    }
    func getData(_ key: String) -> Data? {
        defaults.data(forKey: key)
    }
    func set(_ value: Int, forKey key: String) { defaults.set(value, forKey: key) }
    func set(_ value: Bool, forKey key: String) { defaults.set(value, forKey: key) }
    func set(_ value: String, forKey key: String) { defaults.set(value, forKey: key) }
    func set(_ value: Data, forKey key: String) { defaults.set(value, forKey: key) }
    func removeObject(forKey key: String) { defaults.removeObject(forKey: key) }
    func object(forKey key: String) -> Any? { defaults.object(forKey: key) }

    /// 业务布尔默认值表：统一全项目业务默认值（如 enabled/lockOnIdle 默认 true）
    static func defaultBool(for key: String) -> Bool {
        switch key {
        case "enabled", "lockOnIdle":
            return true
        default:
            return false
        }
    }

    /// 读取布尔配置：键缺失时自动回退业务默认值（防裸读 false 与 UI 默认 true 的双语义冲突）
    func bool(forKey key: String) -> Bool {
        guard let obj = defaults.object(forKey: key) else {
            return ConfigStore.defaultBool(for: key)
        }
        return (obj as? Bool) ?? defaults.bool(forKey: key)
    }

    /// 读取布尔配置，当键缺失（未设置）时回退到显式指定的默认值
    func bool(forKey key: String, default defaultVal: Bool) -> Bool {
        guard let obj = defaults.object(forKey: key) else { return defaultVal }
        return (obj as? Bool) ?? defaults.bool(forKey: key)
    }
    func string(forKey key: String) -> String? { defaults.string(forKey: key) }

    // MARK: - 全量设置导出/导入

    /// 可导出的业务 key（legacyKeys + 后续新增 key；不含 didMigrate 等内部标记）
    static let exportableKeys = legacyKeys + [
        "permissionOnboarded",
    ]

    /// 敏感键：导出时跳过（值与清单均不含），导入时不删除、不覆盖本机已有值。
    static let sensitiveKeys: Set<String> = ["barkNotifyKey"]

    private static let exportedKeysKey = "_exportedKeys"
    private static let dataPrefix = "_b64:"

    /// 导出全部业务设置为 JSON：Bool 输出 "true"/"false"（CFBoolean 判定），
    /// Data 走 base64 前缀，其余按类型字符串化；附带 _exportedKeys 清单，
    /// 导入时按清单删除旧 key（支持多设备配置完全替换）。
    func exportAllSettings() -> String? {
        var dict: [String: String] = [:]
        for key in ConfigStore.exportableKeys {
            // 敏感键不导出（密钥明文离开本机的风险）
            guard !ConfigStore.sensitiveKeys.contains(key) else { continue }
            guard let value = defaults.object(forKey: key) else { continue }
            if let data = value as? Data {
                dict[key] = ConfigStore.dataPrefix + data.base64EncodedString()
            } else if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
                dict[key] = (value as? Bool) == true ? "true" : "false"
            } else {
                dict[key] = "\(value)"
            }
        }
        let exportList = ConfigStore.exportableKeys.filter { !ConfigStore.sensitiveKeys.contains($0) }
        dict[ConfigStore.exportedKeysKey] = exportList.joined(separator: ",")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 导入结果统计
    struct SettingsImportStats {
        let applied: Int
        let removed: Int
    }

    /// 从 JSON 恢复全部设置：先删清单内的旧 key，再逐 key 写回。
    /// 兼容读取：Int/Bool/String/Data(base64) 按原类型还原。解析失败返回 nil（不落盘）。
    func importAllSettings(json: String) -> SettingsImportStats? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data),
              !dict.isEmpty else {
            return nil
        }
        // 至少命中一个已知业务 key 才视为合法设置文件，避免误吃任意 JSON
        let knownKeys = Set(ConfigStore.exportableKeys)
        guard dict.keys.contains(where: { knownKeys.contains($0) }) else { return nil }

        let keysToRemove = (dict[ConfigStore.exportedKeysKey]?
            .split(separator: ",").map(String.init)) ?? []
        var removed = 0
        for key in keysToRemove where key != ConfigStore.exportedKeysKey && knownKeys.contains(key) {
            // 敏感键不删除：本机已有密钥不被导入文件清掉
            guard !ConfigStore.sensitiveKeys.contains(key) else { continue }
            if defaults.object(forKey: key) != nil {
                defaults.removeObject(forKey: key)
                removed += 1
            }
        }

        var applied = 0
        for (key, raw) in dict where key != ConfigStore.exportedKeysKey {
            guard knownKeys.contains(key) else { continue }
            // 敏感键不写入：导入文件不得覆盖/植入推送密钥
            guard !ConfigStore.sensitiveKeys.contains(key) else { continue }
            // Bark 服务器明文 http 会泄漏推送 Key：非空时必须是 https
            if key == "barkNotifyServer" {
                let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty && !normalized.lowercased().hasPrefix("https://") {
                    AppLog.error(.app, "importRejectedNonHTTPS", [("key", key), ("value", normalized)])
                    continue
                }
            }
            let value = ConfigStore.decodeSettingValue(raw, key: key)
            defaults.set(value, forKey: key)
            applied += 1
        }

        // 阈值范围与序关系校验：防止导入非法负迟滞（lock >= unlock）或越界配置
        if let u = defaults.object(forKey: "unlockRSSI") as? Int, u != SignalHysteresisEngine.unlockDisabled {
            let clampedU = SignalHysteresisEngine.clampRSSI(u)
            if clampedU != u { defaults.set(clampedU, forKey: "unlockRSSI") }
            if let l = defaults.object(forKey: "lockRSSI") as? Int, l != SignalHysteresisEngine.lockDisabled {
                let clampedL = min(SignalHysteresisEngine.clampRSSI(l), clampedU - 1)
                if clampedL != l { defaults.set(clampedL, forKey: "lockRSSI") }
            }
        } else if let l = defaults.object(forKey: "lockRSSI") as? Int, l != SignalHysteresisEngine.lockDisabled {
            let clampedL = SignalHysteresisEngine.clampRSSI(l)
            if clampedL != l { defaults.set(clampedL, forKey: "lockRSSI") }
        }
        return SettingsImportStats(applied: applied, removed: removed)
    }

    // MARK: - key 类型表（导出/导入精确还原）

    /// 布尔开关键。导出为 "true"/"false"（CFBoolean 判定，不会变成 "1"/"0"）。
    static let boolKeys: Set<String> = [
        "enabled", "launchAtLogin", "lockOnIdle", "passiveMode",
        "wakeOnProximity", "wakeWithoutUnlocking", "sleepDisplay", "screensaver",
        "pauseOnWiFi", "pauseItunes", "iMessageNotify", "manualLockNoAutoUnlock",
        "hasCompletedOnboarding", "hasShownGuide", "hasCheckedAccessibility",
        "permissionOnboarded", "barkNotify",
    ]
    /// 整数键（阈值/秒数）。
    static let intKeys: Set<String> = [
        "lockRSSI", "unlockRSSI", "wakeAdvance", "preUnlockTrigger",
        "thresholdRSSI", "timeout", "lockDelay", "unlockMargin",
    ]
    /// 字符串键：即使值是纯数字（SSID/手机号/设备名）也必须保持 String，不误转 Int。
    static let stringKeys: Set<String> = [
        "device", "deviceName", "pauseOnWiFiSSID",
        "iMessageNotifyRecipient", "activeProfileID", "barkNotifyServer",
    ]
    /// Data 键（JSON payload）。
    static let dataKeys: Set<String> = ["profiles"]

    /// 导入按 key 已知类型还原：Bool 兼容旧版 "1"/"0"；stringKeys 恒为 String（不误转 Int）。
    private static func decodeSettingValue(_ raw: String, key: String) -> Any {
        if raw.hasPrefix(dataPrefix) {
            if let d = Data(base64Encoded: String(raw.dropFirst(dataPrefix.count))) {
                return d
            }
            AppLog.error(.app, "importBase64DecodeFailed", [("prefix", String(raw.prefix(48)))])
        }
        if boolKeys.contains(key) {
            if raw == "true" { return true }
            if raw == "false" { return false }
            // 旧版导出格式兼容："1"/"0" 视为布尔
            if raw == "1" { return true }
            if raw == "0" { return false }
        }
        if stringKeys.contains(key) {
            // 字符串键恒为 String：纯数字（SSID/手机号）不得误转 Int
            return raw
        }
        if intKeys.contains(key) || dataKeys.contains(key) || key == "lastUpdateCheck" {
            if let i = Int(raw) { return i }
        }
        if raw == "true" { return true }
        if raw == "false" { return false }
        if let i = Int(raw) { return i }
        return raw
    }
}

extension ConfigStore {
    /// 需要迁移的业务 key 全量清单（迁移时逐 key 搬迁）
    static let legacyKeys: [String] = [
        "device", "deviceName", "enabled", "launchAtLogin",
        "lockRSSI", "unlockRSSI", "wakeAdvance", "preUnlockTrigger",
        "lockOnIdle", "passiveMode", "wakeOnProximity", "wakeWithoutUnlocking",
        "sleepDisplay", "screensaver", "pauseOnWiFi", "pauseOnWiFiSSID",
        "pauseItunes", "iMessageNotify", "iMessageNotifyRecipient",
        "barkNotify", "barkNotifyKey", "barkNotifyServer",
        "thresholdRSSI", "timeout", "lockDelay",
        "profiles", "activeProfileID",
        "hasCompletedOnboarding", "hasShownGuide", "hasCheckedAccessibility",
        "lastUpdateCheck", "manualLockNoAutoUnlock", "unlockMargin",
    ]
}
