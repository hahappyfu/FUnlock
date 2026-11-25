// FUnManager.swift
// 状态中枢：收编所有锁屏/解锁状态、@Observable 响应式发布与系统事件分发入口。
// 解锁流水线（门控 → 密码获取 → 注入 → 双保险验证 → 唤醒重试）已抽取为
// UnlockOrchestrator（本类持有并委托）；系统事件与 FUn 设备事件的监听入口
// 见 FUnManager+Events.swift；领域状态类型见 LockScreenState.swift。
// 使用 Observation 宏暴露状态，async/await 替代 Timer。

import Foundation
import Observation
import Cocoa

// MARK: - FUnManager

/// 全类 @MainActor 隔离：所有状态变更、`stateMachine`（@MainActor）交互与解锁注入
/// 都在主线程串行执行。解锁注入/验证路径由 `orchestrator`（@MainActor）承载，
/// 延迟/并行 `Task` 闭包显式标注 `@MainActor`，不依赖 `Task` 隐式继承 actor 上下文的实现细节。
@Observable
@MainActor
final class FUnManager {

    // MARK: Observable state

    var state = LockScreenState()
    var rssi: Int? = nil
    var connected: Bool = false
    var discoveredDevices: [DeviceSnapshot] = []
    var monitoredDeviceName: String? = nil
    var lockRSSI: Int = -80
    var unlockRSSI: Int = -60
    var thresholdVersion: Int = 0

    // MARK: Dependencies

    /// 以下依赖与簿记字段只被方法调用读写、从不参与视图渲染，统一排除在 @Observable
    /// 跟踪之外，避免 ObservationRegistrar 为它们登记无意义的访问记录。
    @ObservationIgnored let fun: FUn
    @ObservationIgnored let stateMachine: FUnlockStateMachine
    @ObservationIgnored let decisionLogger: DecisionLogger
    var inputMonitor: InputActivityMonitor?
    var isSelfLocking = false {  // 区分 FUnlock 自动锁屏 vs 用户手动锁屏
        didSet {
            // 兼容旧调用点/测试直接写 isSelfLocking：置位即开启 10s 自锁窗口
            selfLockWindowDeadline = isSelfLocking ? now.addingTimeInterval(10) : nil
        }
    }
    /// 校准模式：向导采样期间为 true，onDeviceLeft 拦截不锁
    var isCalibrating = false
    /// 自锁时间窗口：屏保/系统锁通知任意顺序到达都能在窗口内识别为 FUnlock 自锁。
    /// 仅 onUnlock / lockNow 主动清除；窗口到期自然失效。
    @ObservationIgnored var selfLockWindowDeadline: Date?
    /// 锁屏回读验证代次：新一次锁屏使旧验证失效。
    @ObservationIgnored var lockVerificationGeneration: UInt64 = 0
    @ObservationIgnored private let updateChecker = UpdateChecker(defaults: ConfigStore.shared.defaults)
    @ObservationIgnored private let downloader = UpdateDownloader()
    private(set) var updateState: UpdateDownloader.State = .idle
    @ObservationIgnored let prefs = ConfigStore.shared.defaults
    /// 后台探测任务的取消句柄，纯内部簿记状态，不参与视图渲染，
    /// 且需在非隔离的 `deinit` 中访问，故显式排除在 @Observable 跟踪之外。
    @ObservationIgnored var intrudeCheckTask: Task<Void, Never>?
    /// 系统唤醒延迟任务：二次睡眠/重复唤醒时必须可取消
    @ObservationIgnored var systemWakeTask: Task<Void, Never>?
    @ObservationIgnored var systemWakeGeneration: UInt64 = 0
    /// 安全 Wi-Fi / 冷静期拦截后的补锁复查任务
    @ObservationIgnored var deferredLockTask: Task<Void, Never>?
    @ObservationIgnored var deferredLockGeneration: UInt64 = 0
    /// 安全 Wi-Fi 补锁复查间隔（测试可注入）
    var trustedWiFiRecheckInterval: TimeInterval = 10.0
    /// 系统锁屏通知复核延迟（测试可注入）
    var screenLockVerifyDelay: TimeInterval = 0.3
    /// 解锁通知复核延迟：`com.apple.screenIsUnlocked` 常早于 CGSession 翻 0 约 100–300ms，
    /// 会话仍显示锁定时延迟复核，避免把合法解锁永久丢弃（测试可注入）
    var screenUnlockVerifyDelay: TimeInterval = 0.4
    /// 锁屏通知复核任务：会话未锁时 0.3s 后复查，onUnlock 可取消
    @ObservationIgnored var screenLockVerifyTask: Task<Void, Never>?
    @ObservationIgnored private var mediaWasPlaying = false

    // MARK: - L0 在场保活 / L1 手表原生协同 / 负向快采

    var idleSleepLatched: Bool = false
    var watchAutoUnlockObserved: Bool {
        get { ConfigStore.shared.bool(forKey: "watchAutoUnlockObserved", default: false) }
        set { ConfigStore.shared.set(newValue, forKey: "watchAutoUnlockObserved") }
    }
    @ObservationIgnored var l1TimeoutStreak: Int = 0
    @ObservationIgnored var l1WaitDurationForTesting: TimeInterval? = nil
    @ObservationIgnored var l1PollIntervalForTesting: TimeInterval? = nil
    @ObservationIgnored var selfWakeStartedAt: Date? = nil
    @ObservationIgnored let powerKeepAlive = PowerKeepAliveAdapter()
    @ObservationIgnored var l0EngineSnapshot = EngineState()
    @ObservationIgnored var idleSecondsProvider: () -> TimeInterval = { PowerKeepAliveAdapter.currentUserIdleSeconds() }
    @ObservationIgnored var negativeSignalAdapter: NegativeSignalAdapter?

    /// 解锁流水线协调器：密码获取 → 注入 → 双保险验证 → 显示器唤醒重试
    /// （在 init 末尾装配；强持有，orchestrator 以 unowned 反向引用本类）
    private(set) var orchestrator: UnlockOrchestrator!

    /// 漏收解锁通知自愈：会话已明确解锁但本地仍是陈旧锁定/手动锁态时，对齐为 unlocked。
    /// 注意：displaySleeping / screensaver 是真实电源/屏保状态，不在此处覆盖。
    func reconcileUnlockedSessionIfNeeded() {
        let isStaleLockedState: Bool
        if case .locked = state.screen { isStaleLockedState = true } else { isStaleLockedState = false }
        guard isStaleLockedState || state.intent.isManualLockActive else { return }
        guard SystemInteractionService.shared.isExplicitlyUnlockedSession() else { return }
        AppLog.info(.sm, "reconcileUnlockedSession", [("screen", "\(state.screen)")])
        state.screen = .unlocked
        state.intent = .autoLock
        clearSelfLockWindow()
    }

    // MARK: - 冷却与缓冲策略（可测试时间源）
    /// 可注入时间源：仅门控判定内部读取，不驱动视图，故排除在跟踪之外
    @ObservationIgnored var nowProvider: () -> Date = { Date() }
    var now: Date { nowProvider() }
    /// 解锁成功后的冷却时间（秒），冷却期内不重复尝试解锁（默认引用状态机单一来源，测试可注入覆盖）
    var unlockCooldownDuration: TimeInterval = FUnlockStateMachine.unlockCooldownDuration
    /// 自动锁屏后的缓冲时间（秒），缓冲期内不尝试自动解锁
    var lockBufferDuration: TimeInterval = 0.8
    /// 系统唤醒后等待蓝牙栈恢复的延迟（秒），延迟结束才置 system 为 awake；测试注入更小值消除 1s 硬等
    var systemWakeDelay: TimeInterval = 1.0
    /// 上次自动锁屏的时间（通过 onDeviceLeft 触发）
    var lastLockTime: Date = .distantPast
    /// 上次成功解锁的时间（自动或手动解锁时更新）
    var lastUnlockTime: Date = .distantPast

    // MARK: - 决策记录辅助（锁 / 系统 / 用户；解锁类记录见 UnlockOrchestrator）

    /// 手动锁定意图的有效期（秒）：一次性覆盖自动解锁判定，直到用户手动解锁重置 intent
    static let manualLockIntentDuration: TimeInterval = 86_400

    /// 标记手动锁定意图（lockNow / 屏保启动 / 系统锁屏三处的单一入口）
    func markManualLock() {
        state.intent = .manualLock(deadline: now.addingTimeInterval(FUnManager.manualLockIntentDuration))
    }

    /// 当前是否处于自锁窗口内。
    var isWithinSelfLockWindow: Bool {
        guard let deadline = selfLockWindowDeadline else { return false }
        return now <= deadline
    }

    /// 开启自锁窗口（自动锁屏路径）。duration 可注入负值用于测试过期窗口。
    func beginSelfLockWindow(duration: TimeInterval = 10) {
        isSelfLocking = true  // didSet 先置默认 10s 窗口
        selfLockWindowDeadline = now.addingTimeInterval(duration)
    }

    /// 清除自锁窗口（用户解锁 / 手动锁屏）。
    func clearSelfLockWindow() {
        selfLockWindowDeadline = nil
        isSelfLocking = false  // didSet 再次置 nil
    }

    /// 2s 锁屏回读验证：系统未锁且无屏保时回滚本地锁定态。
    /// 用代次守卫，避免旧验证在新一次锁屏后误回滚。
    func scheduleLockVerification(delayNanoseconds: UInt64 = 2_000_000_000) {
        lockVerificationGeneration &+= 1
        let generation = lockVerificationGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self, self.lockVerificationGeneration == generation else { return }
            guard !SystemInteractionService.shared.isSystemSessionLocked() else { return }
            guard self.state.screen != .unlocked else { return }
            AppLog.error(.lock, "lockVerifyFailed", [("action", "rollbackToUnlocked")])
            self.state.screen = .unlocked
            self.clearSelfLockWindow()
        }
    }

    func recordLock(_ reason: DecisionReason, detail: String = "") {
        decisionLogger.record(category: .lock, outcome: .success, reason: reason,
                              rssi: rssi, device: monitoredDeviceName,
                              screen: state.screen.description, detail: detail)
    }

    func recordSystem(_ reason: DecisionReason) {
        decisionLogger.record(category: .system, outcome: .info, reason: reason,
                              rssi: rssi, device: monitoredDeviceName,
                              screen: state.screen.description)
    }

    func recordUser(_ reason: DecisionReason) {
        decisionLogger.record(category: .user, outcome: .success, reason: reason,
                              rssi: rssi, device: monitoredDeviceName,
                              screen: state.screen.description)
    }

    /// 自动解锁成功后的统一收尾（双保险两条成功路径共用）：
    /// 清自锁窗口、对齐 screen/intent、消费锁屏期间暂存的改密与告警。
    func finalizeAutoUnlockSuccess() {
        clearSelfLockWindow()
        idleSleepLatched = false
        selfWakeStartedAt = nil
        l1TimeoutStreak = 0
        state.screen = .unlocked
        state.unlockedAt = now
        state.intent = .autoLock
        syncL0KeepAlive()
        if SecurityService.shared.hasPendingPasswordChange {
            SecurityService.shared.hasPendingPasswordChange = false
            SecurityService.shared.handlePasswordChanged()
        }
        SystemInteractionService.shared.flushPendingAlerts()
    }

    func onUserUnlockedClearLatchForTesting() {
        idleSleepLatched = false
        selfWakeStartedAt = nil
        state.screen = .unlocked
        syncL0KeepAlive()
    }

    func isKnownIPhoneDevice(_ name: String?) -> Bool {
        name?.localizedCaseInsensitiveContains("iPhone") == true
    }

    func currentEngineConfig() -> EngineConfig {
        EngineConfig(
            enabled: ConfigStore.shared.bool(forKey: "enabled", default: true),
            unlockRSSI: unlockRSSI,
            lockRSSI: lockRSSI,
            proximityTimeout: fun.proximityTimeout,
            signalTimeout: fun.signalTimeout,
            wakeAdvance: SignalHysteresisEngine.offsetSetting("wakeAdvance", default: FUn.defaultWakeAdvance),
            preUnlockTrigger: SignalHysteresisEngine.offsetSetting("preUnlockTrigger", default: FUn.defaultPreUnlockTrigger),
            wakeOnProximity: prefs.bool(forKey: "wakeOnProximity"),
            wakeWithoutUnlocking: prefs.bool(forKey: "wakeWithoutUnlocking"),
            useScreensaver: prefs.bool(forKey: "screensaver"),
            sleepDisplay: prefs.bool(forKey: "sleepDisplay"),
            pauseMedia: prefs.bool(forKey: "pauseItunes"),
            lockOnIdle: ConfigStore.shared.bool(forKey: "lockOnIdle", default: true),
            keepAliveWhilePresent: ConfigStore.shared.bool(forKey: "keepAliveWhilePresent", default: true),
            preferNativeWatchUnlock: ConfigStore.shared.bool(forKey: "preferNativeWatchUnlock", default: true),
            pauseOnWiFi: prefs.bool(forKey: "pauseOnWiFi"),
            pauseOnWiFiSSID: prefs.string(forKey: "pauseOnWiFiSSID") ?? "",
            passiveMode: prefs.bool(forKey: "passiveMode"),
            isKnownIPhone: isKnownIPhoneDevice(monitoredDeviceName)
        )
    }

    func syncL0KeepAlive(forceRenew: Bool = false) {
        let snap = fun.signalSnapshot()
        l0EngineSnapshot.monitoredUUID = fun.monitoredUUID
        l0EngineSnapshot.monitoredDeviceName = monitoredDeviceName
        l0EngineSnapshot.presence = snap.presence
        l0EngineSnapshot.effectiveRSSI = snap.effectiveRSSI
        l0EngineSnapshot.screen = state.screen
        l0EngineSnapshot.systemPower = state.system
        l0EngineSnapshot.intent = state.intent

        let active = powerKeepAlive.evaluate(
            state: &l0EngineSnapshot,
            idleSeconds: idleSecondsProvider(),
            config: currentEngineConfig(),
            now: now,
            forceRenew: forceRenew
        )
        if active, let renewAt = l0EngineSnapshot.deadlines[.keepAliveRenew] {
            fun.scheduler.schedule(.keepAliveRenew, at: renewAt)
        } else {
            fun.scheduler.cancel(.keepAliveRenew)
        }
    }

    func startRuntimeAdapters() {
        negativeSignalAdapter?.start()
        syncL0KeepAlive()
    }

    // MARK: Init

    init(fun: FUn, nowProvider: @escaping () -> Date = { Date() }, decisionLogger: DecisionLogger = .shared) {
        self.fun = fun
        self.stateMachine = FUnlockStateMachine(nowProvider: nowProvider)
        self.nowProvider = nowProvider
        self.decisionLogger = decisionLogger
        self.lockRSSI = fun.lockRSSI
        self.unlockRSSI = fun.unlockRSSI

        // 接线：updateChecker → downloader → installer
        updateChecker.onNewVersion = { [weak self] version in
            self?.downloader.download(version: version)
        }
        downloader.onStateChange = { [weak self] state in
            self?.updateState = state
            if case .completed(let appPath) = state {
                // 安全加固：下载解压验证完成后提示用户确认，不再静默覆盖安装重启
                self?.promptInstallConfirmation(appPath: appPath)
            }
        }

        // 装配解锁流水线协调器（共用同一时间源，保证冷却/缓冲判定一致）
        self.orchestrator = UnlockOrchestrator(manager: self, nowProvider: nowProvider)

        fun.lock.withLock {
            fun.onKeepAliveRenew = { [weak self] in
                self?.syncL0KeepAlive(forceRenew: true)
            }
        }
        self.negativeSignalAdapter = NegativeSignalAdapter { [weak self] source in
            self?.fun.applyNegativeHint(source)
        }
    }

    deinit {
        intrudeCheckTask?.cancel()
        systemWakeTask?.cancel()
        deferredLockTask?.cancel()
        screenLockVerifyTask?.cancel()
        // orchestrator 随本类释放，其 deinit 负责取消 wakeTask / unlockTask
    }

    // MARK: - 阈值同步

    func setLockRSSI(_ value: Int) {
        var finalLock = value
        // 防御性校验：若解锁功能开启且不是锁定禁用哨兵，锁定阈值必须严于（更远/小于）解锁阈值
        if finalLock != FUn.LOCK_DISABLED && unlockRSSI != FUn.UNLOCK_DISABLED {
            finalLock = min(finalLock, unlockRSSI - 1)
        }
        lockRSSI = finalLock
        fun.lockRSSI = finalLock
        ConfigStore.shared.set(finalLock, forKey: "lockRSSI")
        thresholdVersion += 1
    }

    func setUnlockRSSI(_ value: Int) {
        unlockRSSI = value
        fun.unlockRSSI = value
        ConfigStore.shared.set(value, forKey: "unlockRSSI")
        defer { thresholdVersion += 1 }
        if value != FUn.UNLOCK_DISABLED {
            // 迟滞联动仅修正「违反序关系」的锁定阈值：
            // 用户已自定义合法更远的 lock（lock < value）时不覆写；
            // 只有 lock 缺省/越界（lock >= value 或为禁用哨兵）才联动到 unlock-10
            if lockRSSI != FUn.LOCK_DISABLED && lockRSSI >= value {
                let idealLock = value - lockUnlockDelayGap
                let clampedLock = SignalHysteresisEngine.clampRSSI(idealLock)
                let safeLock = min(clampedLock, value - 1)
                setLockRSSI(safeLock)
            }
        }
    }

    /// 设置唤醒提前量（dB）：解锁阈值往更远方向提前（自动钳制到 0-20）
    func setWakeAdvance(_ value: Int) {
        ConfigStore.shared.set(FUn.clampOffset(value), forKey: "wakeAdvance")
        thresholdVersion += 1
    }

    /// 设置预解锁触发量（dB）：解锁阈值往更远方向提前进入预解锁准备（自动钳制到 0-20）
    func setPreUnlockTrigger(_ value: Int) {
        ConfigStore.shared.set(FUn.clampOffset(value), forKey: "preUnlockTrigger")
        thresholdVersion += 1
    }

    // MARK: - 扫描控制

    func startScanning() {
        fun.startScanning()
    }

    func stopScanning() {
        fun.stopScanning()
    }

    /// 被动扫描模式写路径唯一入口（设置页不再直写 FUn）：转发并记录切换
    func setPassiveMode(_ mode: Bool) {
        AppLog.info(.sm, "setPassiveMode", [("enabled", "\(mode)")])
        fun.setPassiveMode(mode)
    }

    // MARK: - 核心：自动解锁（转发至 UnlockOrchestrator，保持对外签名 100% 兼容）

    func attemptAutoUnlock() {
        orchestrator.attemptAutoUnlock()
    }

    // MARK: - 用户操作

    func lockNow() {
        guard !SystemInteractionService.shared.isScreenLocked(screenState: state.screen) else { return }
        // 手动锁定：清空自锁窗口，永久阻止自动解锁，直到用户下次手动解锁（onUnlock 重置 intent）
        cancelDeferredLockRecheck()
        screenLockVerifyTask?.cancel()
        screenLockVerifyTask = nil
        clearSelfLockWindow()
        markManualLock()
        state.screen = .locked(reason: .manual)
        lastLockTime = now
        checkAndPauseMedia()
        SystemInteractionService.shared.lockOrSaveScreen(
            useScreensaver: prefs.bool(forKey: "screensaver"),
            sleepDisplayAfter: prefs.bool(forKey: "sleepDisplay"))
        scheduleLockVerification()
    }

    // MARK: - 设备发现

    func onDeviceDiscovered(_ device: DeviceSnapshot) {
        if let idx = discoveredDevices.firstIndex(where: { $0.uuid == device.uuid }) {
            discoveredDevices[idx] = device
        } else {
            discoveredDevices.append(device)
        }
    }

    func onDeviceUpdated(_ device: DeviceSnapshot) {
        if let idx = discoveredDevices.firstIndex(where: { $0.uuid == device.uuid }) {
            // DeviceSnapshot 为纯值类型，整元素替换即触发 @Observable 数组变更通知，
            // 无需像旧引用类型那样就地改字段后手动补发
            discoveredDevices[idx] = device
        }
    }

    func onDeviceRemoved(_ device: DeviceSnapshot) {
        discoveredDevices.removeAll { $0.uuid == device.uuid }
    }

    func selectDevice(_ device: DeviceSnapshot) {
        fun.startMonitor(uuid: device.uuid)
        monitoredDeviceName = device.name
        prefs.set(device.uuid.uuidString, forKey: "device")
        prefs.set(device.name, forKey: "deviceName")
    }

    func unbindDevice() {
        // 先取锁内监控的 peripheral 引用，锁外取消连接
        let peripheralToCancel = fun.withLockedPeripheral()
        if let p = peripheralToCancel {
            fun.centralMgr.cancelPeripheralConnection(p)
        }
        // 先清监控 UUID，再无条件停扫：被动模式下 stopScanning() 会因
        // shouldStopCentralScanOnStopDiscovery()==false 而保留扫描，解绑必须绕开该保护。
        fun.unbindAllState()
        fun.stopAllScanning()
        // 清除所有 timer
        fun.invalidateAllTimers()
        fun.invalidateAllDeviceTimers()

        // 清除 Manager 层状态
        monitoredDeviceName = nil
        watchAutoUnlockObserved = false
        l1TimeoutStreak = 0
        prefs.removeObject(forKey: "device")
        prefs.removeObject(forKey: "deviceName")
        rssi = nil
        connected = false
        syncL0KeepAlive()
    }

    // MARK: - Now Playing（委托 SystemInteractionService）

    func checkAndPauseMedia() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        state.media = .idle
        SystemInteractionService.shared.checkAndPauseMedia(enabled: true) { [weak self] playing in
            self?.mediaWasPlaying = playing
            self?.state.media = playing ? .wasPlaying : .paused
        }
    }

    func resumeMediaIfNeeded() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        guard state.media == .wasPlaying else { return }
        SystemInteractionService.shared.resumeMediaIfNeeded(wasPlaying: mediaWasPlaying, enabled: true)
        state.media = .idle
    }

    // 屏幕操作、键盘注入、Keychain、通知、日志、脚本 — 已迁移至
    // SystemInteractionService / SecurityService / ScriptRunner

    func checkUpdate() {
        updateChecker.check()
    }

    /// 手动触发检查更新（completion 在主线程回调）
    func forceCheckUpdate(completion: (@MainActor (String?) -> Void)? = nil) {
        updateChecker.forceCheck(completion: completion)
    }

    /// 三态检查结果（UI 用于区分「已是最新」与「检查失败」）
    func forceCheckUpdateResult(completion: @escaping @MainActor (UpdateChecker.CheckResult) -> Void) {
        updateChecker.forceCheckResult(completion: completion)
    }

    // MARK: - 清理（退出时调用，防止 RunLoop Timer 崩溃）

    func cleanup() {
        negativeSignalAdapter?.stop()
        powerKeepAlive.releaseAll(state: &l0EngineSnapshot)
        // 退出时不要同步 invalidate Timer —— RunLoop 正在销毁 Timer 列表，
        // 同步 invalidate 会导致 __CFRunLoopDeallocateTimers 数组越界崩溃。
        // 延迟到下一个 RunLoop 迭代（退出时不会执行，Timer 随 RunLoop 一起释放）。
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.fun.invalidateAllTimers()
            self.fun.invalidateAllDeviceTimers()
            funlock_releaseWakeAssertion()
            funlock_releasePresenceKeepAlive()
        }
        orchestrator.cancelPendingTasks()
        lockVerificationGeneration &+= 1
        systemWakeTask?.cancel()
        systemWakeGeneration &+= 1
        cancelDeferredLockRecheck()
        screenLockVerifyTask?.cancel()
        screenLockVerifyTask = nil
        intrudeCheckTask?.cancel()
    }

    // MARK: - 冷却与缓冲检查

    /// 解锁冷却期内（成功解锁后 unlockCooldownDuration 秒内）返回 true
    func isUnlockCooldownActive() -> Bool {
        now.timeIntervalSince(lastUnlockTime) < unlockCooldownDuration
    }

    /// 锁屏缓冲期内（自动锁屏后 lockBufferDuration 秒内）返回 true
    func isLockBufferActive() -> Bool {
        now.timeIntervalSince(lastLockTime) < lockBufferDuration
    }

    // MARK: - 便利属性

    var isDeviceConnected: Bool { connected }

    func updateConnected(_ newValue: Bool) {
        connected = newValue
    }

    // MARK: - 更新安装确认

    /// 锁屏期间暂存的待安装包路径：解锁后由 onUnlock 消费，
    /// 避免在锁屏时直接 runModal 阻塞 @MainActor 主线程
    @ObservationIgnored var pendingUpdateAppPath: URL?
    /// 测试注入：替代真实 NSAlert 的安装确认弹窗
    @ObservationIgnored var presentInstallConfirmationOverride: ((URL) -> Void)?

    /// 下载完成后的安装确认入口：锁屏时只暂存，解锁后消费
    func promptInstallConfirmation(appPath: URL) {
        if SystemInteractionService.shared.isSystemSessionLocked() {
            pendingUpdateAppPath = appPath
            AppLog.info(.app, "updatePromptDeferred", [("reason", "sessionLocked")])
            return
        }
        presentInstallConfirmation(appPath: appPath)
    }

    /// 解锁后消费锁屏期间暂存的安装确认
    func consumePendingUpdatePromptIfNeeded() {
        guard let appPath = pendingUpdateAppPath else { return }
        pendingUpdateAppPath = nil
        AppLog.info(.app, "updatePromptConsumed")
        presentInstallConfirmation(appPath: appPath)
    }

    /// 真正展示安装确认（可被测试注入替代）
    private func presentInstallConfirmation(appPath: URL) {
        if let override = presentInstallConfirmationOverride {
            override(appPath)
            return
        }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("update_ready_title", value: "新版本已准备就绪", comment: "")
        alert.informativeText = NSLocalizedString("update_ready_info", value: "新版本已下载并验证签名完成，是否立即退出并更新？", comment: "")
        alert.addButton(withTitle: NSLocalizedString("update_install_now", value: "立即更新", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("later", value: "稍后", comment: ""))
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try UpdateInstaller.install(appPath: appPath)
            } catch {
                self.updateState = .failed(error.localizedDescription)
            }
        }
    }
}
