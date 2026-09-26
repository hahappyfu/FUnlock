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
    var isSelfLocking = false  // 区分 FUnlock 自动锁屏 vs 用户手动锁屏
    @ObservationIgnored private let updateChecker = UpdateChecker(defaults: ConfigStore.shared.defaults)
    @ObservationIgnored private let downloader = UpdateDownloader()
    private(set) var updateState: UpdateDownloader.State = .idle
    @ObservationIgnored let prefs = ConfigStore.shared.defaults
    /// 后台探测任务的取消句柄，纯内部簿记状态，不参与视图渲染，
    /// 且需在非隔离的 `deinit` 中访问，故显式排除在 @Observable 跟踪之外。
    @ObservationIgnored var intrudeCheckTask: Task<Void, Never>?
    @ObservationIgnored private var mediaWasPlaying = false

    /// 解锁流水线协调器：密码获取 → 注入 → 双保险验证 → 显示器唤醒重试
    /// （在 init 末尾装配；强持有，orchestrator 以 unowned 反向引用本类）
    private(set) var orchestrator: UnlockOrchestrator!

    // MARK: - 冷却与缓冲策略（可测试时间源）
    /// 可注入时间源：仅门控判定内部读取，不驱动视图，故排除在跟踪之外
    @ObservationIgnored var nowProvider: () -> Date = { Date() }
    var now: Date { nowProvider() }
    /// 解锁成功后的冷却时间（秒），冷却期内不重复尝试解锁
    var unlockCooldownDuration: TimeInterval = 5.0
    /// 自动锁屏后的缓冲时间（秒），缓冲期内不尝试自动解锁
    var lockBufferDuration: TimeInterval = 0.8
    /// 上次自动锁屏的时间（通过 onDeviceLeft 触发）
    var lastLockTime: Date = .distantPast
    /// 上次成功解锁的时间（自动或手动解锁时更新）
    var lastUnlockTime: Date = .distantPast

    // MARK: - 决策记录辅助（锁 / 系统 / 用户；解锁类记录见 UnlockOrchestrator）

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
    }

    deinit {
        intrudeCheckTask?.cancel()
        // orchestrator 随本类释放，其 deinit 负责取消 wakeTask / unlockTask
    }

    // MARK: - 阈值同步

    func setLockRSSI(_ value: Int) {
        var finalLock = value
        // 防御性校验：若解锁功能开启且不是锁定禁用哨兵，锁定阈值必须严于（更远/小于）解锁阈值
        if finalLock != SignalHysteresisEngine.lockDisabled && unlockRSSI != FUn.UNLOCK_DISABLED {
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
        if value != FUn.UNLOCK_DISABLED {
            // 迟滞联动：锁定阈值应比解锁阈值更远（更小）；
            // 若受下限钳制无法拉满 gap，强制保证 lock < unlock
            let idealLock = value - lockUnlockDelayGap
            let clampedLock = SignalHysteresisEngine.clampRSSI(idealLock)
            let safeLock = min(clampedLock, value - 1)
            setLockRSSI(safeLock)
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

    // MARK: - 核心：自动解锁（转发至 UnlockOrchestrator，保持对外签名 100% 兼容）

    func attemptAutoUnlock() {
        orchestrator.attemptAutoUnlock()
    }

    // MARK: - 用户操作

    func lockNow() {
        guard !SystemInteractionService.shared.isScreenLocked(screenState: state.screen) else { return }
        // 手动锁定：永久阻止自动解锁，直到用户下次手动解锁（onUnlock 重置 intent）
        state.intent = .manualLock(deadline: Date().addingTimeInterval(86400))
        state.screen = .locked(reason: .manual)
        lastLockTime = now
        checkAndPauseMedia()
        SystemInteractionService.shared.lockOrSaveScreen(
            useScreensaver: prefs.bool(forKey: "screensaver"),
            sleepDisplayAfter: prefs.bool(forKey: "sleepDisplay"))
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
        fun.stopScanning()
        // 清除所有 timer
        fun.invalidateAllTimers()
        fun.invalidateAllDeviceTimers()
        // 重置状态
        fun.unbindAllState()

        // 清除 Manager 层状态
        monitoredDeviceName = nil
        prefs.removeObject(forKey: "device")
        prefs.removeObject(forKey: "deviceName")
        rssi = nil
        connected = false
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

    // MARK: - 清理（退出时调用，防止 RunLoop Timer 崩溃）

    func cleanup() {
        // 退出时不要同步 invalidate Timer —— RunLoop 正在销毁 Timer 列表，
        // 同步 invalidate 会导致 __CFRunLoopDeallocateTimers 数组越界崩溃。
        // 延迟到下一个 RunLoop 迭代（退出时不会执行，Timer 随 RunLoop 一起释放）。
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.fun.invalidateAllTimers()
            self.fun.invalidateAllDeviceTimers()
            funlock_releaseWakeAssertion()
        }
        orchestrator.cancelPendingTasks()
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

    /// 下载完成后的安装确认弹窗：由用户主动确认后执行替换与重启，防止静默换装
    private func promptInstallConfirmation(appPath: URL) {
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
