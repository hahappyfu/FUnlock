import Foundation
import Cocoa
import UserNotifications
import IOKit

/// 锁屏期间需要延迟展示的告警类型（按类型去重）。
enum DeferredAlertKind: Hashable {
    case noPassword
    case axRevoked
    case passwordMismatch
    case abnormalUnlock(count: Int, window: Int)
}


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

    /// 显示器是否点亮。默认读真实硬件（CGDisplayIsAsleep + IODisplayWrangler）；
    /// 测试可注入以在无物理休眠的条件下验证注入门控。
    nonisolated(unsafe) static var displayPoweredOnProvider: (() -> Bool)?

    /// 锁屏动作注入点：非 nil 时整体替代真实锁屏（SACLockScreenImmediate / 屏保启动 / 关显示器）。
    /// 测试进程必须装 no-op——否则每个门控用例都会真的锁住用户电脑
    /// （2026-11-02 实测：跑一轮全量测试触发 36 次 systemScreenLocked）。
    nonisolated(unsafe) static var lockActionOverride: (() -> Void)?

    /// 测试注入：当前会话字典（nil = 读真实 CGSessionCopyCurrentDictionary()）
    nonisolated(unsafe) static var sessionDictProvider: (() -> [String: Any]?)?
    /// 测试注入：屏保是否运行（nil = 读真实 NSRunningApplication）
    nonisolated(unsafe) static var screensaverRunningProvider: (() -> Bool)?
    /// 测试注入：前台应用 bundle id（nil = 读真实 NSWorkspace.frontmostApplication）
    nonisolated(unsafe) static var frontmostBundleIDProvider: (() -> String?)?

    /// 测试注入：替换整个密码注入前奏（避免真实 CGEvent 注入）
    nonisolated(unsafe) static var injectPasswordOverride: (@MainActor (String) async -> Bool)?
    /// 测试注入：替换双保险解锁验证
    nonisolated(unsafe) static var verifyUnlockOverride: (@MainActor (TimeInterval, TimeInterval) async -> UnlockNotification)?
    /// 测试注入：替换按键注入（保留前奏等待/门控），用于取消与安全门控测试，避免真实按键
    nonisolated(unsafe) static var fakeKeyStrokesOverride: ((String, () -> Bool) -> Bool)?

    /// 测试注入：告警展示器（nil = 真实 NSAlert）
    nonisolated(unsafe) static var alertPresenterOverride: (@MainActor (DeferredAlertKind) -> Void)?

    /// 测试注入：替换唤醒断言释放（nil = 调用 funlock_releaseWakeAssertion）
    nonisolated(unsafe) static var wakeAssertionReleaseOverride: (() -> Void)?

    /// 物理键盘活动探测（nil = 读真实 CGEventSource HID 按键时间；测试可显式注入）
    nonisolated(unsafe) static var physicalKeyActiveProvider: (() -> Bool)?

    private let syntheticKeyLock = NSLock()
    nonisolated(unsafe) private var lastSyntheticKeyAt: Date = .distantPast

    func recordSyntheticKeyEvent() {
        syntheticKeyLock.lock()
        lastSyntheticKeyAt = Date()
        syntheticKeyLock.unlock()
    }

    /// 探测用户是否正在进行物理按键输入（排除 FUnlock 自身刚投递的合成事件，防止与手动输密打架）。
    func isPhysicalKeyActive() -> Bool {
        if let provider = Self.physicalKeyActiveProvider {
            return provider()
        }
        if NSClassFromString("XCTestCase") != nil {
            return false
        }
        let elapsed = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        guard elapsed < 0.4 else { return false }
        let lastEventAt = Date().addingTimeInterval(-elapsed)
        syntheticKeyLock.lock()
        let syntheticAt = lastSyntheticKeyAt
        syntheticKeyLock.unlock()
        // 若最近一次 keyDown 落在 FUnlock 自身合成窗口内（±0.08s），视为己方事件，不误判为物理抢占
        return abs(lastEventAt.timeIntervalSince(syntheticAt)) > 0.08
    }

    // MARK: - Screen State Detection

    /// 屏幕是否处于锁定/屏保态。
    /// 只要 CGSession 有字典，就以它（+ 屏保进程）为准，不再信任可能陈旧的 screenState；
    /// 仅当系统完全拿不到会话字典时才退回 screenState。锁屏失败/漏通知不会被应用内状态掩盖。
    func isScreenLocked(screenState: ScreenState?) -> Bool {
        if let dict = currentSessionDict {
            let cgLocked = dict["CGSSessionScreenIsLocked"] as? Int == 1
            return cgLocked || isScreenSaverRunning
        }
        if isScreenSaverRunning { return true }
        if let screen = screenState { return screen != .unlocked }
        return false
    }

    /// 纯外部系统事实：CGSession 明确锁定，或屏保正在运行。
    func isSystemSessionLocked() -> Bool {
        if let dict = currentSessionDict,
           dict["CGSSessionScreenIsLocked"] as? Int == 1 {
            return true
        }
        return isScreenSaverRunning
    }

    /// 会话明确解锁：会话字典存在、CGSSession 未锁且无屏保。
    /// nil 字典表示无法判定，不视为「明确解锁」（避免误清手动锁）。
    func isExplicitlyUnlockedSession() -> Bool {
        guard let dict = currentSessionDict else { return false }
        let cgLocked = dict["CGSSessionScreenIsLocked"] as? Int == 1
        return !cgLocked && !isScreenSaverRunning
    }

    private var currentSessionDict: [String: Any]? {
        if let provider = Self.sessionDictProvider { return provider() }
        return CGSessionCopyCurrentDictionary() as? [String: Any]
    }

    /// ScreenSaver.Engine 是否正在运行（审计修复 #3）：
    /// 屏保激活时会话未锁（CGSSessionScreenIsLocked 缺失），仅凭 CGSession 判"已解锁"
    /// 会把屏保期间的注入失败误报为解锁成功（失败计数被清零、degraded 保护被绕过）
    private var isScreenSaverRunning: Bool {
        if let provider = Self.screensaverRunningProvider { return provider() }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSaver.Engine").isEmpty
    }

    /// 判断 CGSession 字典是否表示屏幕已解锁。
    /// macOS 解锁时 CGSSessionScreenIsLocked key 缺失（nil）或为 0，锁定时为 1。
    /// 因此"非锁定"（key 缺失或 0）即视为已解锁；nil 字典（无会话信息）保守判未解锁。
    static func sessionDictIndicatesUnlocked(_ dict: [String: Any]?) -> Bool {
        guard let dict else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Int ?? 0) == 0
    }

    /// Double safety check: session really locked + frontmost is a lock-screen app.
    /// - Parameter allowScreensaver: 前奏阶段允许屏保引擎；实际按键注入阶段必须传 false。
    func isSecureToInject(screenState: ScreenState?, allowScreensaver: Bool = true) -> Bool {
        guard isSystemSessionLocked() else {
            AppLog.debug(.unlock, "secureCheckFailed", [("reason", "systemSessionUnlocked")])
            return false
        }
        // 注入 provider 时必须尊重其 nil 返回值（模拟 macOS 14+ 锁屏无前台应用），
        // 不能用 `??` 穿透到宿主真实前台（测试会读到 Xcode/Terminal）。
        let frontmost: String?
        if let provider = Self.frontmostBundleIDProvider {
            frontmost = provider()
        } else {
            frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        if let frontmost {
            if frontmost == "com.apple.loginwindow" {
                AppLog.debug(.unlock, "secureCheckPassed", [("frontmost", frontmost)])
                return true
            }
            if allowScreensaver && frontmost == "com.apple.ScreenSaver.Engine" {
                AppLog.debug(.unlock, "secureCheckPassed", [("frontmost", frontmost), ("phase", "prelude")])
                return true
            }
            AppLog.error(.unlock, "secureCheckFailed", [("reason", "frontmostNotLockScreen"), ("frontmost", frontmost)])
            return false
        }
        // macOS 14+ LSUIElement 菜单栏进程在锁屏界面可能拿不到前台应用：
        // 只有 CGSession 明确锁定才放行；仅屏保运行（会话未锁）不放行。
        guard currentSessionDict?["CGSSessionScreenIsLocked"] as? Int == 1 else {
            AppLog.error(.unlock, "secureCheckFailed", [("reason", "nilFrontmostWithoutCGSessionLock")])
            return false
        }
        AppLog.debug(.unlock, "secureCheckPassed", [("frontmost", "nil"), ("cgLocked", "true")])
        return true
    }

    // MARK: - Screen Control

    /// Check if the display is powered on.
    /// 优先用 CoreGraphics 公共 API CGDisplayIsAsleep；IOKit IOEnginePower 在
    /// Apple Silicon 上不存在（日志打印 not found），仅作后备检查。
    func isDisplayPoweredOn() -> Bool {
        if let provider = Self.displayPoweredOnProvider { return provider() }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            AppLog.debug(.sm, "displayAsleep", [("method", "CGDisplayIsAsleep")])
            return false
        }

        let reg = IORegistryEntryFromPath(kIOMainPortDefault,
                                          "IOService:/IOResources/IODisplayWrangler")
        guard reg != 0 else {
            AppLog.debug(.sm, "displayPowerCheckFailed", [("reason", "noIODisplayWrangler")])
            return true  // 无法查询时默认通电，避免误唤醒
        }
        defer { IOObjectRelease(reg) }

        if let prop = IORegistryEntryCreateCFProperty(reg, "IOEnginePower" as CFString, kCFAllocatorDefault, 0) {
            let raw = prop.takeRetainedValue()
            // CFNumber 不允许 as? 条件下转（编译器视 CF 桥接为恒真），用 GetTypeID 做运行时类型校验
            guard CFGetTypeID(raw) == CFNumberGetTypeID() else {
                AppLog.debug(.sm, "displayPowerCheckFailed", [("reason", "ioEnginePowerNotCFNumber")])
                return true  // 类型不符时默认通电（与其他失败路径一致）
            }
            let powerState = unsafeDowncast(raw, to: CFNumber.self)
            var value: UInt32 = 0
            CFNumberGetValue(powerState, .sInt32Type, &value)
            AppLog.debug(.sm, "displayPowerState", [("ioEnginePower", "\(value)")])
            return value != 0
        }
        AppLog.debug(.sm, "displayPowerCheckFailed", [("reason", "ioEnginePowerNotFound")])
        return true  // 属性不存在时默认通电，避免误唤醒
    }

    /// Wake the display before password injection
    /// P1-4: 原 Thread.sleep(0.2) 在 @MainActor 注入路径同步阻塞主线程；
    /// async 化后 Task.sleep 只挂起当前任务，主线程事件循环继续处理
    @MainActor
    @discardableResult
    func wakeDisplay() async -> Bool {
        AppLog.info(.unlock, "wakeDisplayBeforeInjection")
        funlock_wakeDisplay()
        do {
            try await Task.sleep(nanoseconds: 200_000_000)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    // MARK: - Screen Control (Lock)

    /// Lock screen or start screensaver based on user preference
    func lockOrSaveScreen(useScreensaver: Bool, sleepDisplayAfter: Bool) {
        // 测试注入优先：整体跳过真实锁屏与灭屏，防止跑测试锁住用户电脑
        if let override = Self.lockActionOverride {
            override()
            return
        }
        // 纵深防御：即使某个测试忘了安装注入点，测试进程也绝不执行真实锁屏
        if NSClassFromString("XCTestCase") != nil {
            AppLog.error(.lock, "lockSuppressedUnderTest", [("action", "noOverrideInstalled")])
            return
        }
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
    /// 使用托管 `SecretUTF16Buffer` 投递密码按键（CGEvent 二级降级：`cgSessionEventTap -> cghidEventTap`）。
    /// 全程不生成 Swift `String`；每批发送前检查屏幕安全性与物理键盘抢占，检测到手打立即中止。
    func injectKeyStrokes(_ buffer: SecretUTF16Buffer, isSecureCheck: () -> Bool) -> Bool {
        guard !isPhysicalKeyActive() else {
            AppLog.info(.unlock, "keystrokeInjectionAborted", [("reason", "physicalKeyActive")])
            return false
        }
        AppLog.info(.unlock, "keystrokeInjectionStart", [("passwordLength", "\(buffer.count)")])

        AppLog.info(.unlock, "keystrokeLevelTry", [("level", "1"), ("tap", "cgSessionEventTap"), ("vk", "0")])
        if injectWithCGEvent(buffer, tap: .cgSessionEventTap, virtualKey: 0, isSecureCheck: isSecureCheck) {
            AppLog.info(.unlock, "keystrokeLevelSuccess", [("level", "1")])
            timingLog("event=keystrokeLevelSuccess level=1")
            return true
        }
        AppLog.info(.unlock, "keystrokeLevelFailed", [("level", "1"), ("next", "2")])
        timingLog("event=keystrokeLevelFailed level=1")

        guard !isPhysicalKeyActive() else {
            AppLog.info(.unlock, "keystrokeInjectionAborted", [("reason", "physicalKeyActive")])
            return false
        }
        AppLog.info(.unlock, "keystrokeLevelTry", [("level", "2"), ("tap", "cghidEventTap"), ("vk", "0")])
        let result = injectWithCGEvent(buffer, tap: .cghidEventTap, virtualKey: 0, isSecureCheck: isSecureCheck)
        if result {
            AppLog.info(.unlock, "keystrokeLevelSuccess", [("level", "2")])
            timingLog("event=keystrokeLevelSuccess level=2")
        } else {
            AppLog.error(.unlock, "keystrokeLevelFailed", [("level", "2"), ("exhausted", "true")])
            timingLog("event=keystrokeLevelFailed level=2")
        }
        AppLog.debug(.unlock, "keystrokeInjectionEnd", [("result", "\(result)")])
        return result
    }

    /// 兼容旧签名的按键注入入口（已移除 AppleScript L3 回退，仅走测试 override 或 SecretUTF16Buffer）。
    func fakeKeyStrokes(_ string: String, isSecureCheck: () -> Bool) -> Bool {
        guard !isPhysicalKeyActive() else {
            AppLog.info(.unlock, "keystrokeInjectionAborted", [("reason", "physicalKeyActive")])
            return false
        }
        if let override = Self.fakeKeyStrokesOverride {
            return override(string, isSecureCheck)
        }
        var data = Data(string.utf8)
        guard let buffer = SecretUTF16Buffer(utf8Data: &data) else { return false }
        defer { buffer.wipe() }
        return injectKeyStrokes(buffer, isSecureCheck: isSecureCheck)
    }

    /// Inject password using CGEvent with specified tap type and virtual key.
    /// Returns true if at least one event posted without preemption.
    private func injectWithCGEvent(_ buffer: SecretUTF16Buffer, tap: CGEventTapLocation, virtualKey: CGKeyCode, isSecureCheck: () -> Bool) -> Bool {
        let src = CGEventSource(stateID: .hidSystemState)
        var anyEventPosted = false

        let batchesCompleted = buffer.forEachCGEventBatch(maxUnits: 20) { ptr, len in
            guard isSecureCheck() else {
                AppLog.error(.unlock, "keystrokeInjectionAborted", [("reason", "screenNotSecureDuringInjection")])
                return false
            }
            guard !isPhysicalKeyActive() else {
                AppLog.info(.unlock, "keystrokeInjectionAborted", [("reason", "physicalKeyActiveDuringBatch")])
                return false
            }
            let pressEvent = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true)
            pressEvent?.keyboardSetUnicodeString(stringLength: len, unicodeString: ptr)
            recordSyntheticKeyEvent()
            pressEvent?.post(tap: tap)
            CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false)?.post(tap: tap)
            if pressEvent != nil { anyEventPosted = true }
            return true
        }
        guard batchesCompleted else { return false }

        guard isSecureCheck(), !isPhysicalKeyActive() else {
            AppLog.error(.unlock, "keystrokeInjectionAborted", [("reason", "screenNotSecureOrKeyActiveBeforeReturn")])
            return false
        }
        let returnDown = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)
        let returnUp = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)
        recordSyntheticKeyEvent()
        returnDown?.post(tap: tap)
        returnUp?.post(tap: tap)
        if returnDown != nil { anyEventPosted = true }
        return anyEventPosted
    }

    // MARK: - Injection Prelude

    /// Send a single Shift key press-release via CGEvent.
    /// Used as a prelude before password injection to activate the login window text field.
    /// isSecureCheck is called before each event batch to verify screen is still locked.
    public func sendShiftKey(isSecureCheck: @escaping () -> Bool) -> Bool {
        AppLog.debug(.unlock, "sendShiftKeyStart")

        let src = CGEventSource(stateID: .hidSystemState)

        // 优先确保向 cghidEventTap 投递 HID 级按键以唤醒显示器硬件，同时向 cgSession 投递以激活登录窗口文本框
        for tap in [CGEventTapLocation.cghidEventTap, CGEventTapLocation.cgSessionEventTap] {
            guard isSecureCheck() else {
                AppLog.error(.unlock, "sendShiftKeyAborted", [("reason", "screenNotSecure")])
                return false
            }
            let shiftDown = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: true)
            let shiftUp = CGEvent(keyboardEventSource: src, virtualKey: 56, keyDown: false)
            recordSyntheticKeyEvent()
            shiftDown?.post(tap: tap)
            shiftUp?.post(tap: tap)
            if shiftDown != nil {
                AppLog.info(.unlock, "sendShiftKeySuccess", [("tap", tap == .cgSessionEventTap ? "cgSession" : "cghid")])
                return true
            }
        }

        AppLog.error(.unlock, "sendShiftKeyFailed", [("reason", "allTapsExhausted")])
        return false
    }

    /// Send a Shift key prelude, wait for the display/loginwindow to become ready, then inject password.
    /// The Shift key activates the login window text field before password injection.
    /// Returns true if at least one password event was posted.
    /// P1-4: 原 Thread.sleep(0.3) 与 fakeKeyStrokes 内 wakeDisplay 的 Thread.sleep(0.2)
    /// 在 @MainActor 注入路径同步冻结主线程共约 0.5s。本方法 async 化（@MainActor）：
    /// 等待改 Task.sleep 挂起不占线程，display-off 唤醒统一移至方法开头。
    /// P1-3: 显示器熄灭唤醒后 loginwindow 就绪需 500ms~1500ms，固定 300ms 会导致
    /// 首次注入丢失；改为自适应轮询——熄屏唤醒最多等 2.5s，亮屏 300ms 不变。
    /// 托管 SecretUTF16Buffer 版本的注入前奏：无论提前返回、取消还是完成，退出前必调 `buffer.wipe()`。
    @MainActor
    func injectPasswordBufferWithPrelude(
        _ buffer: SecretUTF16Buffer,
        isSecureCheck: @escaping () -> Bool,
        keystrokeSecureCheck: (() -> Bool)? = nil
    ) async -> Bool {
        defer { buffer.wipe() }
        let ok = await runPreludeAndWait(lengthHint: buffer.count, isSecureCheck: isSecureCheck)
        guard ok else { return false }
        AppLog.info(.unlock, "injectPasswordStart")
        let result = injectKeyStrokes(buffer, isSecureCheck: keystrokeSecureCheck ?? isSecureCheck)
        AppLog.info(.unlock, "injectPasswordWithPreludeEnd", [("result", "\(result)")])
        return result
    }

    @MainActor
    public func injectPasswordWithPrelude(_ string: String, isSecureCheck: @escaping () -> Bool) async -> Bool {
        await injectPasswordWithPrelude(string, isSecureCheck: isSecureCheck, keystrokeSecureCheck: nil)
    }

    /// 带按键阶段独立安全校验的注入前奏。
    /// Shift 前奏与等待阶段允许屏保引擎（`allowScreensaver: true`），
    /// 真正投递密码前必须使用更严格的按键阶段校验（`allowScreensaver: false`）。
    @MainActor
    public func injectPasswordWithPrelude(_ string: String, isSecureCheck: @escaping () -> Bool,
                                          keystrokeSecureCheck: (() -> Bool)?) async -> Bool {
        let ok = await runPreludeAndWait(lengthHint: string.count, isSecureCheck: isSecureCheck)
        guard ok else { return false }
        AppLog.info(.unlock, "injectPasswordStart")
        let result = fakeKeyStrokes(string, isSecureCheck: keystrokeSecureCheck ?? isSecureCheck)
        AppLog.info(.unlock, "injectPasswordWithPreludeEnd", [("result", "\(result)")])
        return result
    }

    @MainActor
    private func runPreludeAndWait(lengthHint: Int, isSecureCheck: @escaping () -> Bool) async -> Bool {
        AppLog.info(.unlock, "injectPasswordWithPreludeStart", [("passwordLength", "\(lengthHint)")])

        guard !Task.isCancelled, !isPhysicalKeyActive() else { return false }

        let displayWasOff = !isDisplayPoweredOn()
        let screensaverWasRunning = isScreenSaverRunning
        // 前奏自行唤醒显示器时创建了 IOPMAssertion，退出时必须释放，
        // 否则 Mac 会被持续阻止自动熄屏。
        defer {
            if displayWasOff {
                if let release = Self.wakeAssertionReleaseOverride {
                    release()
                } else {
                    funlock_releaseWakeAssertion()
                }
            }
        }
        if displayWasOff {
            AppLog.info(.unlock, "injectPreludeWakingDisplay")
            guard await wakeDisplay() else { return false }
        }
        guard !Task.isCancelled, !isPhysicalKeyActive() else { return false }

        let shiftSent = sendShiftKey(isSecureCheck: isSecureCheck)
        var waitedMs = 0
        if shiftSent {
            // 熄屏唤醒最多轮询 2.5s；屏保激活时预留 800ms 等待屏保淡出/密码框聚焦
            //（若屏保进程提前退出，则退出后再静置 200ms 保障 loginwindow 接管焦点）；
            // 普通亮屏锁屏保持 300ms 不变。
            let maxWaitMs = displayWasOff ? 2500 : (screensaverWasRunning ? 800 : 300)
            let minWaitMs = screensaverWasRunning ? 800 : 300
            AppLog.info(.unlock, "injectPreludeWaitingDisplayReady", [
                ("maxWaitMs", "\(maxWaitMs)"),
                ("screensaver", "\(screensaverWasRunning)")
            ])
            let stepMs = 100
            var screensaverClearedAtMs: Int? = nil
            while waitedMs < maxWaitMs {
                guard !Task.isCancelled else {
                    AppLog.error(.unlock, "injectPreludeAborted", [("reason", "cancelled")])
                    return false
                }
                do {
                    try await Task.sleep(nanoseconds: UInt64(stepMs) * 1_000_000)
                } catch {
                    // 取消不得坍缩为 0ms 盲打：立即中止前奏
                    AppLog.error(.unlock, "injectPreludeAborted", [("reason", "cancelled")])
                    return false
                }
                waitedMs += stepMs
                // 轮询期间若屏幕已不再处于安全锁定状态或用户正手打键盘，立即中止
                guard isSecureCheck() else {
                    AppLog.error(.unlock, "injectPreludeAborted", [("reason", "screenNotSecure")])
                    return false
                }
                guard !isPhysicalKeyActive() else {
                    AppLog.info(.unlock, "injectPreludeAborted", [("reason", "physicalKeyActive")])
                    return false
                }
                if screensaverWasRunning && screensaverClearedAtMs == nil && !isScreenSaverRunning {
                    screensaverClearedAtMs = waitedMs
                }
                let screensaverReady: Bool
                if !screensaverWasRunning {
                    screensaverReady = true
                } else if let clearedAt = screensaverClearedAtMs {
                    // 经典屏保已退出：退出后再等待 200ms 供 loginwindow 密码框完成聚焦
                    screensaverReady = (waitedMs - clearedAt) >= 200 && waitedMs >= 300
                } else {
                    // 现代 macOS 锁屏壁纸屏保在解锁前保持运行，等待 minWaitMs（800ms）供密码框淡入聚焦
                    screensaverReady = waitedMs >= minWaitMs
                }
                // 基础等待保障 loginwindow 响应 Shift 聚焦；显示器点亮且屏保过渡就绪即可注入
                if waitedMs >= 300 && isDisplayPoweredOn() && screensaverReady {
                    break
                }
            }
            AppLog.info(.unlock, "injectPreludeDisplayReady", [
                ("waitedMs", "\(waitedMs)"),
                ("screensaverWasRunning", "\(screensaverWasRunning)"),
                ("screensaverStillRunning", "\(isScreenSaverRunning)")
            ])
        } else {
            AppLog.error(.unlock, "injectPreludeShiftFailed", [("action", "proceedingWithoutDelay")])
        }

        // 关键门控：显示器若仍处于休眠未点亮状态或用户已开始手动键入，绝不盲打注入密码
        guard !Task.isCancelled, !isPhysicalKeyActive() else { return false }
        guard isDisplayPoweredOn() else {
            AppLog.error(.unlock, "injectPreludeDisplayStillAsleep", [("waitedMs", "\(waitedMs)"), ("action", "abortInjection")])
            return false
        }
        return true
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
        content.title = "FUnlock"
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
                    AppLog.debug(.sm, "screenUnlocked", [("source", "CGSession")])
                    return true
                }
            } else {
                // CGSession 为 nil 表示无会话信息，不视为解锁，继续轮询
                AppLog.debug(.sm, "screenCheckWaiting", [("reason", "sessionDictNil")])
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
        AppLog.debug(.sm, "screenCheckTimeout", [("timeout", "\(timeout)s")])
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
                    AppLog.debug(.sm, "screenUnlocked", [("source", "CGSessionPolling")])
                    return true
                }
            } else {
                // CGSession 为 nil 表示无会话信息，不视为解锁，继续轮询
                AppLog.debug(.sm, "screenCheckWaiting", [("reason", "sessionDictNil")])
            }
            do {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            } catch {
                // 审计修复 #7：CancellationError 立即返回，不再吞掉后继续轮询
                return false
            }
        }
        AppLog.debug(.sm, "screenCheckTimeout", [("timeout", "\(timeout)s")])
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

    /// 锁屏期间待展示告警（按类型去重，避免锁屏中 runModal 阻塞主线程）
    @MainActor private(set) var pendingAlerts: [DeferredAlertKind] = []
    @MainActor var pendingAlertsCount: Int { pendingAlerts.count }

    /// 锁屏时入队并投递非阻塞本地通知；已解锁时立即展示。
    @MainActor
    func enqueueOrPresentAlert(_ kind: DeferredAlertKind) {
        if isSystemSessionLocked() {
            if !pendingAlerts.contains(kind) {
                pendingAlerts.append(kind)
            }
            postDeferredAlertNotification(kind)
            return
        }
        presentAlert(kind)
    }

    /// 解锁后统一展示积压告警（由 FUnManager.onUnlock 调用）。
    @MainActor
    func flushPendingAlerts() {
        let alerts = pendingAlerts
        pendingAlerts.removeAll()
        for kind in alerts {
            presentAlert(kind)
        }
    }

    @MainActor
    func clearPendingAlertsForTesting() {
        pendingAlerts.removeAll()
    }

    @MainActor
    private func presentAlert(_ kind: DeferredAlertKind) {
        if let presenter = Self.alertPresenterOverride {
            presenter(kind)
            return
        }
        switch kind {
        case .noPassword:
            UIHelper.errorModal(t("password_not_set"))
        case .axRevoked:
            let alert = NSAlert()
            alert.messageText = t("ax_revoked_title")
            alert.informativeText = t("ax_revoked_info")
            alert.alertStyle = .warning
            alert.addButton(withTitle: t("open_settings"))
            alert.addButton(withTitle: t("ok"))
            alert.window.title = "FUnlock"
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                openAccessibilitySettings()
            }
        case .passwordMismatch:
            let alert = NSAlert()
            alert.messageText = t("password_mismatch_title")
            alert.informativeText = t("password_mismatch_info")
            alert.alertStyle = .warning
            alert.addButton(withTitle: t("re_enter_password"))
            alert.addButton(withTitle: t("cancel"))
            alert.window.title = "FUnlock"
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                SecurityService.shared.askPassword()
            }
        case .abnormalUnlock(let count, let window):
            AppLog.info(.app, "abnormalUnlockAlert", [("count", "\(count)"), ("window", "\(window)s")])
            let alert = NSAlert()
            alert.messageText = t("abnormal_unlock_title")
            alert.informativeText = t("abnormal_unlock_info")
            alert.alertStyle = .critical
            alert.addButton(withTitle: t("ok"))
            alert.window.title = "FUnlock"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @MainActor
    private func postDeferredAlertNotification(_ kind: DeferredAlertKind) {
        let content = UNMutableNotificationContent()
        content.title = "FUnlock"
        content.body = deferredAlertTitle(kind)
        content.sound = .default
        let request = UNNotificationRequest(identifier: deferredAlertIdentifier(kind),
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func deferredAlertTitle(_ kind: DeferredAlertKind) -> String {
        switch kind {
        case .noPassword: return t("password_not_set")
        case .axRevoked: return t("ax_revoked_title")
        case .passwordMismatch: return t("password_mismatch_title")
        case .abnormalUnlock: return t("abnormal_unlock_title")
        }
    }

    private func deferredAlertIdentifier(_ kind: DeferredAlertKind) -> String {
        switch kind {
        case .noPassword: return "funlock-deferred-no-password"
        case .axRevoked: return "funlock-deferred-ax-revoked"
        case .passwordMismatch: return "funlock-deferred-password-mismatch"
        case .abnormalUnlock(let count, let window):
            return "funlock-deferred-abnormal-\(count)-\(window)"
        }
    }

    /// Show AX permission revoked alert (throttled to once per hour)
    @MainActor
    func showAXRevokedAlertIfNeeded(lastAlertTime: inout Date) {
        let now = Date().timeIntervalSince1970
        if now - lastAlertTime.timeIntervalSince1970 < 3600 {
            return
        }
        lastAlertTime = Date()
        enqueueOrPresentAlert(.axRevoked)
    }

    /// 打开系统「辅助功能」权限设置页
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 弹出密码不匹配告警（主线程 UI；锁屏时延迟到解锁后）
    @MainActor
    func showPasswordMismatchAlert() {
        enqueueOrPresentAlert(.passwordMismatch)
    }

    /// 弹出异常解锁告警（主线程 UI；锁屏时延迟到解锁后）
    @MainActor
    func showAbnormalUnlockAlert(count: Int, window: Int) {
        enqueueOrPresentAlert(.abnormalUnlock(count: count, window: window))
    }
}