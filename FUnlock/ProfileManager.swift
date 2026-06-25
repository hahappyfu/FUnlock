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
