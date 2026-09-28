import UserNotifications

/// 更新检查器：全部状态在主线程读写（@MainActor）；
/// 网络请求经 async URLSession API 挂起等待，不阻塞主线程。
@MainActor
class UpdateChecker {
    private let key = "lastUpdateCheck"
    private let interval: TimeInterval = 24 * 60 * 60
    private var notified = false
    private var checking = false
    private var lastCheckAt: TimeInterval
    private let defaults: UserDefaults

    /// 检测到新版本时回调，参数为版本号（不含 v 前缀）
    var onNewVersion: ((String) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        lastCheckAt = defaults.double(forKey: key)
    }

    func check() {
        guard !notified, !checking else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastCheckAt >= interval else { return }
        doCheck()
    }

    /// 忽略 24h 间隔，立即检测（用于手动触发）。
    /// completion 在主线程回调（闭包标注 @MainActor：调用方无需自行 hop 主线程）。
    func forceCheck(completion: (@MainActor (String?) -> Void)? = nil) {
        guard !checking else { return }
        doCheck(completion: completion)
    }

    private func doCheck(completion: (@MainActor (String?) -> Void)? = nil) {
        checking = true
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/hahappyfu/FUnlock/releases/latest")!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        Task { @MainActor in
            defer { self.checking = false }
            let data: Data?
            do {
                let (d, _) = try await URLSession.shared.data(for: request)
                data = d
            } catch {
                data = nil
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                completion?(nil)
                return
            }
            self.lastCheckAt = Date().timeIntervalSince1970
            self.defaults.set(self.lastCheckAt, forKey: self.key)
            let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            if self.isNewVersion(version) {
                self.notify()
                self.notified = true
                self.onNewVersion?(version)
                completion?(version)
            } else {
                completion?(nil)
            }
        }
    }

    private func isNewVersion(_ remoteVersion: String) -> Bool {
        guard let local = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return false
        }
        return Self.compareVersions(remoteVersion, local) == .orderedDescending
    }

    /// semver 比较：返回 .orderedAscending / .orderedSame / .orderedDescending（static 供单元测试）
    static func compareVersions(_ v1: String, _ v2: String) -> ComparisonResult {
        let parts1 = v1.split(separator: ".").compactMap { Int($0) }
        let parts2 = v2.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(parts1.count, parts2.count)
        for i in 0..<maxLen {
            let a = i < parts1.count ? parts1[i] : 0
            let b = i < parts2.count ? parts2[i] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        return .orderedSame
    }

    private func notify() {
        let content = UNMutableNotificationContent()
        content.title = "Funlock"
        content.subtitle = t("notification_update_available")
        let req = UNNotificationRequest(identifier: "funlock-update", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
