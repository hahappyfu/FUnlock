import Foundation

struct Profile: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var lockRSSI: Int
    var unlockRSSI: Int
    var enabled: Bool

    static let `default` = Profile(id: "default", name: "默认", lockRSSI: -80, unlockRSSI: -60, enabled: true)
}

class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published var profiles: [Profile] = []
    @Published var activeProfileID: String = "default"

    private let profilesKey = "profiles"
    private let activeKey = "activeProfileID"

    init() {
        load()
    }

    var activeProfile: Profile {
        profiles.first(where: { $0.id == activeProfileID }) ?? .default
    }

    func addProfile(_ profile: Profile) {
        profiles.append(profile)
        save()
    }

    func deleteProfile(id: String) {
        guard id != "default" else { return }
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = "default" }
        save()
    }

    func updateProfile(_ profile: Profile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
            save()
        }
    }

    func setActive(_ id: String) {
        activeProfileID = id
        save()
    }

    @MainActor func applyActiveProfile(to manager: FUnManager) {
        let profile = activeProfile
        manager.setLockRSSI(profile.lockRSSI)
        manager.setUnlockRSSI(profile.unlockRSSI)
    }

    // MARK: - Save current thresholds as a new profile

    func saveCurrentAsProfile(name: String, lockRSSI: Int, unlockRSSI: Int) {
        let newProfile = Profile(
            id: UUID().uuidString,
            name: name,
            lockRSSI: lockRSSI,
            unlockRSSI: unlockRSSI,
            enabled: true
        )
        addProfile(newProfile)
    }

    // MARK: - 导入导出

    /// 导出全部用户配置为 JSON 字符串（prettyPrinted）；编码失败返回 nil。
    /// 内置 default 配置不导出（导入端对 default 有跳过保护，导出端对称排除）
    func exportJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(profiles.filter { $0.id != "default" }) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 解析 JSON 并合并进现有配置：
    /// 同 id 覆盖（updated）；id == "default" 跳过保护（skipped）；新 id 追加（added）。
    /// 解析失败返回 nil；成功则持久化并返回统计。
    func importFrom(json: String) -> (added: Int, updated: Int, skipped: Int)? {
        guard let data = json.data(using: .utf8),
              let incoming = try? JSONDecoder().decode([Profile].self, from: data) else {
            return nil
        }
        var added = 0, updated = 0, skipped = 0
        for p in incoming {
            if p.id == "default" {
                skipped += 1
                continue
            }
            if let idx = profiles.firstIndex(where: { $0.id == p.id }) {
                profiles[idx] = p
                updated += 1
            } else {
                profiles.append(p)
                added += 1
            }
        }
        save()
        return (added, updated, skipped)
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
        UserDefaults.standard.set(activeProfileID, forKey: activeKey)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = decoded
        }
        // Ensure default profile exists
        if !profiles.contains(where: { $0.id == "default" }) {
            profiles.insert(.default, at: 0)
        }
        activeProfileID = UserDefaults.standard.string(forKey: activeKey) ?? "default"
    }
}
