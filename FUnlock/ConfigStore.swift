// FUnlock/ConfigStore.swift
import Foundation

/// 配置存储：独立 suite 域，与 bundle id 解耦。
/// 覆盖安装 app 后配置不丢失（偏好域不随 bundle 替换而重建）。
/// 所有配置读写走这里，不再直接使用 UserDefaults.standard。
final class ConfigStore {
    static let shared = ConfigStore()

    /// 固定 suite 域名（不随 bundle id 变）
    static let suiteName = "com.fuhahah.Funlock.config"
    private static let didMigrateKey = "didMigrate"

    let defaults: UserDefaults

    /// 测试注入：允许指定 suite 名隔离
    init(suiteName: String = ConfigStore.suiteName) {
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
    func bool(forKey key: String) -> Bool { defaults.bool(forKey: key) }
    func string(forKey key: String) -> String? { defaults.string(forKey: key) }

    // MARK: - 全量设置导出/导入

    /// 可导出的业务 key（legacyKeys + 后续新增 key；不含 didMigrate 等内部标记）
    static let exportableKeys = legacyKeys + [
        "permissionOnboarded",
    ]

    private static let exportedKeysKey = "_exportedKeys"
    private static let dataPrefix = "_b64:"

    /// 导出全部业务设置为 JSON：值统一转字符串，Data 走 base64 前缀编码；
    /// 附带 _exportedKeys 清单，导入时按清单删除旧 key（支持多设备配置完全替换）。
    func exportAllSettings() -> String? {
        var dict: [String: String] = [:]
        for key in ConfigStore.exportableKeys {
            guard let value = defaults.object(forKey: key) else { continue }
            if let data = value as? Data {
                dict[key] = ConfigStore.dataPrefix + data.base64EncodedString()
            } else {
                dict[key] = "\(value)"
            }
        }
        dict[ConfigStore.exportedKeysKey] = ConfigStore.exportableKeys.joined(separator: ",")
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
        for key in keysToRemove where key != ConfigStore.exportedKeysKey {
            if defaults.object(forKey: key) != nil {
                defaults.removeObject(forKey: key)
                removed += 1
            }
        }

        var applied = 0
        for (key, raw) in dict where key != ConfigStore.exportedKeysKey {
            guard knownKeys.contains(key) else { continue }
            let value = ConfigStore.decodeSettingValue(raw)
            defaults.set(value, forKey: key)
            applied += 1
        }
        return SettingsImportStats(applied: applied, removed: removed)
    }

    /// 字符串 → 原类型还原：base64 Data / Int / Bool / String
    private static func decodeSettingValue(_ raw: String) -> Any {
        if raw.hasPrefix(dataPrefix),
           let d = Data(base64Encoded: String(raw.dropFirst(dataPrefix.count))) {
            return d
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
        "thresholdRSSI", "timeout", "lockDelay",
        "profiles", "activeProfileID",
        "hasCompletedOnboarding", "hasShownGuide", "hasCheckedAccessibility",
        "lastUpdateCheck", "manualLockNoAutoUnlock", "unlockMargin",
    ]
}
