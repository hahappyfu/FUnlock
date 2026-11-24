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

    /// 手动检查结果：区分「有新版本 / 已是最新 / 检查失败」，供 UI 展示真实状态
    enum CheckResult: Equatable {
        case available(String)
        case upToDate
        case failed
    }

    /// 测试注入：返回远端 tag（nil 表示网络/解析失败）；为 nil 时走真实网络
    var fetchLatestTagOverride: (() async -> String?)?

    /// 并发检查期间到达的额外回调：全部挂起，完成后统一派发，不再静默丢弃
    private var pendingResults: [@MainActor (CheckResult) -> Void] = []

    /// 忽略 24h 间隔，立即检测（用于手动触发）。
    /// completion 在主线程回调（闭包标注 @MainActor：调用方无需自行 hop 主线程）。
    func forceCheck(completion: (@MainActor (String?) -> Void)? = nil) {
        forceCheckResult { result in
            switch result {
            case .available(let version): completion?(version)
            case .upToDate, .failed: completion?(nil)
            }
        }
    }

    /// 返回三态结果；检查进行中时挂入等待队列，避免并发调用被静默丢弃
    func forceCheckResult(completion: @escaping @MainActor (CheckResult) -> Void) {
        guard !checking else {
            pendingResults.append(completion)
            return
        }
        doCheck(result: completion)
    }

    private func doCheck(result completion: (@MainActor (CheckResult) -> Void)? = nil) {
        checking = true
        Task { @MainActor in
            let tag: String?
            if let override = self.fetchLatestTagOverride {
                tag = await override()
            } else {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/hahappyfu/FUnlock/releases/latest")!)
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                do {
                    let (data, _) = try await URLSession.shared.data(for: request)
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    tag = json?["tag_name"] as? String
                } catch {
                    tag = nil
                }
            }

            let result: CheckResult
            if let tag {
                self.lastCheckAt = Date().timeIntervalSince1970
                self.defaults.set(self.lastCheckAt, forKey: self.key)
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if self.isNewVersion(version) {
                    self.notify()
                    self.notified = true
                    self.onNewVersion?(version)
                    result = .available(version)
                } else {
                    result = .upToDate
                }
            } else {
                result = .failed
            }

            self.checking = false
            completion?(result)
            let pending = self.pendingResults
            self.pendingResults.removeAll()
            for waiter in pending { waiter(result) }
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
        content.title = "FUnlock"
        content.subtitle = t("notification_update_available")
        let req = UNNotificationRequest(identifier: "funlock-update", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
