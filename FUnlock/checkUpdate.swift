import Cocoa
import UserNotifications

class UpdateChecker {
    private let key = "lastUpdateCheck"
    private let interval: TimeInterval = 24 * 60 * 60  // 24h
    private var notified = false
    private var checking = false
    private var lastCheckAt: TimeInterval

    init(defaults: UserDefaults = .standard) {
        lastCheckAt = defaults.double(forKey: "lastUpdateCheck")
    }

    func check() {
        guard !notified else { return }
        guard !checking else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastCheckAt >= interval else { return }
        doCheck()
    }

    private func doCheck() {
        checking = true
        var request = URLRequest(url: URL(string: "https://gitee.com/api/v5/repos/fuhahah/bleunlock/releases/latest")!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self else { return }
            defer { self.checking = false }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["tag_name"] as? String else { return }
            self.lastCheckAt = Date().timeIntervalSince1970
            UserDefaults.standard.set(self.lastCheckAt, forKey: self.key)
            self.compareVersionsAndNotify(version)
        }
        task.resume()
    }

    private func compareVersionsAndNotify(_ latestVersion: String) {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           version != latestVersion {
            notify()
            notified = true
        }
    }

    private func notify() {
        let content = UNMutableNotificationContent()
        content.title = "FUnlock"
        content.subtitle = t("notification_update_available")
        let req = UNNotificationRequest(identifier: "funlock-update", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}

private let sharedUpdater = UpdateChecker()

func checkUpdate() {
    sharedUpdater.check()
}
