import Foundation
import Cocoa
import UserNotifications
import IOKit


/// 跨线程唤醒标志：由 NSLock 保护，供通知回调（任意线程）与轮询循环共享
private final class WakeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var detected = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return detected
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        detected = true
    }
}


/// Encapsulates all OS-level side effects: screen control, keyboard injection, media, notifications
final class SystemInteractionService: Sendable {
    static let shared = SystemInteractionService()
    private init() {}

    /// 同时写 ~/Library/Logs/FUnlock/debug.log（logDebug）与 os.log（Log.sm.debug）
    private func logBoth(_ component: String, _ osMsg: String, fileMsg: String? = nil) {
        let fm = fileMsg ?? osMsg.replacingOccurrences(of: "PASSWORD: ", with: "")
        logDebug(component: component, fm)
        Log.sm.debug("\(osMsg)")
    }

    // MARK: - Screen State Detection

    /// Check if screen is locked (CGSession + screensaver + state fallback)
    func isScreenLocked(screenState: ScreenState?) -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if dict["CGSSessionScreenIsLocked"] as? Int == 1 { return true }
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSaver.Engine").count > 0 {
            return true
        }
        if let screen = screenState { return screen != .unlocked }
        return false
    }

    /// ScreenSaver.Engine 是否正在运行（审计修复 #3）：
    /// 屏保激活时会话未锁（CGSSessionScreenIsLocked 缺失），仅凭 CGSession 判"已解锁"
    /// 会把屏保期间的注入失败误报为解锁成功（失败计数被清零、degraded 保护被绕过）
    private var isScreenSaverRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSaver.Engine").isEmpty
    }

    /// 判断 CGSession 字典是否表示屏幕已解锁。
    /// macOS 解锁时 CGSSessionScreenIsLocked key 缺失（nil）或为 0，锁定时为 1。
    /// 因此"非锁定"（key 缺失或 0）即视为已解锁；nil 字典（无会话信息）保守判未解锁。
    static func sessionDictIndicatesUnlocked(_ dict: [String: Any]?) -> Bool {
        guard let dict else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Int ?? 0) == 0
    }

    /// Double safety check: screen locked + frontmost app is loginwindow
    func isSecureToInject(screenState: ScreenState?) -> Bool {
        let locked = isScreenLocked(screenState: screenState)
        guard locked else {
            logDebug(component: "SystemInteraction", "isSecureToInject: NOT locked")
            return false
        }
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier != "com.apple.loginwindow" {
            logBoth("SystemInteraction", "ABORT: frontmost=\(frontApp.bundleIdentifier ?? "nil"), not loginwindow", fileMsg: "isSecureToInject: ABORT frontmost=\(frontApp.bundleIdentifier ?? "nil")")
            return false
        }
        logDebug(component: "SystemInteraction", "isSecureToInject: OK")
        return true
    }

    // MARK: - Screen Control

    /// Check if the display is powered on via IOKit IODisplayWrangler
    func isDisplayPoweredOn() -> Bool {
        let reg = IORegistryEntryFromPath(kIOMainPortDefault,
                                          "IOService:/IOResources/IODisplayWrangler")
        guard reg != 0 else {
            logDebug(component: "SystemInteraction", "isDisplayPoweredOn: failed to get IODisplayWrangler")
            return true  // 无法查询时默认通电，避免误唤醒
        }
        defer { IOObjectRelease(reg) }

        if let prop = IORegistryEntryCreateCFProperty(reg, "IOEnginePower" as CFString, kCFAllocatorDefault, 0) {
            let raw = prop.takeRetainedValue()
            // CFNumber 不允许 as? 条件下转（编译器视 CF 桥接为恒真），用 GetTypeID 做运行时类型校验
            guard CFGetTypeID(raw) == CFNumberGetTypeID() else {
                logDebug(component: "SystemInteraction", "isDisplayPoweredOn: IOEnginePower not a CFNumber")
                return true  // 类型不符时默认通电（与其他失败路径一致）
            }
            let powerState = unsafeDowncast(raw, to: CFNumber.self)
            var value: UInt32 = 0
            CFNumberGetValue(powerState, .sInt32Type, &value)
            logDebug(component: "SystemInteraction", "isDisplayPoweredOn: IOEnginePower=\(value)")
            return value != 0
        }
        logDebug(component: "SystemInteraction", "isDisplayPoweredOn: IOEnginePower not found")
        return true  // 属性不存在时默认通电，避免误唤醒
    }

    /// Wake the display before password injection
    /// P1-4: 原 Thread.sleep(0.2) 在 @MainActor 注入路径同步阻塞主线程；
    /// async 化后 Task.sleep 只挂起当前任务，主线程事件循环继续处理
    @MainActor
    func wakeDisplay() async {
        logBoth("SystemInteraction", "PASSWORD: waking display before injection", fileMsg: "wakeDisplay: waking display")
        funlock_wakeDisplay()
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    // MARK: - Screen Control (Lock)

    /// Lock screen or start screensaver based on user preference
    func lockOrSaveScreen(useScreensaver: Bool, sleepDisplayAfter: Bool) {
        if useScreensaver {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ScreenSaver.Engine") {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: config)
            }
        } else {
            _ = SACLockScreenImmediate()
        }
        if sleepDisplayAfter {
            funlock_sleepDisplay()
        }
    }

    // MARK: - Keyboard Injection

    /// Inject password keystrokes via CGEvent. Returns true if at least one event posted.
    /// isSecureCheck is called before each batch to verify screen is still locked.
    /// 采用三级降级策略：cgSessionEventTap -> cghidEventTap -> AppleScript
    func fakeKeyStrokes(_ string: String, isSecureCheck: () -> Bool) -> Bool {
        logBoth("SystemInteraction", "PASSWORD: attempting keystroke injection", fileMsg: "fakeKeyStrokes() START")

        // P1-4: display-off 唤醒已上移至 injectPasswordWithPrelude 开头
        // （本方法为同步方法，保留唤醒等待会阻塞主线程）

        // 尝试第1级：cgSessionEventTap + virtualKey 0
        logBoth("SystemInteraction", "PASSWORD: trying Level 1 - cgSessionEventTap + virtualKey 0", fileMsg: "Level 1: cgSessionEventTap + vk0")
        if injectWithCGEvent(string, tap: .cgSessionEventTap, virtualKey: 0, isSecureCheck: isSecureCheck) {
            logBoth("SystemInteraction", "PASSWORD: Level 1 injection succeeded", fileMsg: "Level 1: SUCCESS")
            timingLog("keystrokeLevel1=SUCCESS")
            return true
        }
        logBoth("SystemInteraction", "PASSWORD: Level 1 failed, trying Level 2", fileMsg: "Level 1: FAILED, trying Level 2")
        timingLog("keystrokeLevel1=FAIL")

        // 尝试第2级：cghidEventTap + virtualKey 0
        logBoth("SystemInteraction", "PASSWORD: trying Level 2 - cghidEventTap + virtualKey 0", fileMsg: "Level 2: cghidEventTap + vk0")
        if injectWithCGEvent(string, tap: .cghidEventTap, virtualKey: 0, isSecureCheck: isSecureCheck) {
            logBoth("SystemInteraction", "PASSWORD: Level 2 injection succeeded", fileMsg: "Level 2: SUCCESS")
            timingLog("keystrokeLevel2=SUCCESS")
            return true
        }
        logBoth("SystemInteraction", "PASSWORD: Level 2 failed, trying Level 3", fileMsg: "Level 2: FAILED, trying Level 3")
        timingLog("keystrokeLevel2=FAIL")

        // 尝试第3级：AppleScript System Events（仅限 ASCII 密码）
        guard string.canBeConverted(to: .ascii) else {
            logBoth("SystemInteraction", "PASSWORD: Level 3 skipped - password contains non-ASCII characters", fileMsg: "Level 3: SKIPPED - non-ASCII password")
            return false
        }
        logBoth("SystemInteraction", "PASSWORD: trying Level 3 - AppleScript System Events", fileMsg: "Level 3: AppleScript System Events")
        let result = injectWithAppleScript(string, isSecureCheck: isSecureCheck)
        if result {
            logBoth("SystemInteraction", "PASSWORD: Level 3 injection succeeded", fileMsg: "Level 3: SUCCESS")
            timingLog("keystrokeLevel3=SUCCESS")
        } else {
            logBoth("SystemInteraction", "PASSWORD: Level 3 failed - all levels exhausted", fileMsg: "Level 3: FAILED - all levels exhausted")
            timingLog("keystrokeLevel3=FAIL")
        }
        logDebug(component: "SystemInteraction", "fakeKeyStrokes() END - result=\(result)")
        return result
    }

    /// Inject password using CGEvent with specified tap type and virtual key.
    /// Returns true if at least one event posted.
    private func injectWithCGEvent(_ string: String, tap: CGEventTapLocation, virtualKey: CGKeyCode, isSecureCheck: () -> Bool) -> Bool {
        let src = CGEventSource(stateID: .hidSystemState)
        var anyEventPosted = false
        let uniCharCount = string.utf16.count
        var strIndex = string.utf16.startIndex

        for offset in stride(from: 0, to: uniCharCount, by: 20) {
            guard isSecureCheck() else {
                Log.sm.error("PASSWORD: ABORT - screen no longer secure during keystroke injection")
                return anyEventPosted
            }
            let pressEvent = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true)
            let len = offset + 20 < uniCharCount ? 20 : uniCharCount - offset
            let buffer = UnsafeMutablePointer<UniChar>.allocate(capacity: len)
            defer { buffer.deallocate() }
            for i in 0..<len {
                buffer[i] = string.utf16[strIndex]
                strIndex = string.utf16.index(after: strIndex)
            }
            pressEvent?.keyboardSetUnicodeString(stringLength: len, unicodeString: buffer)
            pressEvent?.post(tap: tap)
            CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false)?.post(tap: tap)
            if pressEvent != nil { anyEventPosted = true }
        }

        guard isSecureCheck() else {
            Log.sm.error("PASSWORD: ABORT - screen no longer secure before Return key")
            return anyEventPosted
        }
        let returnDown = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)
        let returnUp = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)
        returnDown?.post(tap: tap)
        returnUp?.post(tap: tap)
        if returnDown != nil { anyEventPosted = true }
        return anyEventPosted
    }

    /// Inject password using AppleScript System Events (only for ASCII passwords).
    /// Returns true if injection was initiated successfully.
    /// 执行前与结束后均调用 isSecureCheck 确认屏幕仍处于锁定状态（防密码泄露给非锁定会话）
    /// 使用进程内 NSAppleScript 执行（而非外部 /usr/bin/osascript 进程），
    /// 避免密码以命令行参数形式暴露给 ps/sysctl 等进程检查工具
    private func injectWithAppleScript(_ string: String, isSecureCheck: () -> Bool) -> Bool {
        guard string.canBeConverted(to: .ascii) else {
            Log.sm.debug("PASSWORD: AppleScript rejected - non-ASCII characters")
            return false
        }

        // AppleScript 执行前再次确认屏幕仍锁定，防止密码泄露给非锁定会话
        guard isSecureCheck() else {
            logBoth("SystemInteraction", "PASSWORD: ABORT - screen no longer secure before AppleScript injection", fileMsg: "Level 3: ABORT - screen no longer secure before AppleScript")
            return false
        }

        // Escape special characters for AppleScript string.
        // 审计修复 #6：双引号字符串内单引号无需转义，旧代码产生的 `\'` 是非法转义序列，
        // 含单引号的密码在 L3 必然编译失败，故只处理反斜杠与双引号
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "System Events"
            keystroke "\(escaped)"
            delay 0.2
            key code 36
        end tell
        """

        Log.sm.debug("PASSWORD: executing AppleScript keystroke injection (in-process NSAppleScript)")
        guard let appleScript = NSAppleScript(source: script) else {
            Log.sm.debug("PASSWORD: AppleScript compilation failed")
            return false
        }
        var errorInfo: NSDictionary?
        _ = appleScript.executeAndReturnError(&errorInfo)
        // NSAppleScript 为同步执行，此处检查只能用于结果判定：
        // 若屏幕已解锁，密码可能已被输入到非锁定会话，调用方不得视为成功
        if !isSecureCheck() {
            logBoth("SystemInteraction", "PASSWORD: screen no longer locked after AppleScript, treating as failure", fileMsg: "Level 3: screen no longer locked after AppleScript - result unreliable, treated as failure")
            return false
        }
        // 注：macOS 27 SDK 下 executeAndReturnError 返回非可选 NSAppleEventDescriptor，
        // `result != nil` 在 -O 优化下会被折叠为恒真，无法据以判成败；
        // 故以 errorInfo == nil（无错误信息即成功）为准。
        if errorInfo == nil {
            Log.sm.debug("PASSWORD: AppleScript injection completed successfully")
            return true
        } else {
            let number = errorInfo?["NSAppleScriptErrorNumber"] as? Int ?? -1
            let message = errorInfo?["NSAppleScriptErrorMessage"] as? String ?? "unknown"
            Log.sm.debug("PASSWORD: AppleScript failed - error \(number): \(message)")
            return false
        }
    }

    // MARK: - Injection Prelude

    /// Send a single Shift key press-release via CGEvent.
    /// Used as a prelude before password injection to activate the login window text field.
    /// isSecureCheck is called before each event batch to verify screen is still locked.
    public func sendShiftKey(isSecureCheck: @escaping () -> Bool) -> Bool {
        logBoth("SystemInteraction", "PASSWORD: sending Shift key prelude", fileMsg: "sendShiftKey() START")

        let src = CGEventSource(stateID: .hidSystemState)

        for tap in [CGEventTapLocation.cgSessionEventTap, CGEventTapLocation.cghidEventTap] {
            guard isSecureCheck() else {
                logDebug(component: "SystemInteraction", "sendShiftKey: ABORT - screen not secure")
                return false
            }
            let shiftDown = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: true)
            let shiftUp = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: false)
            shiftDown?.post(tap: tap)
            shiftUp?.post(tap: tap)
            if shiftDown != nil {
                logBoth("SystemInteraction", "PASSWORD: Shift key sent successfully", fileMsg: "sendShiftKey: SUCCESS via tap=\(tap == .cgSessionEventTap ? "cgSession" : "cghid")")
                return true
            }
        }

        logBoth("SystemInteraction", "PASSWORD: Shift key send failed", fileMsg: "sendShiftKey: FAILED - all taps exhausted")
        return false
    }

    /// Send a Shift key prelude, wait 300ms, then inject password.
    /// The Shift key activates the login window text field before password injection.
    /// Returns true if at least one password event was posted.
    /// P1-4: 原 Thread.sleep(0.3) 与 fakeKeyStrokes 内 wakeDisplay 的 Thread.sleep(0.2)
    /// 在 @MainActor 注入路径同步冻结主线程共约 0.5s。本方法 async 化（@MainActor）：
    /// 等待改 Task.sleep 挂起不占线程，display-off 唤醒统一移至方法开头。
    @MainActor
    public func injectPasswordWithPrelude(_ string: String, isSecureCheck: @escaping () -> Bool) async -> Bool {
        logBoth("SystemInteraction", "PASSWORD: injection with prelude - Shift + 300ms delay", fileMsg: "injectPasswordWithPrelude() START")

        if !isDisplayPoweredOn() {
            logBoth("SystemInteraction", "PASSWORD: display off, waking screen", fileMsg: "injectPasswordWithPrelude: display off, waking")
            await wakeDisplay()
        }

        let shiftSent = sendShiftKey(isSecureCheck: isSecureCheck)
        if shiftSent {
            logBoth("SystemInteraction", "PASSWORD: Shift prelude sent, waiting 300ms before password", fileMsg: "injectPasswordWithPrelude: Shift sent, waiting 300ms")
            try? await Task.sleep(nanoseconds: 300_000_000)
        } else {
            logBoth("SystemInteraction", "PASSWORD: Shift prelude failed, proceeding without delay", fileMsg: "injectPasswordWithPrelude: Shift failed, proceeding without delay")
        }

        logDebug(component: "SystemInteraction", "injectPasswordWithPrelude: injecting password")
        let result = fakeKeyStrokes(string, isSecureCheck: isSecureCheck)
        logDebug(component: "SystemInteraction", "injectPasswordWithPrelude() END - result=\(result)")
        return result
    }

    // MARK: - Media Control

    /// Pause Now Playing if preference enabled. Returns whether it was playing.
    func checkAndPauseMedia(enabled: Bool, callback: @escaping (Bool) -> Void) {
        guard enabled else { callback(false); return }
        MRMediaRemoteGetNowPlayingApplicationIsPlaying(DispatchQueue.main) { playing in
            if playing {
                MRMediaRemoteSendCommand(MRCommandPause, nil)
            }
            callback(playing)
        }
    }

    /// Resume Now Playing if it was playing before
    func resumeMediaIfNeeded(wasPlaying: Bool, enabled: Bool) {
        guard enabled && wasPlaying else { return }
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            MRMediaRemoteSendCommand(MRCommandPlay, nil)
        }
    }

    // MARK: - Notifications

    /// 已投递的锁屏通知标识；仅由主线程（通知相关路径）访问
    @MainActor private var deliveredNotificationId = ""

    @MainActor
    func notifyLock(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Funlock"
        if reason == "lost" { content.subtitle = t("notification_lost_signal") }
        else if reason == "away" { content.subtitle = t("notification_device_away") }
        content.body = t("notification_locked")
        let req = UNNotificationRequest(identifier: "funlock-lock", content: content, trigger: nil)
        deliveredNotificationId = req.identifier
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    @MainActor
    func clearLockNotification() {
        if !deliveredNotificationId.isEmpty {
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: [deliveredNotificationId])
            deliveredNotificationId = ""
        }
    }

    // MARK: - 双保险验证

    /// 解锁通知结果
    struct UnlockNotification {
        let unlock: Bool
    }

    /// 等待系统解锁（快速路径）
    /// 监听 NSWorkspace.didWakeNotification（系统唤醒信号）+ 轮询 CGSession
    /// 系统唤醒时立即开始高频轮询，比纯 CGSession 轮询更快响应
    func waitForUnlockNotification(timeout: TimeInterval = 1.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        // 唤醒信号：收到后立即开始高频轮询（比固定间隔更快）
        let wakeFlag = WakeFlag()

        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            wakeFlag.set()
        }

        defer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }

        while Date() < deadline {
            // 审计修复 #7：响应任务取消，取消后立即退出而非跑满 deadline
            guard !Task.isCancelled else { return false }
            // 检查 CGSession
            if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
                // 审计修复 #3：解锁判定还需屏保未运行（屏保激活时会话未锁，不能视为已解锁）
                if Self.sessionDictIndicatesUnlocked(dict) && !isScreenSaverRunning {
                    logDebug(component: "SystemInteraction", "waitForUnlockNotification: unlocked via CGSession")
                    return true
                }
            } else {
                // CGSession 为 nil 表示无会话信息，不视为解锁，继续轮询
                logDebug(component: "SystemInteraction", "waitForUnlockNotification: CGSession nil → 继续轮询")
            }
            // 唤醒信号检测到后用更短间隔轮询（50ms），否则200ms
            let interval: UInt64 = wakeFlag.isSet ? 50_000_000 : 200_000_000
            do {
                try await Task.sleep(nanoseconds: interval)
            } catch {
                // 审计修复 #7：CancellationError 立即返回，不再吞掉后继续轮询
                return false
            }
        }
        logDebug(component: "SystemInteraction", "waitForUnlockNotification: timeout (\(timeout)s)")
        return false
    }

    /// 通过 CGSession 轮询检测屏幕是否解锁（兜底路径，最多2秒）
    /// 每100ms 检查一次 CGSessionCopyCurrentDictionary，超时返回 false
    func checkScreenUnlocked(timeout: TimeInterval = 2.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // 审计修复 #7：响应任务取消，取消后立即退出而非跑满 deadline
            guard !Task.isCancelled else { return false }
            if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
                // 审计修复 #3：解锁判定还需屏保未运行（屏保激活时会话未锁，不能视为已解锁）
                if Self.sessionDictIndicatesUnlocked(dict) && !isScreenSaverRunning {
                    logDebug(component: "SystemInteraction", "checkScreenUnlocked: screen unlocked via CGSession")
                    return true
                }
            } else {
                // CGSession 为 nil 表示无会话信息，不视为解锁，继续轮询
                logDebug(component: "SystemInteraction", "checkScreenUnlocked: CGSession nil → 继续轮询")
            }
            do {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            } catch {
                // 审计修复 #7：CancellationError 立即返回，不再吞掉后继续轮询
                return false
            }
        }
        logDebug(component: "SystemInteraction", "checkScreenUnlocked: timeout (\(timeout)s)")
        return false
    }

    /// 双保险验证：通知 + CGSession 竞速，withTaskGroup 实现
    /// 任一路径先返回 true 即为解锁成功；全部超时返回 .timeout
    @MainActor
    func verifyUnlock(
        timeout: TimeInterval = 2.0,
        notificationTimeout: TimeInterval = 1.0
    ) async -> UnlockNotification {
        await Self.verifyUnlock(
            timeout: timeout,
            notificationTimeout: notificationTimeout,
            waitForNotification: { [weak self] t in
                await self?.waitForUnlockNotification(timeout: t) ?? false
            },
            checkUnlocked: { [weak self] t in
                await self?.checkScreenUnlocked(timeout: t) ?? false
            }
        )
    }

    /// 双保险验证（可测试版本）：接受注入的通知监听和屏幕检查闭包
    /// 用于单元测试时替换系统 API 调用
    @MainActor
    static func verifyUnlock(
        timeout: TimeInterval = 2.0,
        notificationTimeout: TimeInterval = 1.0,
        waitForNotification: @escaping @Sendable (TimeInterval) async -> Bool,
        checkUnlocked: @escaping @Sendable (TimeInterval) async -> Bool
    ) async -> UnlockNotification {
        let result = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            group.addTask {
                await waitForNotification(notificationTimeout)
            }
            group.addTask {
                await checkUnlocked(timeout)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            for await success in group {
                if success {
                    group.cancelAll()
                    return true
                }
            }
            return false
        }
        return UnlockNotification(unlock: result)
    }

    // MARK: - Alert Dialogs

    /// Show AX permission revoked alert (throttled to once per hour)
    @MainActor
    func showAXRevokedAlertIfNeeded(lastAlertTime: inout Date) {
        let now = Date().timeIntervalSince1970
        if now - lastAlertTime.timeIntervalSince1970 < 3600 {
            return
        }
        lastAlertTime = Date()
        let alert = NSAlert()
        alert.messageText = t("ax_revoked_title")
        alert.informativeText = t("ax_revoked_info")
        alert.alertStyle = .warning
        alert.addButton(withTitle: t("open_settings"))
        alert.addButton(withTitle: t("ok"))
        alert.window.title = "Funlock"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    /// 打开系统「辅助功能」权限设置页
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 弹出密码不匹配告警（主线程 UI）
    @MainActor
    func showPasswordMismatchAlert() {
        let alert = NSAlert()
        alert.messageText = t("password_mismatch_title")
        alert.informativeText = t("password_mismatch_info")
        alert.alertStyle = .warning
        alert.addButton(withTitle: t("re_enter_password"))
        alert.addButton(withTitle: t("cancel"))
        alert.window.title = "Funlock"
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SecurityService.shared.askPassword()
        }
    }

    /// 弹出异常解锁告警（主线程 UI）
    @MainActor
    func showAbnormalUnlockAlert(count: Int, window: Int) {
        Log.sm.debug("abnormal unlock alert: \(count) attempts in \(window)s")
        let alert = NSAlert()
        alert.messageText = t("abnormal_unlock_title")
        alert.informativeText = t("abnormal_unlock_info")
        alert.alertStyle = .critical
        alert.addButton(withTitle: t("ok"))
        alert.window.title = "Funlock"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}