import Foundation
@preconcurrency import CoreBluetooth
import Combine
import os

func lockLog(_ msg: String) {
    logDebug(component: "Lock", msg)
}

/// 日志节流器：内部锁保护时间戳字典，消除裸全局可变状态
private final class BLELogThrottler: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTime: [String: Date] = [:]

    /// 距上次记录超过 interval 时返回 true 并更新时间戳
    func shouldLog(key: String, interval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if let last = lastTime[key], now.timeIntervalSince(last) < interval { return false }
        lastTime[key] = now
        return true
    }
}

private let bleLogThrottler = BLELogThrottler()
func throttledBleLog(_ key: String, interval: TimeInterval = 1.0, _ msg: String) {
    guard bleLogThrottler.shouldLog(key: key, interval: interval) else { return }
    Log.ble.debug("\(msg)")
}

/// BLE 服务/特征 UUID 命名空间
enum BLEUUIDs {
    static let deviceInformation = CBUUID(string: "180A")
    static let manufacturerName = CBUUID(string: "2A29")
    static let modelName = CBUUID(string: "2A24")
    static let exposureNotification = CBUUID(string: "FD6F")
}

/// 接近阈值窗口（dBm）：有效信号进入 [threshold-window, threshold) 时启用快速轮询
let proximityPollWindow = 15.0
/// 快速轮询间隔（s）：信号接近阈值时降低感知延迟
let fastPollInterval = 0.5
/// 解锁 → 锁定 联动迟滞（dB）：调解解锁阈值时锁定自动设为 unlockRSSI - lockUnlockDelayGap
let lockUnlockDelayGap = 10
/// 快速锁屏（s）：信号快速下降时的锁屏超时
let fastLockTimeout = 2.5
/// 判定「快速下降」的斜率阈值（dBm/s），slope ≤ -8 视为快速离开
let fastSlopeThreshold = 8.0
/// 判定「缓降」的斜率阈值（dBm/s），slope ≥ -1 视为接近平稳
let mildSlopeThreshold = 1.0

/// 蓝牙事件回调协议：所有回调均涉及 UI 更新、通知或主线程状态机
/// （AppDelegate 的 manager.onDeviceDiscovered 等），故协议层隔离到主 actor。
/// FUn 内部派发时统一通过 `Task { @MainActor [weak self] in ... }` 跨回主线程。
@MainActor
protocol FUnDelegate: AnyObject {
    func newDevice(device: Device)
    func updateDevice(device: Device)
    func removeDevice(device: Device)
    func updateRSSI(rssi: Int?, active: Bool)
    func updatePresence(presence: Bool, reason: String)
    func bluetoothPowerWarn()
    func onDeviceApproached()
}

/// BLE 中央管理器。
/// 线程契约（@unchecked Sendable 依据）：
/// - CBCentralManager 回调与设备扫描在串行 `bleQueue` 上执行，跨线程共享状态
///   （devices / monitoredUUID / presence / pipeline 等）统一由 `lock`（UnfairLock）保护；
/// - Timer 操作与 `@Published`（lockRSSI/unlockRSSI）读写收敛在主 RunLoop 与主线程；
/// - 向 `delegate`（@MainActor 协议）的派发统一走 `Task { @MainActor [weak self] }` 跨回主线程。
class FUn: NSObject, ObservableObject, @unchecked Sendable, BLEScannerHost {
    static let UNLOCK_DISABLED = SignalHysteresisEngine.unlockDisabled
    static let LOCK_DISABLED = SignalHysteresisEngine.lockDisabled
    let bleQueue = DispatchQueue(label: "com.funlock.ble")
    private let lock = UnfairLock()
    private(set) var scanner: BLEScanner!
    var centralMgr: CBCentralManager! { scanner.centralMgr }
    var devices: [UUID: Device] {
        get { scanner.devices }
        set { scanner.devices = newValue }
    }
    weak var delegate: FUnDelegate?
    var inputMonitor: InputActivityMonitor?

    /// 用户是否有输入活动（nil-safe，线程安全）
    private var isUserInputActive: Bool {
        inputMonitor?.isActive == true
    }

    var scanMode: Bool {
        get { scanner.scanMode }
        set { scanner.scanMode = newValue }
    }
    var monitoredUUID: UUID? {
        get { scanner.monitoredUUID }
        set { scanner.monitoredUUID = newValue }
    }
    var monitoredUUIDs: Set<UUID> {
        get { scanner.monitoredUUIDs }
        set { scanner.monitoredUUIDs = newValue }
    }
    var monitoredPeripheral: CBPeripheral? {
        get { scanner.monitoredPeripheral }
        set { scanner.monitoredPeripheral = newValue }
    }
    private var proximityTimer : Timer?
    private var signalTimer: Timer?
    var presence = false
    @Published var lockRSSI = -80
    @Published var unlockRSSI = -60
    var proximityTimeout = 5.0
    var signalTimeout = 60.0
    var lastReadAt: Double {
        get { scanner.lastReadAt }
        set { scanner.lastReadAt = newValue }
    }
    private var powerWarn = true
    var passiveMode: Bool {
        get { scanner.passiveMode }
        set { scanner.passiveMode = newValue }
    }
    var activeModeTimer: Timer? {
        get { scanner.activeModeTimer }
        set { scanner.activeModeTimer = newValue }
    }
    var connectionTimer: Timer? {
        get { scanner.connectionTimer }
        set { scanner.connectionTimer = newValue }
    }
    var stableCount: Int {
        get { scanner.stableCount }
        set { scanner.stableCount = newValue }
    }
    var activePollInterval: TimeInterval {
        get { scanner.activePollInterval }
        set { scanner.activePollInterval = newValue }
    }
    var lastEstimatedRSSI: Int {
        get { scanner.lastEstimatedRSSI }
        set { scanner.lastEstimatedRSSI = newValue }
    }
    var thresholdRSSI = -90
    // 管道状态 (替代旧的散装字段)
    var pipeline = SignalPipeline()
    var effectiveRSSI: Double = -60.0
    var displayRSSI: Double = -60.0
    /// EMA 平滑 RSSI（alpha=0.3），用于预备唤醒阈值判断
    private var smoothedRSSIValue: Double = -100.0
    private let smoothedRSSIAlpha: Double = 0.3
    // MARK: 阶梯唤醒阈值（由解锁阈值 - 用户偏移派生）
    /// 默认唤醒提前量（dB）
    static let defaultWakeAdvance = SignalHysteresisEngine.defaultWakeAdvance
    /// 默认预解锁触发量（dB）
    static let defaultPreUnlockTrigger = SignalHysteresisEngine.defaultPreUnlockTrigger
    /// 偏移量允许范围（dB）
    static let offsetRange = SignalHysteresisEngine.offsetRange
    /// 将偏移量钳制到允许范围（UI 可能输入越界值）
    static func clampOffset(_ value: Int) -> Int {
        SignalHysteresisEngine.clampOffset(value)
    }
    /// 预备唤醒阈值（dBm）：解锁阈值往更远方向提前 wakeAdvance（UI 可填，默认 20）
    var preWakeThreshold: Int {
        guard unlockRSSI != Self.UNLOCK_DISABLED else { return unlockRSSI }
        let advance = SignalHysteresisEngine.offsetSetting("wakeAdvance", default: Self.defaultWakeAdvance)
        return unlockRSSI - advance
    }
    /// 预解锁触发阈值（dBm）：解锁阈值往更远方向提前 preUnlockTrigger（UI 可填，默认 10），
    /// 信号进入该接近窗口时启用 0.5s 快速轮询（开足马力探测）；不再直接触发解锁，
    /// 真正解锁由信号达到 unlockRSSI 决定
    var unlockStairThreshold: Int {
        guard unlockRSSI != Self.UNLOCK_DISABLED else { return unlockRSSI }
        let trigger = SignalHysteresisEngine.offsetSetting("preUnlockTrigger", default: Self.defaultPreUnlockTrigger)
        return unlockRSSI - trigger
    }
    var lastReceiveTime: Date = Date()
    var lastSignalAnomalous: Bool = false
    // Heartbeat timer (独立状态机，不在管道内)
    var heartbeatTimer: Timer?
    var heartbeatInterval: TimeInterval = 2.0
    private var lastHeartbeatInterval: TimeInterval = 2.0
    var signalLostCount: Int = 0
    // 冷静期：解锁后短时间内不触发锁定，防止振荡
    private var lastProximityEventTime: Date = .distantPast
    private let proximityGracePeriod: TimeInterval = 5.0

    func scanForPeripherals() {
        scanner.scanForPeripherals()
    }

    func startScanning() {
        scanner.startScanning()
    }

    func stopScanning() {
        scanner.stopScanning()
    }

    func setPassiveMode(_ mode: Bool) {
        scanner.setPassiveMode(mode)
    }

    func startMonitor(uuid: UUID) {
        // 快照需要在锁外操作的旧 peripheral
        let oldPeripheral: CBPeripheral? = lock.withLock {
            let old = monitoredUUID != uuid ? monitoredPeripheral : nil

            // 重置所有共享状态
            monitoredUUID = uuid
            scanMode = true
            // presence 不强制置 true：绑定后须信号实际达到解锁阈值（checkProximity）才标记在场，
            // 避免"设备从未靠近"（如忘带手表）时因 presence 残留触发锁屏
            presence = false
            monitoredPeripheral = nil
            activeModeTimer?.invalidate()
            activeModeTimer = nil
            connectionTimer?.invalidate()
            connectionTimer = nil
            stableCount = 0
            activePollInterval = 2.0
            lastEstimatedRSSI = 0
            signalLostCount = 0
            pipeline.reset()
            lastReceiveTime = Date()
            effectiveRSSI = -60.0
            displayRSSI = -60.0
            smoothedRSSIValue = -100.0
            monitoredUUIDs = [uuid]
            return old
        }

        // Timer 操作在锁外（RunLoop 线程安全，但 invalidate 后不应再用锁）
        proximityTimer?.invalidate()
        proximityTimer = nil
        resetSignalTimer()
        cancelHeartbeat()

        // BLE 操作在锁外（CBCentralManager 在 bleQueue 执行）
        if let p = oldPeripheral {
            centralMgr.cancelPeripheralConnection(p)
        }
        let known = centralMgr.retrievePeripherals(withIdentifiers: [uuid])
        if let peripheral = known.first {
            Log.ble.debug("[FUn] Found known peripheral: \(peripheral.identifier) state=\(peripheral.state.rawValue)")
            lock.withLock { monitoredPeripheral = peripheral }
            if peripheral.state == .disconnected {
                centralMgr.connect(peripheral, options: nil)
            }
        }

        scanForPeripherals()
    }

    func resetSignalTimer() {
        signalTimer?.invalidate()
        let timer = Timer(timeInterval: signalTimeout, repeats: true, block: { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            let shouldLose: Bool = self.lock.withLock {
                // 输入活动且 lockOnIdle 开启时，不判定信号丢失（与 applyLockTimer 行为一致），
                // 仅重置超时计数与衰减基准，避免打字/用鼠标时因信号超时误锁
                let lockOnIdle = ConfigStore.shared.object(forKey: "lockOnIdle") == nil
                    || ConfigStore.shared.bool(forKey: "lockOnIdle")
                if lockOnIdle && self.isUserInputActive {
                    self.signalLostCount = 0
                    self.lastReceiveTime = Date()
                    self.pipeline.decayBaseline = Date()
                    return false
                }
                self.signalLostCount += 1
                return self.signalLostCount >= 3
            }
            if shouldLose {
                timer.invalidate()
                self.markSignalLost()
            } else {
                Log.sm.debug("Signal timeout \(self.lock.withLock { self.signalLostCount })/3, waiting...")
            }
        })
        RunLoop.main.add(timer, forMode: .common)
        signalTimer = timer
    }

    /// 信号丢失（3 次连续超时）统一复位：清在场标志、有效信号复位到无信号档（-100）、
    /// 通知 UI（rssi 置 nil，与总览「无信号」判据一致），避免菜单栏残留冻结的旧信号值
    func markSignalLost() {
        let wasPresent = lock.withLock { self.presence }
        lock.withLock {
            presence = false
            signalLostCount = 0
            if effectiveRSSI > -100.0 {
                effectiveRSSI = -100.0
            }
        }
        Log.sm.debug("Device is lost (3 consecutive timeouts)")
        Task { @MainActor [weak self] in
            self?.delegate?.updateRSSI(rssi: nil, active: false)
        }
        if wasPresent {
            // P1: 记录信号丢失锁定事件
            SignalDataStore.shared.record(
                rawRSSI: -100, kalmanEstimate: -100,
                effectiveRSSI: -100, slope: 0, isAnomalous: false,
                event: "locked: lost")
            Task { @MainActor [weak self] in
                self?.delegate?.updatePresence(presence: false, reason: "lost")
            }
        }
    }

    // MARK: - Time decay computation (heartbeat fallback, depends only on self.effectiveRSSI)

    /// 信号中断期间的有效信号衰减：分段的温和曲线 + 封顶。
    /// 目的：BLE 采样短暂间隙（几秒）不应把信号强行压到锁阈值之下造成误锁；
    /// 但同时保证真实离场（长时间无采样）仍能衰减到阈值以下触发锁定。
    /// - Parameters:
    ///   - effectiveRSSI: 最近一次采样的有效信号（dBm）
    ///   - elapsedSinceLastReceive: 距离最后一次采样的时间（秒）
    static func decayedEffectiveRSSI(effectiveRSSI: Double, elapsedSinceLastReceive: TimeInterval) -> Double {
        let penalty: Double
        if elapsedSinceLastReceive <= 6.0 {
            // 6 秒内：不额外惩罚，信任管道 effectiveRSSI（缓冲 BLE 采样间隙）
            penalty = 0
        } else if elapsedSinceLastReceive <= 10.0 {
            // 6~10 秒：温和线性（0.75 dB/s，最多 3 dB）
            penalty = (elapsedSinceLastReceive - 6.0) * 0.75
        } else {
            // 10 秒后：1 dB/s，累计最多 20 dB（防止长时间陈旧值剧烈下探）
            penalty = min(3.0 + (elapsedSinceLastReceive - 10.0), 20.0)
        }
        return max(effectiveRSSI - penalty, -100.0)
    }

    func getEffectiveRSSI() -> Double {
        let (lastRecv, effRSSI) = lock.withLock { (lastReceiveTime, effectiveRSSI) }
        let elapsed = Date().timeIntervalSince(lastRecv)
        return Self.decayedEffectiveRSSI(effectiveRSSI: effRSSI, elapsedSinceLastReceive: elapsed)
    }

    /// 跨线程共享信号状态的锁内快照（Manager/UI 统一走快照，避免逐字段裸读）
    struct SignalSnapshot {
        let effectiveRSSI: Double
        let presence: Bool
        let kalmanEstimate: Double
        let smoothedSlope: Double
        let lastSignalAnomalous: Bool
        let activeModeActive: Bool
    }

    func signalSnapshot() -> SignalSnapshot {
        lock.withLock {
            SignalSnapshot(
                effectiveRSSI: effectiveRSSI,
                presence: presence,
                kalmanEstimate: pipeline.kalmanEstimate,
                smoothedSlope: pipeline.smoothedSlope,
                lastSignalAnomalous: lastSignalAnomalous,
                activeModeActive: activeModeTimer != nil
            )
        }
    }

    /// 锁内遍历 devices（Manager 解绑/清理时避免裸读字典）
    func withDevices(_ body: ([UUID: Device]) -> Void) {
        lock.withLock { body(devices) }
    }

    /// 锁内读取监控的 peripheral 引用（锁外取消连接）
    func withLockedPeripheral() -> CBPeripheral? {
        lock.withLock { monitoredPeripheral }
    }

    /// 锁内重置解绑状态（unbindDevice 改用它，替代 Manager 无锁覆写）
    func unbindAllState() {
        lock.withLock {
            monitoredUUID = nil
            monitoredUUIDs.removeAll()
            monitoredPeripheral = nil
            scanMode = false
            presence = false
            signalLostCount = 0
            stableCount = 0
            activePollInterval = 2.0
            lastEstimatedRSSI = 0
            pipeline.reset()
            effectiveRSSI = -60.0
            displayRSSI = -60.0
            smoothedRSSIValue = -100.0
        }
    }

    // MARK: - Direction 3: Heartbeat — proactive lock check
    private func ensureHeartbeat() {
        let alreadyExists = lock.withLock { heartbeatTimer != nil }
        guard !alreadyExists else { return }
        let interval = computeHeartbeatInterval()
        let timer: Timer = lock.withLock {
            lastHeartbeatInterval = interval
            heartbeatTimer = makeHeartbeatTimer(interval: interval)
            return heartbeatTimer!
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func computeHeartbeatInterval() -> TimeInterval {
        let eff = getEffectiveRSSI()
        let baseTh = Double(unlockRSSI) + 10.0
        let lockTh = Double(lockRSSI == Self.LOCK_DISABLED ? unlockRSSI : lockRSSI) + 10.0
        if eff > baseTh { return 8.0 }
        if eff < lockTh { return 2.0 }
        return 3.0
    }

    private func makeHeartbeatTimer(interval: TimeInterval) -> Timer {
        return Timer(timeInterval: interval, repeats: true, block: { [weak self] _ in
            guard let self = self else { return }
            let shouldStop = self.lock.withLock {
                guard self.presence else {
                    self.heartbeatTimer?.invalidate()
                    self.heartbeatTimer = nil
                    return true
                }
                return false
            }
            guard !shouldStop else { return }
            let eff = self.getEffectiveRSSI()
            let threshold = Double(self.lockRSSI == Self.LOCK_DISABLED ? self.unlockRSSI : self.lockRSSI)
            let hasTimer = self.lock.withLock { self.proximityTimer != nil }
            // 冷静期：刚解锁后不立即触发锁定
            let graceElapsed = Date().timeIntervalSince(self.lastProximityEventTime)
            lockLog("[LOCK] heartbeat eff=\(String(format: "%.1f", eff)) threshold=\(Int(threshold)) hasTimer=\(hasTimer) graceElapsed=\(String(format: "%.1f", graceElapsed)) inputActive=\(self.isUserInputActive)")
            if eff < threshold && !hasTimer && graceElapsed >= self.proximityGracePeriod {
                if self.isUserInputActive {
                    // 用户活跃时重置衰减基准，阻止衰减累积
                    self.lock.withLock {
                        self.lastReceiveTime = Date()
                        self.pipeline.decayBaseline = Date()
                    }
                } else {
                    Log.sm.debug("[HB] effectiveRSSI=\(Int(eff)) < threshold=\(Int(threshold)), starting lock timer")
                    self.startLockTimer()
                }
            }
            let newInterval = self.computeHeartbeatInterval()
            // P0 #4 修复：invalidate + 创建 + 状态更新全部在锁内完成，避免 cancelHeartbeat 竞态
            let timerToAdd: Timer? = self.lock.withLock {
                let lastInterval = self.lastHeartbeatInterval
                guard abs(newInterval - lastInterval) > 0.5 else { return nil }
                Log.sm.debug("[HB] interval \(lastInterval)s → \(newInterval)s")
                self.heartbeatTimer?.invalidate()
                let newTimer = self.makeHeartbeatTimer(interval: newInterval)
                self.lastHeartbeatInterval = newInterval
                self.heartbeatTimer = newTimer
                return newTimer
            }
            if let timerToAdd = timerToAdd {
                RunLoop.main.add(timerToAdd, forMode: .common)
            }
        })
    }

    func cancelHeartbeat() {
        lock.withLock {
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
        }
    }

    /// 刷新锁冷静基准（所有解锁成功路径调用）：重置 lastProximityEventTime，
    /// 使心跳锁检查与锁计时器触发时都能看到「距最近解锁 < proximityGracePeriod」
    func refreshProximityGrace() {
        lock.withLock { lastProximityEventTime = Date() }
    }

    /// 是否处于锁冷静期（距最近解锁/靠近 < proximityGracePeriod）
    func isWithinLockGracePeriod(now: Date = Date()) -> Bool {
        let last = lock.withLock { lastProximityEventTime }
        return SignalHysteresisEngine.isWithinLockGracePeriod(
            lastUnlockTime: last, gracePeriod: proximityGracePeriod, now: now)
    }

    func invalidateAllTimers() {
        lock.withLock {
            signalTimer?.invalidate()
            signalTimer = nil
            proximityTimer?.invalidate()
            proximityTimer = nil
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
        }
        scanner?.invalidateAllTimers()
    }

    func invalidateAllDeviceTimers() {
        scanner?.invalidateAllDeviceTimers()
    }

    // MARK: - Lock timer (shared by updateMonitoredPeripheral and heartbeat)
    /// 方案 C：按下降斜率计算锁屏超时 —— 陡降（slope ≤ -fastSlopeThreshold）→ fastLockTimeout；
    /// 缓降/平稳（slope ≥ -mildSlopeThreshold）→ base；中间线性插值
    static func lockTimeout(slope: Double, base: TimeInterval = 5.0) -> TimeInterval {
        SignalHysteresisEngine.lockTimeout(slope: slope, base: base)
    }

    /// 方案 A：信号是否处于接近窗口（有效信号进入 [threshold-window, threshold)）
    static func isNearThreshold(_ effectiveRSSI: Double, threshold: Double) -> Bool {
        SignalHysteresisEngine.isNearThreshold(effectiveRSSI, threshold: threshold)
    }

    private func startLockTimer() {
        // 方案 C：锁屏超时随下降斜率自适应
        let slope = lock.withLock { pipeline.smoothedSlope }
        let timeout = Self.lockTimeout(slope: slope, base: proximityTimeout)
        let timer = Timer(timeInterval: timeout, repeats: false, block: { [weak self] _ in
            guard let self = self else { return }
            let lockOnIdle = ConfigStore.shared.object(forKey: "lockOnIdle") == nil
                || ConfigStore.shared.bool(forKey: "lockOnIdle")
            let nowEff = self.getEffectiveRSSI()
            let nowThreshold = Double(self.lockRSSI == Self.LOCK_DISABLED ? self.unlockRSSI : self.lockRSSI)
            let nowPresence = self.lock.withLock { self.presence }
            lockLog("[LOCK] timer FIRED eff=\(String(format: "%.1f", nowEff)) threshold=\(Int(nowThreshold)) presence=\(nowPresence) lockOnIdle=\(lockOnIdle) inputActive=\(self.isUserInputActive) effAboveThreshold=\(nowEff >= nowThreshold)")
            if nowEff >= nowThreshold {
                lockLog("[LOCK] timer fired but signal recovered (eff=\(String(format: "%.1f", nowEff)) >= threshold=\(Int(nowThreshold))), skipping lock")
                self.lock.withLock { self.proximityTimer = nil }
                return
            }
            if lockOnIdle && self.isUserInputActive {
                lockLog("[LOCK] timer fired but input active, deferring lock")
                Log.sm.debug("[SM] input active at lock timer fire, deferring")
                self.lock.withLock {
                    self.proximityTimer = nil
                    self.lastReceiveTime = Date()
                    self.pipeline.decayBaseline = Date()
                }
                return
            }
            if self.isWithinLockGracePeriod() {
                lockLog("[LOCK] timer fired but within unlock grace period, skipping lock")
                self.lock.withLock { self.proximityTimer = nil }
                return
            }
            Log.sm.debug("Device is away")
            // P1: 记录锁定事件
            SignalDataStore.shared.record(
                rawRSSI: -100, kalmanEstimate: -100,
                effectiveRSSI: -100, slope: 0, isAnomalous: false,
                event: "locked")
            self.lock.withLock { self.presence = false }
            self.cancelHeartbeat()
            Task { @MainActor [weak self] in
                self?.delegate?.updatePresence(presence: false, reason: "away")
            }
            self.lock.withLock { self.proximityTimer = nil }
        })
        lock.withLock { proximityTimer = timer }
        RunLoop.main.add(timer, forMode: .common)
    }

    func updateMonitoredPeripheral(_ rssi: Int) {
        let now = Date()
        let source: SignalSource = (activeModeTimer != nil) ? .connected : .scanning

        // 1. 信号处理（纯计算）
        let decision = processSignal(rssi: rssi, source: source, now: now)

        // 调试日志：追踪 effectiveRSSI 计算
        let isActive = lock.withLock { activeModeTimer != nil }
        throttledBleLog("updateMonitored", interval: 1.0, "[DEBUG] updateMonitored rssi=\(rssi) effectiveRSSI=\(String(format: "%.1f", decision.effectiveRSSI)) kalman=\(String(format: "%.1f", decision.kalmanEstimate)) source=\(source == .connected ? "connected" : "scanning") activeMode=\(isActive)")

        // 2. 更新 displayRSSI
        updateDisplayRSSI(rssi: rssi)

        // 3. 在场检测（基于原始 RSSI 快速解锁）
        checkProximity(rssi: rssi, effectiveRSSI: decision.effectiveRSSI)

        // 4. 锁定决策（基于 effectiveRSSI）
        applyLockTimer(rssi: rssi, effectiveRSSI: decision.effectiveRSSI)

        // 5. 心跳 + 信号超时
        ensureHeartbeat()
        resetSignalTimer()
    }

    // MARK: - updateMonitoredPeripheral 拆分方法

    private func processSignal(rssi: Int, source: SignalSource, now: Date) -> SignalDecision {
        let decision: SignalDecision = lock.withLock {
            // P1 #5 修复：先追加当前 RSSI 再计算，确保斜率包含当前点
            pipeline.latestRSSIs.append(Double(rssi))
            pipeline.rssiTimestamps.append(now)
            let cutoff = now.addingTimeInterval(-pipeline.windowDuration)
            while let first = pipeline.rssiTimestamps.first, first < cutoff {
                pipeline.rssiTimestamps.removeFirst()
                pipeline.latestRSSIs.removeFirst()
            }

            let d = pipeline.process(rssi: rssi, source: source, now: now)

            lastReceiveTime = now
            effectiveRSSI = d.effectiveRSSI
            lastSignalAnomalous = d.isAnomalous
            return d
        }

        // EMA 平滑 RSSI：用于阶梯唤醒阈值判断
        smoothedRSSI(rssi)

        // P1: 采集信号样本到数据仓库（低开销，仅追加到环形缓冲）
        SignalDataStore.shared.record(
            rawRSSI: Double(rssi),
            kalmanEstimate: decision.kalmanEstimate,
            effectiveRSSI: decision.effectiveRSSI,
            slope: decision.slope,
            isAnomalous: decision.isAnomalous
        )

        return decision
    }

    private func updateDisplayRSSI(rssi: Int) {
        lock.withLock {
            displayRSSI = 0.1 * Double(rssi) + 0.9 * displayRSSI
        }
    }

    /// EMA 信号平滑：返回指数移动平均 RSSI，用于阶梯唤醒阈值判断
    /// - Parameter rssi: 原始 RSSI 采样值（dBm，负数）
    /// - Returns: 平滑后的 RSSI（dBm）
    @discardableResult
    func smoothedRSSI(_ rssi: Int) -> Double {
        lock.withLock {
            let measurement = Double(rssi)
            smoothedRSSIValue = smoothedRSSIAlpha * measurement + (1 - smoothedRSSIAlpha) * smoothedRSSIValue
            return smoothedRSSIValue
        }
    }

    /// 重置 EMA 平滑 RSSI 到初始值（解绑设备时调用）
    func resetSmoothedRSSI() {
        lock.withLock {
            smoothedRSSIValue = -100.0
        }
    }

    private func checkProximity(rssi: Int, effectiveRSSI: Double) {
        // 用 effectiveRSSI（与 applyLockTimer 同源）判断解锁，避免原始 RSSI 尖峰导致振荡
        let decision = SignalHysteresisEngine.checkProximity(
            rssi: Double(rssi), effectiveRSSI: effectiveRSSI,
            unlockRSSI: unlockRSSI, lockRSSI: lockRSSI)
        var shouldNotifyClose = false

        // 调试日志：追踪 presence 判断条件
        let debugInfo: (isMonitored: Bool, presence: Bool, uuidCount: Int) = lock.withLock {
            (monitoredUUID != nil, presence, monitoredUUIDs.count)
        }
        throttledBleLog("checkProximity", interval: 1.0, "[DEBUG] checkProximity rssi=\(rssi) effectiveRSSI=\(String(format: "%.1f", effectiveRSSI)) threshold=\(decision.unlockThreshold) monitored=\(debugInfo.isMonitored) presence=\(debugInfo.presence) uuidCount=\(debugInfo.uuidCount)")

        let dispRSSI: Double = lock.withLock {
            let disp = displayRSSI
            let wasPresent = presence
            if decision.isClose && !wasPresent {
                Log.sm.debug("Device is close (eff=\(String(format: "%.1f", effectiveRSSI)))")
                presence = true
                shouldNotifyClose = true
                lastProximityEventTime = Date()
                pipeline.latestRSSIs.removeAll()
                pipeline.rssiTimestamps.removeAll()
            }
            return disp
        }
        let activeMode = lock.withLock { activeModeTimer != nil }

        if decision.isClose {
            if shouldNotifyClose {
                // P1: 记录解锁事件
                SignalDataStore.shared.record(
                    rawRSSI: Double(rssi), kalmanEstimate: effectiveRSSI,
                    effectiveRSSI: effectiveRSSI, slope: 0, isAnomalous: false,
                    event: "unlocked")
                Task { @MainActor [weak self] in
                    self?.delegate?.updatePresence(presence: true, reason: "close")
                }
            }
            Task { @MainActor [weak self] in
                self?.delegate?.updateRSSI(rssi: Int(dispRSSI), active: activeMode)
                self?.delegate?.onDeviceApproached()
            }
        } else {
            Task { @MainActor [weak self] in
                self?.delegate?.updateRSSI(rssi: Int(dispRSSI), active: activeMode)
            }
        }
    }

    private func applyLockTimer(rssi: Int, effectiveRSSI: Double) {
        let decision = SignalHysteresisEngine.checkProximity(
            rssi: Double(rssi), effectiveRSSI: effectiveRSSI,
            unlockRSSI: unlockRSSI, lockRSSI: lockRSSI)
        let threshold = Double(decision.lockThreshold)
        if !decision.isAway {
            lock.withLock {
                proximityTimer?.invalidate()
                proximityTimer = nil
            }
        } else {
            let (curPresence, curTimer) = lock.withLock { (presence, proximityTimer) }
            lockLog("[LOCK] applyLockTimer eff=\(String(format: "%.1f", effectiveRSSI)) threshold=\(Int(threshold)) presence=\(curPresence) hasTimer=\(curTimer != nil)")
            if curPresence && curTimer == nil {
                // 冷静期：刚解锁后不立即触发锁定，防止 effectiveRSSI 衰减导致振荡
                let lastUnlock = lastProximityEventTime
                let now = Date()
                let elapsed = now.timeIntervalSince(lastUnlock)
                lockLog("[LOCK] graceElapsed=\(String(format: "%.1f", elapsed))s gracePeriod=\(self.proximityGracePeriod)s")
                if SignalHysteresisEngine.isWithinLockGracePeriod(
                    lastUnlockTime: lastUnlock,
                    gracePeriod: self.proximityGracePeriod, now: now) {
                    lockLog("[LOCK] BLOCKED by proximityGracePeriod")
                    Log.sm.debug("[SM] grace period \(String(format: "%.1f", elapsed))s < \(self.proximityGracePeriod)s, deferring lock")
                    return
                }
                let lockOnIdle = ConfigStore.shared.object(forKey: "lockOnIdle") == nil
                    || ConfigStore.shared.bool(forKey: "lockOnIdle")
                if lockOnIdle && isUserInputActive {
                    lockLog("[LOCK] BLOCKED by isUserInputActive (lockOnIdle=\(lockOnIdle) inputActive=\(isUserInputActive))")
                    Log.sm.debug("[SM] input active, rejecting lock signal + resetting decay")
                    lock.withLock {
                        lastReceiveTime = Date()
                        pipeline.decayBaseline = Date()
                    }
                } else {
                    lockLog("[LOCK] all guards passed -> startLockTimer")
                    startLockTimer()
                }
            } else {
                lockLog("[LOCK] SKIPPED: presence=\(curPresence) hasTimer=\(curTimer != nil)")
            }
        }
    }

    func resetScanTimer(device: Device) {
        scanner.resetScanTimer(device: device, timeout: signalTimeout)
    }

    func connectMonitoredPeripheral() {
        scanner.connectMonitoredPeripheral()
    }


    override init() {
        super.init()
        let btAuth = CBManager.authorization
        logDebug(component: "FUn", "[DIAG] FUn.init() - initializing BLEScanner, bluetooth authorization=\(btAuth.rawValue)")
        scanner = BLEScanner(queue: bleQueue, lock: lock, host: self)
    }
}

// MARK: - BLEScannerHost

extension FUn {
    func scanner(_ scanner: BLEScanner, didSampleMonitoredRSSI rssi: Int) {
        updateMonitoredPeripheral(rssi)
    }

    func scannerDidDisconnectMonitored(_ scanner: BLEScanner) {
        signalLostCount = 0
    }

    func scannerDidPowerOn(_ scanner: BLEScanner) {
        powerWarn = false
    }

    func scannerDidPowerOff(_ scanner: BLEScanner) {
        invalidateAllTimers()
        let shouldWarn: Bool = lock.withLock {
            presence = false
            let w = powerWarn
            powerWarn = false
            return w
        }
        if shouldWarn {
            Task { @MainActor [weak self] in
                self?.delegate?.bluetoothPowerWarn()
            }
        }
    }

    func scannerPollingContext(_ scanner: BLEScanner) -> BLEScanner.PollingContext {
        let (k, near) = lock.withLock {
            (pipeline.kalmanEstimate, SignalHysteresisEngine.isNearThreshold(effectiveRSSI, threshold: Double(unlockRSSI)))
        }
        return BLEScanner.PollingContext(kalman: k, nearThreshold: near)
    }

    func scannerDeviceScanTimeout(_ scanner: BLEScanner) -> TimeInterval {
        signalTimeout
    }

    var bleDelegate: FUnDelegate? {
        delegate
    }
}
