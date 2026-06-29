# FUnlock Quick Fixes Batch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 FUnlock 的 7 个已知问题：版本比较 bug、更新安全漏洞、硬编码 bundleId、窗口宽度、Profile 删除 UI、解绑确认弹窗、诊断导出 bug。

**Architecture:** 每个 task 独立修改一个文件或一组相关代码，互不依赖，可独立编译验证。

**Tech Stack:** Swift / AppKit / SwiftUI / Process / codesign

---

### Task 1: 修复版本比较 — 改为 semver 感知

**Files:**
- Modify: `FUnlock/checkUpdate.swift:64-69`

**Problem:** `isNewVersion()` 用 `local != remoteVersion` 简单字符串比较，无法区分升级和降级，且不是 semver 感知。

- [ ] **Step 1: 替换 isNewVersion 方法**

将 `checkUpdate.swift` 的 `isNewVersion` 方法（line 64-69）替换为：

```swift
    private func isNewVersion(_ remoteVersion: String) -> Bool {
        guard let local = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return false
        }
        return compareVersions(remoteVersion, local) == .orderedDescending
    }

    /// semver 比较：返回 .orderedAscending / .orderedSame / .orderedDescending
    private func compareVersions(_ v1: String, _ v2: String) -> ComparisonResult {
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
```

- [ ] **Step 2: 编译验证**

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock && xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add FUnlock/checkUpdate.swift && git commit -m "fix: 版本比较改为 semver 感知，避免降级误触发"
```

---

### Task 2: 更新安装添加 codesign 校验

**Files:**
- Modify: `FUnlock/UpdateInstaller.swift:17-30`

**Problem:** 下载的 app 只检查了 CFBundleIdentifier，没有验证代码签名。MITM 攻击可注入恶意 app。

- [ ] **Step 1: 在 install 方法中添加签名校验**

在 `UpdateInstaller.swift` 的 `install(appPath:)` 方法开头（line 17 之后），添加签名校验逻辑。将整个方法替换为：

```swift
    /// 校验代码签名后，生成安装脚本并启动，然后退出 app
    static func install(appPath: URL) throws {
        // 代码签名校验：验证下载的 app 由 Apple 签名或开发者签名
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--verify", "--deep", "--strict", appPath.path]
        codesign.standardOutput = FileHandle.nullDevice
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else {
            throw InstallError.signatureInvalid
        }

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
```

- [ ] **Step 2: 添加 signatureInvalid 错误 case**

在 `InstallError` 枚举中（line 4-13）添加新 case：

```swift
    enum InstallError: LocalizedError {
        case scriptCreationFailed
        case processLaunchFailed
        case signatureInvalid

        var errorDescription: String? {
            switch self {
            case .scriptCreationFailed: return "安装脚本创建失败"
            case .processLaunchFailed: return "安装脚本启动失败"
            case .signatureInvalid: return "下载的应用签名验证失败"
            }
        }
    }
```

- [ ] **Step 3: 编译验证**

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock && xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add FUnlock/UpdateInstaller.swift && git commit -m "security: 更新安装添加 codesign 签名校验"
```

---

### Task 3: 修复 AutomationView 硬编码 bundleId

**Files:**
- Modify: `FUnlock/AutomationView.swift:10-13`

**Problem:** `eventScriptDir` 使用硬编码的旧 bundle ID `jp.sone.BLEUnlock`，自动化脚本写入错误路径。

- [ ] **Step 1: 替换硬编码路径**

将 AutomationView.swift line 10-13：

```swift
    private static let eventScriptDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("jp.sone.BLEUnlock/event")
    }()
```

替换为：

```swift
    private static let eventScriptDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "com.fuhahah.FUnlock"
        return appSupport.appendingPathComponent("\(bundleId)/event")
    }()
```

- [ ] **Step 2: 编译验证 + Commit**

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock && xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug build 2>&1 | tail -3 && git add FUnlock/AutomationView.swift && git commit -m "fix: AutomationView 修复硬编码 bundleId，使用动态值"
```

---

### Task 4: 修复 SettingsWindow 宽度限制

**Files:**
- Modify: `FUnlock/AppDelegate.swift:558-559`

**Problem:** `contentMaxSize` 宽度 320，但 MenuDashboardView 需要 440+，UI 可能被裁剪。

- [ ] **Step 1: 修改窗口尺寸约束**

将 AppDelegate.swift line 558-559：

```swift
        settingsWindow.contentMinSize = NSSize(width: 320, height: 480)
        settingsWindow.contentMaxSize = NSSize(width: 320, height: 800)
```

替换为：

```swift
        settingsWindow.contentMinSize = NSSize(width: 440, height: 480)
        settingsWindow.contentMaxSize = NSSize(width: 520, height: 800)
```

- [ ] **Step 2: 编译验证 + Commit**

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock && xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug build 2>&1 | tail -3 && git add FUnlock/AppDelegate.swift && git commit -m "fix: SettingsWindow 宽度从 320 调整到 440-520"
```

---

### Task 5: ProfileManager 添加删除功能

**Files:**
- Modify: `FUnlock/MenuDashboardView.swift:701-752`（configContent 视图）

**Problem:** ProfileManager 有 `deleteProfile(id:)` 方法但没有 UI 调用。用户可以新建配置但不能删除。

- [ ] **Step 1: 在 Profile Picker 旁添加删除按钮**

在 MenuDashboardView.swift 的 `configContent` 中（约 line 734，`plus.circle` 按钮之后），添加删除按钮。将 line 726-735 替换为：

```swift
                Button(action: {
                    newProfileName = ""
                    showAddProfile = true
                }) {
                    Image(systemName: "plus.circle")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)

                // 删除当前非默认配置
                if profileManager.activeProfileID != "default" {
                    Button(action: { showDeleteProfile = true }) {
                        Image(systemName: "minus.circle")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                }
```

- [ ] **Step 2: 添加 State 变量和确认弹窗**

在 MenuDashboardView 的 `@State` 变量区域（查找 `@State private var showAddProfile` 附近），添加：

```swift
    @State private var showDeleteProfile = false
```

在 configContent 的 `alert` 之后（约 line 749），添加删除确认弹窗：

```swift
            .alert(t("profile_delete_confirm"), isPresented: $showDeleteProfile) {
                Button(t("ok"), role: .destructive) {
                    let id = profileManager.activeProfileID
                    profileManager.activeProfileID = "default"
                    profileManager.deleteProfile(id: id)
                    profileManager.applyActiveProfile(to: manager)
                }
                Button(t("cancel"), role: .cancel) {}
            } message: {
                Text(t("profile_delete_hint"))
            }
```

- [ ] **Step 3: 添加本地化 key**

在 8 个 Localizable.strings 文件中，在 `profile_add_hint` 行之后添加：

| File | Keys to add |
|------|-------------|
| zh-Hans | `"profile_delete_confirm" = "删除配置";` `"profile_delete_hint" = "确定删除当前配置？此操作不可撤销。";` |
| Base | `"profile_delete_confirm" = "Delete Profile";` `"profile_delete_hint" = "Delete this profile? This cannot be undone.";` |
| ja | `"profile_delete_confirm" = "プロファイルを削除";` `"profile_delete_hint" = "このプロファイルを削除しますか？この操作は元に戻せません。";` |
| de | `"profile_delete_confirm" = "Profil löschen";` `"profile_delete_hint" = "Dieses Profil löschen? Dies kann nicht rückgängig gemacht werden.";` |
| sv | `"profile_delete_confirm" = "Ta bort profil";` `"profile_delete_hint" = "Ta bort denna profil? Detta kan inte ångras.";` |
| da | `"profile_delete_confirm" = "Slet profil";` `"profile_delete_hint" = "Slet denne profil? Dette kan ikke fortrydes.";` |
| nb | `"profile_delete_confirm" = "Slett profil";` `"profile_delete_hint" = "Slette denne profilen? Dette kan ikke angres.";` |
| tr | `"profile_delete_confirm" = "Profili sil";` `"profile_delete_hint" = "Bu profil silinsin mi? Bu işlem geri alınamaz.";` |

- [ ] **Step 4: 编译验证 + Commit**

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock && xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug build 2>&1 | tail -3 && git add FUnlock/MenuDashboardView.swift FUnlock/*/Localizable.strings && git commit -m "feat: ProfileManager 添加删除配置功能 + 确认弹窗"
```

---

### Task 6: 设备解绑添加确认弹窗

**Files:**
- Modify: `FUnlock/MenuDashboardView.swift:456-462`

**Problem:** 点击"解绑"直接执行，没有确认，容易误操作。

- [ ] **Step 1: 添加确认弹窗**

在 MenuDashboardView 的 `@State` 变量区域，添加：

```swift
    @State private var showUnbindConfirm = false
```

将 line 456-462：

```swift
                    Button(action: { manager.unbindDevice() }) {
                        Text(t("unbind"))
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
```

替换为：

```swift
                    Button(action: { showUnbindConfirm = true }) {
                        Text(t("unbind"))
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .alert(t("unbind_confirm_title"), isPresented: $showUnbindConfirm) {
                        Button(t("ok"), role: .destructive) { manager.unbindDevice() }
                        Button(t("cancel"), role: .cancel) {}
                    } message: {
                        Text(t("unbind_confirm_message"))
                    }
```

- [ ] **Step 2: 添加本地化 key**

在 8 个 Localizable.strings 文件中，在 `unbind` key 行之后添加：

| File | Keys |
|------|------|
| zh-Hans | `"unbind_confirm_title" = "解绑设备";` `"unbind_confirm_message" = "确定解绑当前设备？解绑后自动锁定/解锁功能将停用。";` |
| Base | `"unbind_confirm_title" = "Unbind Device";` `"unbind_confirm_message" = "Unbind this device? Auto lock/unlock will be disabled.";` |
| ja | `"unbind_confirm_title" = "デバイスのバインド解除";` `"unbind_confirm_message" = "このデバイスのバインドを解除しますか？自動ロック/解除が無効になります。";` |
| de | `"unbind_confirm_title" = "Gerät trennen";` `"unbind_confirm_message" = "Dieses Gerät trennen? Auto-Sperren/Entsperren wird deaktiviert.";` |
| sv | `"unbind_confirm_title" = "Avbind enhet";` `"unbind_confirm_message" = "Avbinda denna enhet? Auto-lås/upplås kommer att inaktiveras.";` |
| da | `"unbind_confirm_title" = "Afbind enhed";` `"unbind_confirm_message" = "Afbind denne enhed? Auto-lås/lås op deaktiveres.";` |
| nb | `"unbind_confirm_title" = "Koble fra enhet";` `"unbind_confirm_message" = "Koble fra denne enheten? Automatisk låsing/oppheving deaktiveres.";` |
| tr | `"unbind_confirm_title" = "Cihazı ayır";` `"unbind_confirm_message" = "Bu cihaz ayrılsın mı? Otomatik kilitleme/kilid açma devre dışı bırakılacak.";` |

- [ ] **Step 3: 编译验证 + Commit**

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock && xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug build 2>&1 | tail -3 && git add FUnlock/MenuDashboardView.swift FUnlock/*/Localizable.strings && git commit -m "feat: 设备解绑添加确认弹窗防误操作"
```

---

### Task 7: 修复 ExportDiagnostics modelSize bug

**Files:**
- Modify: `FUnlock/MenuDashboardView.swift:883-891`

**Problem:** `var modelSize = ""` 后直接传给 `sysctlbyname` 的 `&modelSize`，传入空 String 的指针，sysctl 写入的数据无处可去或产生垃圾数据。

- [ ] **Step 1: 替换 sysctlbyname 调用**

将 line 883-891：

```swift
        var modelSize = ""
        var size = 0
        var sizeLen = MemoryLayout.size(ofValue: size)
        sysctlbyname("hw.model", &modelSize, &sizeLen, nil, 0)
        let sysInfo = """
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Model: \(modelSize)
        FUnlock: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))
        """
```

替换为：

```swift
        var modelName = "Unknown"
        var size = 128
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: size)
        defer { buffer.deallocate() }
        if sysctlbyname("hw.model", buffer, &size, nil, 0) == 0 {
            modelName = String(cString: buffer)
        }
        let sysInfo = """
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Model: \(modelName)
        FUnlock: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))
        """
```

- [ ] **Step 2: 编译验证 + Commit**

```bash
cd /Users/fupingguo/fuhaha_workspace/FUnlock && xcodebuild -project FUnlock.xcodeproj -scheme FUnlock -configuration Debug build 2>&1 | tail -3 && git add FUnlock/MenuDashboardView.swift && git commit -m "fix: 修复 ExportDiagnostics sysctlbyname 缓冲区错误"
```
