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
