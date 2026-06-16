import Cocoa
import UserNotifications

private let KEY = "lastUpdateCheck"
private let INTERVAL = 24.0 * 60 * 60
private var notified = false
private var checking = false
private var lastCheckAt = UserDefaults.standard.double(forKey: KEY)

func checkUpdate() {
    guard !notified else { return }
    guard !checking else { return }
    let now = NSDate().timeIntervalSince1970
    guard now - lastCheckAt >= INTERVAL else { return }
    doCheckUpdate()
}

private func doCheckUpdate() {
    checking = true
    var request = URLRequest(url: URL(string: "https://api.github.com/repos/ts1/BLEUnlock/releases/latest")!)
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let task = URLSession.shared.dataTask(with: request, completionHandler: { data, response, error in
        defer { checking = false }
        if let jsondata = data {
            if let json = try? JSONSerialization.jsonObject(with: jsondata) {
                if let dict = json as? [String:Any] {
                    if let version = dict["tag_name"] as? String {
                        lastCheckAt = NSDate().timeIntervalSince1970
                        UserDefaults.standard.set(lastCheckAt, forKey: KEY)
                        compareVersionsAndNotify(version)
                    }
                }
            }
        }
    })
    task.resume()
}

private func compareVersionsAndNotify(_ latestVersion: String) {
    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
        if version != latestVersion {
            notify()
            notified = true
        }
    }
}

private func notify() {
    let content = UNMutableNotificationContent()
    content.title = "FUnlock"
    content.subtitle = t("notification_update_available")
    let req = UNNotificationRequest(identifier: "bleunlock-update", content: content, trigger: nil)
    UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
}
