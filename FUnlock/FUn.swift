import Foundation
import CoreBluetooth
import Combine
import os

/// 锁屏调试日志：写入文件（GUI 应用 print 被丢弃）
func lockLog(_ msg: String) {
    let path = "/tmp/funlock_lock.log"
    let line = "\(Date()): \(msg)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

let DeviceInformation = CBUUID(string:"180A")
let ManufacturerName = CBUUID(string:"2A29")
let ModelName = CBUUID(string:"2A24")
let ExposureNotification = CBUUID(string:"FD6F")

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

func getMACFromUUID(_ uuid: String) -> String? {
    guard let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist") else { return nil }
    guard let cbcache = plist["CoreBluetoothCache"] as? NSDictionary else { return nil }
    guard let device = cbcache[uuid] as? NSDictionary else { return nil }
    return device["DeviceAddress"] as? String
}

func getNameFromMAC(_ mac: String) -> String? {
    guard let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist") else { return nil }
    guard let devcache = plist["DeviceCache"] as? NSDictionary else { return nil }
    guard let device = devcache[mac] as? NSDictionary else { return nil }
    if let name = device["Name"] as? String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed == "" { return nil }
        return trimmed
    }
    return nil
}

class Device: NSObject {
    let uuid : UUID!
    var peripheral : CBPeripheral?
    var manufacture : String?
    var model : String?
    var advData: Data?
    var rssi: Int = 0
    var scanTimer: Timer?
    var macAddr: String?
    var blName: String?
    
    override var description: String {
        get {
            if let name = blName {
                if name != "iPhone" && name != "iPad" {
                    return name
                }
            }
            if let manu = manufacture {
                if let mod = model {
                    if manu == "Apple Inc." && appleDeviceNames[mod] != nil {
                        return appleDeviceNames[mod]!
                    }
                    return String(format: "%@/%@", manu, mod)
                } else {
                    return manu
                }
            }
            if let name = peripheral?.name {
                if name.trimmingCharacters(in: .whitespaces).count != 0 {
                    return name
                }
            }
            if let mod = model {
                return mod
            }
            // iBeacon
            if let adv = advData {
                if adv.count >= 25 {
                    var iBeaconPrefix : [uint16] = [0x004c, 0x01502]
                    if adv[0...3] == Data(bytes: &iBeaconPrefix, count: 4) {
                        let major = uint16(adv[20]) << 8 | uint16(adv[21])
                        let minor = uint16(adv[22]) << 8 | uint16(adv[23])
                        let tx = Int8(bitPattern: adv[24])
                        let distance = pow(10, Double(Int(tx) - rssi)/20.0)
                        let d = String(format:"%.1f", distance)
                        return "iBeacon [\(major), \(minor)] \(d)m"
                    }
                }
            }
            if let name = blName {
                return name
            }
            if let mac = macAddr {
                return mac
            }
            return uuid.description
        }
    }

    init(uuid _uuid: UUID) {
        uuid = _uuid
    }
}

protocol FUnDelegate {
    func newDevice(device: Device)
    func updateDevice(device: Device)
    func removeDevice(device: Device)
    func updateRSSI(rssi: Int?, active: Bool)
    func updatePresence(presence: Bool, reason: String)
    func bluetoothPowerWarn()
    func onDeviceApproached()
}

class FUn: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let UNLOCK_DISABLED = 1
    let LOCK_DISABLED = -100
    let bleQueue = DispatchQueue(label: "com.funlock.ble")
    private let lock = UnfairLock()
    var centralMgr : CBCentralManager!
    var devices : [UUID : Device] = [:]
    var delegate: FUnDelegate?
    var inputMonitor: InputActivityMonitor?

    /// 用户是否有输入活动（nil-safe，线程安全）
    private var isUserInputActive: Bool {
        inputMonitor?.isActive == true
    }

    var scanMode = false
    var monitoredUUID: UUID?
    var monitoredUUIDs: Set<UUID> = []
    var monitoredPeripheral: CBPeripheral?
    var proximityTimer : Timer?
    var signalTimer: Timer?
    var presence = false
    @Published var lockRSSI = -80
    @Published var unlockRSSI = -60
    var proximityTimeout = 5.0
    var signalTimeout = 60.0
    var lastReadAt = 0.0
    var powerWarn = true
    var passiveMode = false
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
    static let defaultWakeAdvance = 20
    /// 默认预解锁触发量（dB）
    static let defaultPreUnlockTrigger = 10
    /// 偏移量允许范围（dB）
    static let offsetRange = 0...20
    /// 将偏移量钳制到允许范围（UI 可能输入越界值）
    static func clampOffset(_ value: Int) -> Int {
        min(max(value, offsetRange.lowerBound), offsetRange.upperBound)
    }
    /// 读取偏移设置，越界/缺失时回退默认值
    private static func offsetSetting(_ key: String, default dft: Int) -> Int {
        let value = UserDefaults.standard.object(forKey: key) as? Int ?? dft
        return clampOffset(value)
    }
    /// 预备唤醒阈值（dBm）：解锁阈值往更远方向提前 wakeAdvance（UI 可填，默认 20）
    var preWakeThreshold: Int {
        guard unlockRSSI != UNLOCK_DISABLED else { return unlockRSSI }
        let advance = Self.offsetSetting("wakeAdvance", default: Self.defaultWakeAdvance)
        return unlockRSSI - advance
    }
    /// 预解锁触发阈值（dBm）：解锁阈值往更远方向提前 preUnlockTrigger（UI 可填，默认 10），
    /// 信号进入该接近窗口时启用 0.5s 快速轮询（开足马力探测）；不再直接触发解锁，
    /// 真正解锁由信号达到 unlockRSSI 决定
    var unlockStairThreshold: Int {
        guard unlockRSSI != UNLOCK_DISABLED else { return unlockRSSI }
        let trigger = Self.offsetSetting("preUnlockTrigger", default: Self.defaultPreUnlockTrigger)
        return unlockRSSI - trigger
    }
    var lastReceiveTime: Date = Date()
    var lastSignalAnomalous: Bool = false
    // Heartbeat timer (独立状态机，不在管道内)
    var heartbeatTimer: Timer?
    var heartbeatInterval: TimeInterval = 2.0
    private var lastHeartbeatInterval: TimeInterval = 2.0
    var activeModeTimer : Timer? = nil
    var connectionTimer : Timer? = nil
    var stableCount: Int = 0
    var activePollInterval: TimeInterval = 2.0
    var lastEstimatedRSSI: Int = 0
    var signalLostCount: Int = 0
    // 节流：非监控设备的 UI 刷新时间戳
    private var lastUIUpdateTime: [UUID: Date] = [:]
    private let uiThrottleInterval: TimeInterval = 1.0
    // 跟踪当前扫描的 AllowDuplicates 状态，避免重复启动
    private var currentScanAllowDuplicates: Bool = false
    // 冷静期：解锁后短时间内不触发锁定，防止振荡
    private var lastProximityEventTime: Date = .distantPast
    private let proximityGracePeriod: TimeInterval = 5.0

    func scanForPeripherals() {
        // 优化：根据当前模式动态决定 AllowDuplicates
        let allowDuplicates: Bool
        let hasMonitor: Bool = lock.withLock { monitoredUUID != nil }
        if !hasMonitor {
            // 未绑定设备，只需发现列表，不需要重复广播
            allowDuplicates = false
        } else if lock.withLock({ passiveMode }) {
            // 被动模式：靠扫描回调获取 RSSI，需要重复
            allowDuplicates = true
        } else {
            // 主动模式 + 有目标：靠 readRSSI 轮询，不需要重复
            allowDuplicates = false
        }
        // 参数没变且正在扫描，跳过重启
        if centralMgr.isScanning && currentScanAllowDuplicates == allowDuplicates {
            return
        }
        // 参数变了，需要先停再启
        if centralMgr.isScanning {
            centralMgr.stopScan()
        }
        currentScanAllowDuplicates = allowDuplicates
        let options: [String: Any] = allowDuplicates
            ? [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            : [:]
        centralMgr.scanForPeripherals(withServices: nil, options: options)
        //Log.sm.debug("Start scanning (allowDuplicates=\(allowDuplicates))")
    }

    func startScanning() {
        scanMode = true
        scanForPeripherals()
    }

    func stopScanning() {
        scanMode = false
        centralMgr.stopScan()
        currentScanAllowDuplicates = false
    }

    func setPassiveMode(_ mode: Bool) {
        let peripheralToCancel: CBPeripheral? = lock.withLock {
            passiveMode = mode
            if passiveMode {
                activeModeTimer?.invalidate()
                activeModeTimer = nil
            }
            return passiveMode ? monitoredPeripheral : nil
        }

        if let p = peripheralToCancel {
            centralMgr.cancelPeripheralConnection(p)
        }
        scanForPeripherals()
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
                let lockOnIdle = UserDefaults.standard.object(forKey: "lockOnIdle") == nil
                    || UserDefaults.standard.bool(forKey: "lockOnIdle")
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
        self.delegate?.updateRSSI(rssi: nil, active: false)
        if wasPresent {
            // P1: 记录信号丢失锁定事件
            SignalDataStore.shared.record(
                rawRSSI: -100, kalmanEstimate: -100,
                effectiveRSSI: -100, slope: 0, isAnomalous: false,
                event: "locked: lost")
            self.delegate?.updatePresence(presence: false, reason: "lost")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("[BLE] Bluetooth powered on - starting scan")
            Log.ble.debug("Bluetooth powered on")
            if activeModeTimer == nil {
                scanForPeripherals()
            }
            powerWarn = false
        case .poweredOff:
            print("[BLE] Bluetooth powered off")
            Log.ble.debug("Bluetooth powered off")
            invalidateAllTimers()
            let shouldWarn: Bool = lock.withLock {
                presence = false
                let w = powerWarn
                powerWarn = false
                return w
            }
            if shouldWarn {
                DispatchQueue.main.async {
                    self.delegate?.bluetoothPowerWarn()
                }
            }
        default:
            break
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
        let lockTh = Double(lockRSSI == LOCK_DISABLED ? unlockRSSI : lockRSSI) + 10.0
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
            let threshold = Double(self.lockRSSI == self.LOCK_DISABLED ? self.unlockRSSI : self.lockRSSI)
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
        return now.timeIntervalSince(last) < proximityGracePeriod
    }

    func invalidateAllTimers() {
        lock.withLock {
            signalTimer?.invalidate()
            signalTimer = nil
            proximityTimer?.invalidate()
            proximityTimer = nil
            activeModeTimer?.invalidate()
            activeModeTimer = nil
            connectionTimer?.invalidate()
            connectionTimer = nil
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
        }
    }

    // MARK: - Lock timer (shared by updateMonitoredPeripheral and heartbeat)
    /// 方案 C：按下降斜率计算锁屏超时 —— 陡降（slope ≤ -fastSlopeThreshold）→ fastLockTimeout；
    /// 缓降/平稳（slope ≥ -mildSlopeThreshold）→ base；中间线性插值
    static func lockTimeout(slope: Double, base: TimeInterval = 5.0) -> TimeInterval {
        if slope <= -fastSlopeThreshold {
            return fastLockTimeout
        } else if slope >= -mildSlopeThreshold {
            return base
        } else {
            let t = (-slope - mildSlopeThreshold) / (fastSlopeThreshold - mildSlopeThreshold)
            return fastLockTimeout + (base - fastLockTimeout) * t
        }
    }

    /// 方案 A：信号是否处于接近窗口（有效信号进入 [threshold-window, threshold)）
    static func isNearThreshold(_ effectiveRSSI: Double, threshold: Double) -> Bool {
        effectiveRSSI >= threshold - proximityPollWindow && effectiveRSSI < threshold
    }

    private func startLockTimer() {
        // 方案 C：锁屏超时随下降斜率自适应
        let slope = lock.withLock { pipeline.smoothedSlope }
        let timeout = Self.lockTimeout(slope: slope, base: proximityTimeout)
        let timer = Timer(timeInterval: timeout, repeats: false, block: { [weak self] _ in
            guard let self = self else { return }
            let lockOnIdle = UserDefaults.standard.object(forKey: "lockOnIdle") == nil
                || UserDefaults.standard.bool(forKey: "lockOnIdle")
            let nowEff = self.getEffectiveRSSI()
            let nowThreshold = Double(self.lockRSSI == self.LOCK_DISABLED ? self.unlockRSSI : self.lockRSSI)
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
            DispatchQueue.main.async {
                self.delegate?.updatePresence(presence: false, reason: "away")
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
        Log.ble.debug("[DEBUG] updateMonitored rssi=\(rssi) effectiveRSSI=\(String(format: "%.1f", decision.effectiveRSSI)) kalman=\(String(format: "%.1f", decision.kalmanEstimate)) source=\(source == .connected ? "connected" : "scanning") activeMode=\(isActive)")

        // 2. 更新 displayRSSI
        updateDisplayRSSI(rssi: rssi)

        // 3. 在场检测（基于原始 RSSI 快速解锁）
        checkProximity(rssi: rssi, effectiveRSSI: decision.effectiveRSSI)

        // 4. 锁定决策（基于 effectiveRSSI）
        applyLockTimer(effectiveRSSI: decision.effectiveRSSI)

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
        let unlockThreshold = unlockRSSI == UNLOCK_DISABLED ? lockRSSI : unlockRSSI
        // 用 effectiveRSSI（与 applyLockTimer 同源）判断解锁，避免原始 RSSI 尖峰导致振荡
        let signal = effectiveRSSI
        var shouldNotifyClose = false

        // 调试日志：追踪 presence 判断条件
        let debugInfo: (isMonitored: Bool, presence: Bool, uuidCount: Int) = lock.withLock {
            (monitoredUUID != nil, presence, monitoredUUIDs.count)
        }
        print("[BLE] checkProximity rssi=\(rssi) effectiveRSSI=\(String(format: "%.1f", signal)) threshold=\(unlockThreshold) presence=\(debugInfo.presence)")
        Log.ble.debug("[DEBUG] checkProximity rssi=\(rssi) effectiveRSSI=\(String(format: "%.1f", signal)) threshold=\(unlockThreshold) monitored=\(debugInfo.isMonitored) presence=\(debugInfo.presence) uuidCount=\(debugInfo.uuidCount)")

        let dispRSSI: Double = lock.withLock {
            let disp = displayRSSI
            let wasPresent = presence
            if signal >= Double(unlockThreshold) && !wasPresent {
                Log.sm.debug("Device is close (eff=\(String(format: "%.1f", signal)))")
                presence = true
                shouldNotifyClose = true
                lastProximityEventTime = Date()
                pipeline.latestRSSIs.removeAll()
                pipeline.rssiTimestamps.removeAll()
            }
            return disp
        }

        if signal >= Double(unlockThreshold) {
            if shouldNotifyClose {
                // P1: 记录解锁事件
                SignalDataStore.shared.record(
                    rawRSSI: Double(rssi), kalmanEstimate: effectiveRSSI,
                    effectiveRSSI: effectiveRSSI, slope: 0, isAnomalous: false,
                    event: "unlocked")
                DispatchQueue.main.async {
                    self.delegate?.updatePresence(presence: true, reason: "close")
                }
            }
            DispatchQueue.main.async {
                self.delegate?.updateRSSI(rssi: Int(dispRSSI), active: self.activeModeTimer != nil)
                self.delegate?.onDeviceApproached()
            }
        } else {
            DispatchQueue.main.async {
                self.delegate?.updateRSSI(rssi: Int(dispRSSI), active: self.activeModeTimer != nil)
            }
        }
    }

    private func applyLockTimer(effectiveRSSI: Double) {
        let threshold = Double(lockRSSI == LOCK_DISABLED ? unlockRSSI : lockRSSI)
        if effectiveRSSI >= threshold {
            lock.withLock {
                proximityTimer?.invalidate()
                proximityTimer = nil
            }
        } else {
            let (curPresence, curTimer) = lock.withLock { (presence, proximityTimer) }
            lockLog("[LOCK] applyLockTimer eff=\(String(format: "%.1f", effectiveRSSI)) threshold=\(Int(threshold)) presence=\(curPresence) hasTimer=\(curTimer != nil)")
            if curPresence && curTimer == nil {
                // 冷静期：刚解锁后不立即触发锁定，防止 effectiveRSSI 衰减导致振荡
                let elapsed = Date().timeIntervalSince(lastProximityEventTime)
                lockLog("[LOCK] graceElapsed=\(String(format: "%.1f", elapsed))s gracePeriod=\(self.proximityGracePeriod)s")
                if elapsed < self.proximityGracePeriod {
                    lockLog("[LOCK] BLOCKED by proximityGracePeriod")
                    Log.sm.debug("[SM] grace period \(String(format: "%.1f", elapsed))s < \(self.proximityGracePeriod)s, deferring lock")
                    return
                }
                let lockOnIdle = UserDefaults.standard.object(forKey: "lockOnIdle") == nil
                    || UserDefaults.standard.bool(forKey: "lockOnIdle")
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
        device.scanTimer?.invalidate()
        guard let uuid = device.uuid else { return }
        let timer = Timer(timeInterval: signalTimeout, repeats: false, block: { [weak self] _ in
            DispatchQueue.main.async {
                self?.delegate?.removeDevice(device: device)
            }
            if let p = device.peripheral {
                self?.centralMgr.cancelPeripheralConnection(p)
            }
            self?.devices.removeValue(forKey: uuid)
            // 防泄漏：设备过期时清理节流记录
            self?.lastUIUpdateTime.removeValue(forKey: uuid)
        })
        RunLoop.main.add(timer, forMode: .common)
        device.scanTimer = timer
    }

    func connectMonitoredPeripheral() {
        guard let p = monitoredPeripheral else { return }

        // Idk why but this works like a charm when 'didConnect' won't get called.
        // However, this generates warnings in the log.
        p.readRSSI()

        guard p.state == .disconnected else { return }
        Log.ble.debug("Connecting")
        centralMgr.connect(p, options: nil)
        connectionTimer?.invalidate()
        let connTimer = Timer(timeInterval: 60, repeats: false, block: { [weak self] _ in
            if p.state == .connecting {
                Log.ble.debug("Connection timeout")
                self?.centralMgr.cancelPeripheralConnection(p)
            }
        })
        RunLoop.main.add(connTimer, forMode: .common)
        lock.withLock { connectionTimer = connTimer }
    }

    private func restartActiveModeTimer(peripheral: CBPeripheral) {
        let pollInterval: TimeInterval = lock.withLock {
            activeModeTimer?.invalidate()
            return activePollInterval
        }

        let timer = Timer(timeInterval: pollInterval, repeats: true, block: { [weak self] _ in
            guard let self = self else { return }
            let lastRead = self.lock.withLock { self.lastReadAt }
            if Date().timeIntervalSince1970 > lastRead + 10 {
                Log.ble.debug("Falling back to passive mode")
                self.centralMgr.cancelPeripheralConnection(peripheral)
                self.lock.withLock {
                    self.activeModeTimer?.invalidate()
                    self.activeModeTimer = nil
                }
                self.scanForPeripherals()
            } else if peripheral.state == .connected {
                peripheral.readRSSI()
            } else {
                self.connectMonitoredPeripheral()
            }
        })
        RunLoop.main.add(timer, forMode: .common)
        lock.withLock { activeModeTimer = timer }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber)
    {
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue

        // 调试日志：追踪设备发现
        let monitorInfo: (monitoredUUID: UUID?, uuidCount: Int) = lock.withLock {
            (monitoredUUID, monitoredUUIDs.count)
        }
        let isInList = monitoredUUIDs.contains(peripheral.identifier)
        print("[BLE] didDiscover \(peripheral.name ?? "unknown") rssi=\(rssi) inList=\(isInList) uuidCount=\(monitorInfo.uuidCount)")
        Log.ble.debug("[DEBUG] didDiscover \(peripheral.name ?? "unknown") rssi=\(rssi) inList=\(isInList) monitoredUUID=\(monitorInfo.monitoredUUID != nil ? "set" : "nil") uuidCount=\(monitorInfo.uuidCount)")

        if monitoredUUIDs.contains(peripheral.identifier) {
            let isMonitored: Bool = lock.withLock {
                let match = peripheral.identifier == monitoredUUID
                if match && monitoredPeripheral == nil {
                    monitoredPeripheral = peripheral
                }
                return match
            }
            if isMonitored {
                // 扫描回调：更新 presence 和锁定判断
                updateMonitoredPeripheral(rssi)
                let shouldConnect: Bool = lock.withLock { activeModeTimer == nil && !passiveMode }
                if shouldConnect {
                    connectMonitoredPeripheral()
                }
            }
        }

        // 优化 1：监控模式下，非目标设备直接丢弃
        let hasMonitor: Bool = lock.withLock { monitoredUUID != nil }
        if hasMonitor && !monitoredUUIDs.contains(peripheral.identifier) {
            return
        }

        if (scanMode) {
            if let uuids = advertisementData["kCBAdvDataServiceUUIDs"] as? [CBUUID] {
                for uuid in uuids {
                    if uuid == ExposureNotification {
                        //Log.sm.debug("Device \(peripheral.identifier) Exposure Notification")
                        return
                    }
                }
            }
            let dev = devices[peripheral.identifier]
            var device: Device
            if (dev == nil) {
                device = Device(uuid: peripheral.identifier)
                if (rssi >= thresholdRSSI) {
                    device.peripheral = peripheral
                    device.rssi = rssi
                    device.advData = advertisementData["kCBAdvDataManufacturerData"] as? Data
                    if let info = getLEDeviceInfoFromUUID(peripheral.identifier.description) {
                        device.blName = info.name
                        device.macAddr = info.macAddr
                    }
                    if device.macAddr == nil {
                        device.macAddr = getMACFromUUID(peripheral.identifier.description)
                    }
                    if let mac = device.macAddr, device.blName == nil {
                        device.blName = getNameFromMAC(mac)
                    }
                    devices[peripheral.identifier] = device
                    central.connect(peripheral, options: nil)
                    DispatchQueue.main.async {
                        self.delegate?.newDevice(device: device)
                    }
                }
            } else {
                device = dev!
                device.rssi = rssi
                // 优化 3：非监控设备 UI 刷新节流（1 秒 1 次）
                let now = Date()
                // 防泄漏：字典超限时清空（丢弃节流记录的代价仅是一次多余 UI 刷新）
                if lastUIUpdateTime.count > 200 {
                    lastUIUpdateTime.removeAll()
                }
                if let lastUpdate = lastUIUpdateTime[peripheral.identifier],
                   now.timeIntervalSince(lastUpdate) < uiThrottleInterval {
                    // 节流窗口内，只更新数据不派发 UI
                } else {
                    lastUIUpdateTime[peripheral.identifier] = now
                    DispatchQueue.main.async {
                        self.delegate?.updateDevice(device: device)
                    }
                }
            }
            resetScanTimer(device: device)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral)
    {
        peripheral.delegate = self
        if scanMode {
            peripheral.discoverServices([DeviceInformation])
        }
        let shouldActivate: Bool = lock.withLock {
            peripheral == monitoredPeripheral && !passiveMode
        }
        if shouldActivate {
            Log.ble.debug("Connected")
            lock.withLock {
                connectionTimer?.invalidate()
                connectionTimer = nil
            }
            // 优化 4：主动模式已连接，停掉全局扫描
            centralMgr.stopScan()
            peripheral.readRSSI()
        }
    }

    //MARK:CBCentralManagerDelegate end -

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Log.ble.debug("didDisconnectPeripheral: \(peripheral.identifier)")
        if peripheral == monitoredPeripheral {
            // 只取消主动模式定时器，保留心跳和信号超时链用于检测离场
            lock.withLock {
                activeModeTimer?.invalidate()
                activeModeTimer = nil
                connectionTimer?.invalidate()
                connectionTimer = nil
                signalLostCount = 0
            }
            // 不立即锁屏 — BLE 连接可能因干扰短暂断开
            // 由心跳衰减机制判断：设备真正离开后 ~10 秒锁屏
            // 恢复扫描，尝试重新发现设备
            scanForPeripherals()
        }
    }

    //MARK:- CBPeripheralDelegate start

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let shouldProcess: Bool = lock.withLock {
            guard peripheral.identifier == monitoredUUID else { return false }
            if monitoredPeripheral == nil { monitoredPeripheral = peripheral }
            return true
        }
        guard shouldProcess else { return }
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        updateMonitoredPeripheral(rssi)

        let now = Date().timeIntervalSince1970
        var restartPolling = false
        let kalmanNow: Double = lock.withLock {
            let k = pipeline.kalmanEstimate
            lastReadAt = now
            let fluctuation = abs(k - Double(lastEstimatedRSSI))
            lastEstimatedRSSI = Int(k)
            // 方案 A：信号接近阈值（有效信号进入 [threshold-window, threshold)）时启用快速轮询，
            // 信号一触线立刻被感知，缩短解锁/锁屏感知延迟
            // 走近方向：解锁爬升区 [stair-window, stair) 也启用快速轮询——用户从远处走回时
            // 若只按锁定阈值触发，爬升区用 8s 慢采样，会出现"走到面前等几十秒"的感知延迟
            var nearClimb = false
            if unlockRSSI != UNLOCK_DISABLED {
                nearClimb = Self.isNearThreshold(effectiveRSSI, threshold: Double(unlockStairThreshold))
            }
            let threshold = Double(lockRSSI == LOCK_DISABLED ? unlockRSSI : lockRSSI)
            let nearThreshold = nearClimb || Self.isNearThreshold(effectiveRSSI, threshold: threshold)
            if nearThreshold {
                if activePollInterval != fastPollInterval {
                    activePollInterval = fastPollInterval
                    restartPolling = true
                }
            } else {
                if fluctuation < 5 {
                    stableCount += 1
                } else {
                    stableCount = 0
                }
                if activePollInterval == fastPollInterval {
                    // 离开接近窗口：快速档回落 2s 基准
                    activePollInterval = 2.0
                    stableCount = 0
                    restartPolling = true
                } else if stableCount >= 10 && activePollInterval < 8.0 {
                    activePollInterval = 8.0
                    restartPolling = true
                } else if fluctuation >= 5 && activePollInterval > 2.0 {
                    activePollInterval = 2.0
                    stableCount = 0
                    restartPolling = true
                }
            }
            return k
        }

        if restartPolling {
            restartActiveModeTimer(peripheral: peripheral)
        }

        let shouldStartActiveMode = lock.withLock { activeModeTimer == nil && !passiveMode }
        if shouldStartActiveMode {
            Log.ble.debug("Entering active mode")
            if !scanMode {
                centralMgr.stopScan()
            }
            let pollInterval = lock.withLock { activePollInterval }
            let timer = Timer(timeInterval: pollInterval, repeats: true, block: { [weak self] _ in
                guard let self = self else { return }
                let lastRead = self.lock.withLock { self.lastReadAt }
                if Date().timeIntervalSince1970 > lastRead + 10 {
                    Log.ble.debug("Falling back to passive mode")
                    self.centralMgr.cancelPeripheralConnection(peripheral)
                    self.lock.withLock {
                        self.activeModeTimer?.invalidate()
                        self.activeModeTimer = nil
                    }
                    self.scanForPeripherals()
                } else if peripheral.state == .connected {
                    peripheral.readRSSI()
                } else {
                    self.connectMonitoredPeripheral()
                }
            })
            RunLoop.main.add(timer, forMode: .common)
            lock.withLock { activeModeTimer = timer }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        if let services = peripheral.services {
            for service in services {
                if service.uuid == DeviceInformation {
                    peripheral.discoverCharacteristics([ManufacturerName, ModelName], for: service)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?)
    {
        if let chars = service.characteristics {
            for chara in chars {
                if chara.uuid == ManufacturerName || chara.uuid == ModelName {
                    peripheral.readValue(for:chara)
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?)
    {
        if let value = characteristic.value {
            let str: String? = String(data: value, encoding: .utf8)
            if let s = str {
                if let device = devices[peripheral.identifier] {
                    if characteristic.uuid == ManufacturerName {
                        device.manufacture = s
                        DispatchQueue.main.async {
                            self.delegate?.updateDevice(device: device)
                        }
                    }
                    if characteristic.uuid == ModelName {
                        device.model = s
                        DispatchQueue.main.async {
                            self.delegate?.updateDevice(device: device)
                        }
                    }
                    if device.model != nil && device.manufacture != nil && device.peripheral != monitoredPeripheral {
                        centralMgr.cancelPeripheralConnection(peripheral)
                    }
                }
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didModifyServices invalidatedServices: [CBService])
    {
        peripheral.discoverServices([DeviceInformation])
    }
    //MARK:CBPeripheralDelegate end -

    override init() {
        super.init()
        centralMgr = CBCentralManager(delegate: self, queue: bleQueue)
    }
}
