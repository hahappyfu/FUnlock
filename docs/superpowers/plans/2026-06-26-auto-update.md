# Auto Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 FUnlock 自动检测更新 + 静默安装，从 Gitee Release 下载 zip 并自动替换重启。

**Architecture:** 复用已有 `UpdateChecker`（修复版本比较 + 添加回调），新建 `UpdateDownloader`（下载+解压+校验）和 `UpdateInstaller`（shell 脚本安装），AppDelegate 添加菜单入口和状态反馈。

**Tech Stack:** Swift / AppKit / URLSession / Process / Shell Script

---

### Task 1: 修复 UpdateChecker + 添加回调和 forceCheck

**Files:**
- Modify: `FUnlock/checkUpdate.swift`

- [ ] **Step 1: 重写 checkUpdate.swift**

将整个文件替换为以下内容：

```swift
import UserNotifications

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

    /// 忽略 24h 间隔，立即检测（用于手动触发）
    func forceCheck(completion: ((String?) -> Void)? = nil) {
        guard !checking else { return }
        doCheck(completion: completion)
    }

    private func doCheck(completion: ((String?) -> Void)? = nil) {
        checking = true
        var request = URLRequest(url: URL(string: "https://gitee.com/api/v5/repos/fuhahah/bleunlock/releases/latest")!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }
            defer { self.checking = false }
            if let error = error {
                completion?(nil)
                return
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
        task.resume()
    }

    private func isNewVersion(_ remoteVersion: String) -> Bool {
        guard let local = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return false
        }
        return local != remoteVersion
    }

    private func notify() {
        let content = UNMutableNotificationContent()
        content.title = "FUnlock"
        content.subtitle = t("notification_update_available")
        let req = UNNotificationRequest(identifier: "funlock-update", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
```

- [ ] **Step 2: 确认编译通过**

Run: `cd /Users/fupingguo/fuhaha_workspace/FUnlock && xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add FUnlock/checkUpdate.swift
git commit -m "fix: 修复版本比较 bug，添加 onNewVersion 回调和 forceCheck"
```

---

### Task 2: 新建 UpdateDownloader

**Files:**
- Create: `FUnlock/UpdateDownloader.swift`
- Modify: `FUnlock.xcodeproj/project.pbxproj`（添加新文件引用）

- [ ] **Step 1: 创建 UpdateDownloader.swift**

```swift
import Foundation

class UpdateDownloader: NSObject, URLSessionDownloadDelegate {
    enum State {
        case idle
        case downloading(progress: Double)
        case completed(URL)   // 解压后的 FUnlock.app 路径
        case failed(Error)
    }

    var onStateChange: ((State) -> Void)?

    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private let tempDir = URL(fileURLWithPath: "/tmp/FUnlock-update")
    private var targetVersion: String = ""

    enum DownloadError: LocalizedError {
        case unzipFailed
        case bundleIdMismatch
        case appNotFound

        var errorDescription: String? {
            switch self {
            case .unzipFailed: return "解压失败"
            case .bundleIdMismatch: return "Bundle ID 不匹配"
            case .appNotFound: return "FUnlock.app 未找到"
            }
        }
    }

    func download(version: String) {
        cancel()
        targetVersion = version
        let url = URL(string: "https://gitee.com/fuhahah/bleunlock/releases/download/v\(version)/FUnlock.zip")!

        // 准备临时目录
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        downloadTask = session?.downloadTask(with: url)
        downloadTask?.resume()

        onStateChange?(.downloading(progress: 0))
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        session?.invalidateAndCancel()
        session = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let zipPath = tempDir.appendingPathComponent("FUnlock.zip")

        do {
            // 移动下载文件到临时目录
            try FileManager.default.moveItem(at: location, to: zipPath)

            // 解压
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", zipPath.path, "-d", tempDir.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw DownloadError.unzipFailed
            }

            // 校验 FUnlock.app 存在且 Bundle ID 正确
            let appPath = tempDir.appendingPathComponent("FUnlock.app")
            guard FileManager.default.fileExists(atPath: appPath.path) else {
                throw DownloadError.appNotFound
            }

            let plistPath = appPath.appendingPathComponent("Contents/Info.plist")
            guard let plist = NSDictionary(contentsOf: plistPath),
                  let bundleId = plist["CFBundleIdentifier"] as? String,
                  bundleId == "com.fuhahah.FUnlock" else {
                throw DownloadError.bundleIdMismatch
            }

            // 清理 zip 文件
            try? FileManager.default.removeItem(at: zipPath)

            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(.completed(appPath))
            }
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(.failed(error))
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(.downloading(progress: progress))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(.failed(error))
        }
    }
}
```

- [ ] **Step 2: 将文件添加到 Xcode 项目**

在 `FUnlock.xcodeproj/project.pbxproj` 中添加 `UpdateDownloader.swift` 的文件引用。最简单的方式是通过 Xcode GUI 拖入，或使用脚本：

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock
# 使用 ruby 脚本添加文件引用（如果 xcodeproj gem 可用）
# 否则手动在 Xcode 中添加
```

注意：如果 project.pbxproj 手动编辑困难，可以先跳过此步，在 Xcode 中手动添加文件到项目。

- [ ] **Step 3: 确认编译通过**

Run: `cd /Users/fupingguo/fuhaha_workspace/FUnlock && xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add FUnlock/UpdateDownloader.swift FUnlock.xcodeproj/project.pbxproj
git commit -m "feat: 新建 UpdateDownloader，支持 zip 下载+解压+校验"
```

---

### Task 3: 新建 UpdateInstaller

**Files:**
- Create: `FUnlock/UpdateInstaller.swift`
- Modify: `FUnlock.xcodeproj/project.pbxproj`（添加新文件引用）

- [ ] **Step 1: 创建 UpdateInstaller.swift**

```swift
import Foundation

enum UpdateInstaller {
    enum InstallError: LocalizedError {
        case scriptCreationFailed
        case processLaunchFailed

        var errorDescription: String? {
            switch self {
            case .scriptCreationFailed: return "安装脚本创建失败"
            case .processLaunchFailed: return "安装脚本启动失败"
            }
        }
    }

    /// 生成安装脚本并启动，然后退出 app
    static func install(appPath: URL) throws {
        let script = """
        #!/bin/bash
        sleep 2
        APP="/Applications/FUnlock.app"
        UPDATE="\(appPath.path)"

        if [ -d "$UPDATE" ]; then
            rm -rf "$APP"
            cp -R "$UPDATE" "$APP"
            open "$APP"
        fi
        rm -rf /tmp/FUnlock-update
        """

        let scriptPath = "/tmp/FUnlock-update/install.sh"
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.scriptCreationFailed
        }

        // 设置可执行权限
        chmod(scriptPath)

        // 启动脚本（脱离父进程）
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw InstallError.processLaunchFailed
        }

        // 退出 app
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    private static func chmod(_ path: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/chmod")
        proc.arguments = ["+x", path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }
}
```

- [ ] **Step 2: 将文件添加到 Xcode 项目**

同 Task 2，在 Xcode 中手动添加或编辑 project.pbxproj。

- [ ] **Step 3: 确认编译通过**

Run: `cd /Users/fupingguo/fuhaha_workspace/FUnlock && xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add FUnlock/UpdateInstaller.swift FUnlock.xcodeproj/project.pbxproj
git commit -m "feat: 新建 UpdateInstaller，shell 脚本安装+自动重启"
```

---

### Task 4: FUnManager 接线 + AppDelegate 菜单入口

**Files:**
- Modify: `FUnlock/FUnManager.swift:108`（添加 downloader 属性）
- Modify: `FUnlock/FUnManager.swift:724-726`（扩展 checkUpdate 逻辑）
- Modify: `FUnlock/AppDelegate.swift:275-277`（添加 changePassword 之后的菜单方法）
- Modify: `FUnlock/AppDelegate.swift:413`（添加菜单项）

- [ ] **Step 1: 在 FUnManager 中添加 downloader 和 install 逻辑**

在 `FUnManager.swift` line 108 `private let updateChecker = UpdateChecker()` 之后，添加：

```swift
    private let downloader = UpdateDownloader()
    private(set) var updateState: UpdateDownloader.State = .idle
```

在 `FUnManager.swift` 的 `init` 方法中（找到 `updateChecker` 初始化附近），添加 downloader 回调：

```swift
        // 接线：updateChecker → downloader → installer
        updateChecker.onNewVersion = { [weak self] version in
            self?.downloader.download(version: version)
        }
        downloader.onStateChange = { [weak self] state in
            self?.updateState = state
            if case .completed(let appPath) = state {
                try? UpdateInstaller.install(appPath: appPath)
            }
        }
```

将 `checkUpdate()` 方法（line 724-726）替换为：

```swift
    func checkUpdate() {
        updateChecker.check()
    }

    /// 手动触发检查更新，返回版本号（无更新返回 nil）
    func forceCheckUpdate(completion: ((String?) -> Void)? = nil) {
        updateChecker.forceCheck(completion: completion)
    }
```

- [ ] **Step 2: 在 AppDelegate 中添加菜单入口和 UI 反馈**

在 `AppDelegate.swift` 的 `changePassword()` 方法之后（约 line 277），添加：

```swift
    @MainActor @objc func checkForUpdates() {
        // 更新菜单项状态
        if let menuItem = statusItem.menu?.item(withTitle: t("menu_check_update")) {
            menuItem.title = t("menu_checking")
            menuItem.isEnabled = false
        }
        manager.forceCheckUpdate { [weak self] version in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let menuItem = self.statusItem.menu?.item(withTitle: t("menu_checking")) {
                    if version != nil {
                        menuItem.title = t("menu_downloading")
                    } else {
                        menuItem.title = t("menu_check_update")
                        menuItem.isEnabled = true
                        // Toast: 已是最新版本
                        self.showToast(t("already_latest"))
                    }
                }
                // 监听下载状态
                self.observeUpdateState()
            }
        }
    }

    private func observeUpdateState() {
        // 下载状态通过 downloader.onStateChange 回调已在 FUnManager 中处理
        // 这里只需更新菜单文字
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            switch self.manager.updateState {
            case .downloading(let progress):
                if let menuItem = self.statusItem.menu?.item(withTitle: t("menu_downloading")) {
                    menuItem.title = String(format: t("menu_download_progress"), Int(progress * 100))
                }
            case .completed:
                timer.invalidate()
                if let menuItem = self.statusItem.menu?.item(withTitle: t("menu_download_progress")) ?? self.statusItem.menu?.item(withTitle: t("menu_downloading")) {
                    menuItem.title = t("menu_check_update")
                    menuItem.isEnabled = true
                }
            case .failed:
                timer.invalidate()
                if let menuItem = self.statusItem.menu?.item(withTitle: t("menu_downloading")) ?? self.statusItem.menu?.item(withTitle: t("menu_download_progress")) {
                    menuItem.title = t("menu_check_update")
                    menuItem.isEnabled = true
                }
            case .idle:
                break
            }
        }
    }
```

在菜单构建代码中（line 413，`menu_change_password` 之后），添加：

```swift
        menu.addItem(NSMenuItem(title: t("menu_check_update"), action: #selector(checkForUpdates), keyEquivalent: ""))
```

- [ ] **Step 3: 确认编译通过**

Run: `cd /Users/fupingguo/fuhaha_workspace/FUnlock && xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add FUnlock/FUnManager.swift FUnlock/AppDelegate.swift
git commit -m "feat: 接线自动更新流程，菜单栏添加检查更新入口"
```

---

### Task 5: 添加本地化字符串

**Files:**
- Modify: 8 个 `Localizable.strings` 文件

- [ ] **Step 1: 在每个本地化文件的 `menu_change_password` 行之后插入以下 key**

| key | zh-Hans | Base (en) | ja | de | sv | da | nb | tr |
|-----|---------|-----------|-----|-----|-----|-----|-----|-----|
| `menu_check_update` | 检查更新 | Check for Updates | アップデートを確認 | Nach Updates suchen | Sök uppdateringar | Søg efter opdateringer | Se etter oppdateringer | Güncellemeleri kontrol et |
| `menu_checking` | 检查中... | Checking... | 確認中... | Überprüfung... | Kontrollerar... | Kontrollerer... | Sjekker... | Kontrol ediliyor... |
| `menu_downloading` | 正在下载更新... | Downloading update... | ダウンロード中... | Wird heruntergeladen... | Laddar ner... | Downloading... | Laster ned... | İndiriliyor... |
| `menu_download_progress` | 正在下载更新 (%d%%)… | Downloading update (%d%%)… | ダウンロード中 (%d%%)… | Wird heruntergeladen (%d%%)… | Laddar ner (%d%%)… | Downloading (%d%%)… | Laster ned (%d%%)… | İndiriliyor (%d%%)… |
| `already_latest` | 已是最新版本 | Already the latest version | 最新バージョンです | Bereits die neueste Version | Redan den senaste versionen | Allerede den nyeste version | Allerede den nyeste versjonen | Zaten en son sürüm |

- [ ] **Step 2: 验证所有文件格式正确**

Run: `grep -c "menu_check_update" FUnlock/*/Localizable.strings`
Expected: 每个文件 1 行，共 8 个文件

- [ ] **Step 3: Commit**

```bash
git add FUnlock/*/Localizable.strings
git commit -m "i18n: 添加自动更新功能多语言翻译"
```

---

### Task 6: 构建验证 + 端到端测试

- [ ] **Step 1: 完整编译**

Run: `cd /Users/fupingguo/fuhaha_workspace/FUnlock && xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Release build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: 打包安装测试**

```bash
pkill FUnlock; sleep 1
rm -rf /Applications/FUnlock.app
cp -R "$(xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Release -showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | awk '{print $3}')/FUnlock.app" /Applications/
touch /Applications/FUnlock.app
open /Applications/FUnlock.app
```

- [ ] **Step 3: 验证菜单项**

右键菜单栏图标，确认菜单结构：
```
打开设置
重新设置密码
检查更新
───────────────
立即锁定
解锁统计
───────────────
退出 FUnlock
```
