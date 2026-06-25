import Foundation
import CoreBluetooth
import Combine
import os

// MARK: - 线程安全锁

private final class UnfairLock {
    private var _lock = os_unfair_lock()
    func lock() { os_unfair_lock_lock(&_lock) }
    func unlock() { os_unfair_lock_unlock(&_lock) }
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        let result = body()
        unlock()
        return result
    }
}

// MARK: - 信号处理管道类型

struct SignalDecision: Equatable {
    let kalmanEstimate: Double
    let effectiveRSSI: Double
    let slope: Double
    let isAnomalous: Bool
    let sourceWeight: Double
}

enum SignalSource { case scanning, connected }

// MARK: - 管道状态容器

struct SignalPipeline {
    var kalmanEstimate: Double = -60.0
    var kalmanP: Double = 1.0
    var kalmanSampleCount: Int = 0
    var smoothedSlope: Double = 0.0
    var latestRSSIs: [Double] = []
    var rssiTimestamps: [Date] = []
    let windowDuration: TimeInterval = 1.5

    // Kalman 参数
    private let kalmanQ: Double = 0.008
    private let kalmanR: Double = 0.5
    private let kalmanAlpha: Double = 0.02
    private let kalmanQMax: Double = 0.5
    private let kalmanDeadZone: Double = 2.0
    private let betaSlope: Double = 0.1
    private let gammaAnomaly: Double = 1.5

    // 衰减参数
    private let decayRate: Double = 0.5
    private let effectiveRSSIFloor: Double = -100.0
    private let slopeFactor: Double = 0.3
    private let inactivityFactor: Double = 0.05
    private let slopeSwitchThreshold: Double = 2.0

    // IQR 参数
    private let iqrMultiplier: Double = 2.0

    // EWLR 参数
    private let ewlrLambda: Double = 0.4
    private let slopeEmaAlpha: Double = 0.3

    mutating func process(rssi: Int, source: SignalSource, now: Date) -> SignalDecision {
        // S0: 源标记
        let sourceWeight: Double = source == .connected ? 1.0 : 0.7

        // S1: IQR 异常检测
        let isAnomalous = applyIQR(window: latestRSSIs, rssi: Double(rssi))

        // S2: EWLR 斜率
        let rawSlope = computeSlopeEWLR(rssis: latestRSSIs, timestamps: rssiTimestamps, now: now)
        let slope = slopeEmaAlpha * rawSlope + (1 - slopeEmaAlpha) * smoothedSlope
        smoothedSlope = slope

        // S3: Kalman
        let estimate = computeKalman(rssi: rssi, slope: slope, isAnomalous: isAnomalous)

        // S4: 自适应衰减
        // elapsed 基于 rssiTimestamps.last（上一次 BLE 样本时间），新样本尚未 append
        let elapsed = now.timeIntervalSince(rssiTimestamps.last ?? now)
        let adaptiveRate: Double
        if abs(slope) > slopeSwitchThreshold {
            adaptiveRate = decayRate * (1 + slopeFactor * abs(slope))
        } else {
            adaptiveRate = decayRate / (1 + inactivityFactor * max(elapsed, 0))
        }
        let penalty = adaptiveRate * elapsed
        let effective = max(estimate - penalty, effectiveRSSIFloor)

        return SignalDecision(
            kalmanEstimate: estimate,
            effectiveRSSI: effective,
            slope: slope,
            isAnomalous: isAnomalous,
            sourceWeight: sourceWeight
        )
    }

    private func applyIQR(window: [Double], rssi: Double) -> Bool {
        guard window.count >= 5 else { return false }
        let sorted = window.sorted()
        let n = sorted.count
        let q1 = sorted[n / 4]
        let q3 = sorted[3 * n / 4]
        let iqr = q3 - q1
        return abs(rssi - (q1 + q3) / 2.0) > iqrMultiplier * iqr
    }

    private func computeSlopeEWLR(rssis: [Double], timestamps: [Date], now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-windowDuration)
        var sumW: Double = 0
        var sumWT: Double = 0
        var sumWR: Double = 0
        var sumWTR: Double = 0
        var sumWT2: Double = 0
        for i in rssis.indices {
            let t = timestamps[i]
            guard t >= cutoff else { continue }
            let dt = now.timeIntervalSince(t)
            let w = exp(-ewlrLambda * dt)
            let r = rssis[i]
            sumW += w
            sumWT += w * dt
            sumWR += w * r
            sumWTR += w * dt * r
            sumWT2 += w * dt * dt
        }
        guard sumW > 1 else { return 0 }
        let denom = sumW * sumWT2 - sumWT * sumWT
        guard abs(denom) > 1e-6 else { return 0 }
        let slope = -(sumW * sumWTR - sumWT * sumWR) / denom
        return max(min(slope, 30), -30)
    }

    private mutating func computeKalman(rssi: Int, slope: Double, isAnomalous: Bool) -> Double {
        let measurement = Double(rssi)
        let delta = measurement - kalmanEstimate
        var q = kalmanQ
        kalmanSampleCount += 1
        if kalmanSampleCount > 5 && abs(delta) > kalmanDeadZone {
            if delta > 0 {
                let baseTerm = 1.0 + kalmanAlpha * pow(abs(delta), 1.5)
                let slopeTerm = slope > 0 ? betaSlope * slope : 0.0
                let anomTerm = isAnomalous ? gammaAnomaly : 0
                q = kalmanQ * (baseTerm + slopeTerm + anomTerm)
            } else {
                let anomTerm = isAnomalous ? gammaAnomaly : 0
                q = kalmanQ * (1.0 + anomTerm)
            }
            q = min(q, kalmanQMax)
        }
        let predictedP = kalmanP + q
        let kalmanGain = predictedP / (predictedP + kalmanR)
        kalmanEstimate = kalmanEstimate + kalmanGain * (measurement - kalmanEstimate)
        kalmanP = (1 - kalmanGain) * predictedP
        return kalmanEstimate
    }

    mutating func reset() {
        kalmanEstimate = -60.0
        kalmanP = 1.0
        kalmanSampleCount = 0
        smoothedSlope = 0.0
        latestRSSIs.removeAll()
        rssiTimestamps.removeAll()
    }
}

let DeviceInformation = CBUUID(string:"180A")
let ManufacturerName = CBUUID(string:"2A29")
let ModelName = CBUUID(string:"2A24")
let ExposureNotification = CBUUID(string:"FD6F")

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
    let bleQueue = DispatchQueue(label: "com.bleunlock.ble")
    private let lock = UnfairLock()
    var centralMgr : CBCentralManager!
    var devices : [UUID : Device] = [:]
    var delegate: FUnDelegate?
    weak var inputMonitor: InputActivityMonitor?
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
    var lastReceiveTime: Date = Date()
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

    func scanForPeripherals() {
        guard !centralMgr.isScanning else { return }
        centralMgr.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        //Log.sm.debug("Start scanning")
    }

    func startScanning() {
        scanMode = true
        scanForPeripherals()
    }

    func stopScanning() {
        scanMode = false
        centralMgr.stopScan()
    }

    func setPassiveMode(_ mode: Bool) {
        lock.lock()
        passiveMode = mode
        if passiveMode {
            activeModeTimer?.invalidate()
            activeModeTimer = nil
        }
        let peripheralToCancel = passiveMode ? monitoredPeripheral : nil
        lock.unlock()

        if let p = peripheralToCancel {
            centralMgr.cancelPeripheralConnection(p)
        }
        scanForPeripherals()
    }

    func startMonitor(uuid: UUID) {
        // 快照需要在锁外操作的旧 peripheral
        let oldPeripheral: CBPeripheral?
        lock.lock()
        oldPeripheral = monitoredUUID != uuid ? monitoredPeripheral : nil

        // 重置所有共享状态
        monitoredUUID = uuid
        scanMode = true
        presence = true
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
        monitoredUUIDs = [uuid]
        lock.unlock()

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
            lock.lock()
            monitoredPeripheral = peripheral
            lock.unlock()
            if peripheral.state == .disconnected {
                centralMgr.connect(peripheral, options: nil)
            }
        }

        scanForPeripherals()
    }

    func resetSignalTimer() {
        signalTimer?.invalidate()
        let timer = Timer(timeInterval: signalTimeout, repeats: false, block: { [weak self] _ in
            guard let self = self else { return }
            let shouldLose: Bool = self.lock.withLock {
                self.signalLostCount += 1
                if self.signalLostCount >= 3 {
                    return true
                } else {
                    return false
                }
            }
            if shouldLose {
                Log.sm.debug("Device is lost (3 consecutive timeouts)")
                self.delegate?.updateRSSI(rssi: nil, active: false)
                let wasPresent = self.lock.withLock { self.presence }
                if wasPresent {
                    self.lock.lock()
                    self.presence = false
                    self.lock.unlock()
                    self.delegate?.updatePresence(presence: false, reason: "lost")
                }
            } else {
                Log.sm.debug("Signal timeout \(self.lock.withLock { self.signalLostCount })/3, waiting...")
                DispatchQueue.main.async { self.resetSignalTimer() }
            }
        })
        RunLoop.main.add(timer, forMode: .common)
        signalTimer = timer
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            Log.ble.debug("Bluetooth powered on")
            if activeModeTimer == nil {
                scanForPeripherals()
            }
            powerWarn = false
        case .poweredOff:
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

    // MARK: - Time decay computation (heartbeat fallback, reads self.effectiveRSSI)
    func getEffectiveRSSI() -> Double {
        let (lastRecv, effRSSI, slope) = lock.withLock { (lastReceiveTime, effectiveRSSI, pipeline.smoothedSlope) }
        let elapsed = Date().timeIntervalSince(lastRecv)
        let rate: Double
        if abs(slope) > 2.0 {
            rate = 0.5 * (1 + 0.3 * abs(slope))
        } else {
            rate = 0.5 / (1 + 0.05 * elapsed)
        }
        let eff = effRSSI - rate * elapsed
        return max(eff, -100.0)
    }

    // MARK: - Direction 3: Heartbeat — proactive lock check
    private func ensureHeartbeat() {
        let alreadyExists = lock.withLock { heartbeatTimer != nil }
        guard !alreadyExists else { return }
        let interval = computeHeartbeatInterval()
        lock.lock()
        lastHeartbeatInterval = interval
        heartbeatTimer = makeHeartbeatTimer(interval: interval)
        RunLoop.main.add(heartbeatTimer!, forMode: .common)
        lock.unlock()
    }

    private func computeHeartbeatInterval() -> TimeInterval {
        let eff = getEffectiveRSSI()
        let baseTh = Double(unlockRSSI) + 10.0
        let lockTh = Double(lockRSSI == LOCK_DISABLED ? unlockRSSI : lockRSSI) + 10.0
        if eff > baseTh { return 5.0 }
        if eff < lockTh { return 1.0 }
        return 2.0
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
            if eff < threshold && !hasTimer && self.inputMonitor?.isActive != true {
                Log.sm.debug("[HB] effectiveRSSI=\(Int(eff)) < threshold=\(Int(threshold)), starting lock timer")
                self.startLockTimer()
            }
            let newInterval = self.computeHeartbeatInterval()
            let (lastInterval, currentTimer) = self.lock.withLock { (self.lastHeartbeatInterval, self.heartbeatTimer) }
            if abs(newInterval - lastInterval) > 0.5 {
                Log.sm.debug("[HB] interval \(lastInterval)s → \(newInterval)s")
                currentTimer?.invalidate()
                let newTimer = self.makeHeartbeatTimer(interval: newInterval)
                self.lock.lock()
                self.lastHeartbeatInterval = newInterval
                self.heartbeatTimer = newTimer
                self.lock.unlock()
                RunLoop.main.add(newTimer, forMode: .common)
            }
        })
    }

    func cancelHeartbeat() {
        lock.lock()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        lock.unlock()
    }

    func invalidateAllTimers() {
        lock.lock()
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
        lock.unlock()
    }

    // MARK: - Lock timer (shared by updateMonitoredPeripheral and heartbeat)
    private func startLockTimer() {
        let timer = Timer(timeInterval: proximityTimeout, repeats: false, block: { [weak self] _ in
            guard let self = self else { return }
            let lockOnIdle = UserDefaults.standard.object(forKey: "lockOnIdle") == nil
                || UserDefaults.standard.bool(forKey: "lockOnIdle")
            if lockOnIdle && self.inputMonitor?.isActive == true {
                Log.sm.debug("[SM] input active at lock timer fire, deferring")
                self.lock.lock()
                self.proximityTimer = nil
                self.lock.unlock()
                return
            }
            Log.sm.debug("Device is away")
            self.lock.lock()
            self.presence = false
            self.lock.unlock()
            self.cancelHeartbeat()
            DispatchQueue.main.async {
                self.delegate?.updatePresence(presence: false, reason: "away")
            }
            self.lock.lock()
            self.proximityTimer = nil
            self.lock.unlock()
        })
        RunLoop.main.add(timer, forMode: .common)
        lock.lock()
        proximityTimer = timer
        lock.unlock()
    }

    func updateMonitoredPeripheral(_ rssi: Int) {
        let now = Date()
        let source: SignalSource = (activeModeTimer != nil) ? .connected : .scanning

        // 1. 信号处理（纯计算）
        let decision = processSignal(rssi: rssi, source: source, now: now)

        // 2. 更新 displayRSSI
        updateDisplayRSSI(rssi: rssi)

        // 3. 在场检测（基于原始 RSSI 快速解锁）
        checkProximity(rssi: rssi)

        // 4. 锁定决策（基于 effectiveRSSI）
        applyLockTimer(effectiveRSSI: decision.effectiveRSSI)

        // 5. 心跳 + 信号超时
        ensureHeartbeat()
        resetSignalTimer()
    }

    // MARK: - updateMonitoredPeripheral 拆分方法

    private func processSignal(rssi: Int, source: SignalSource, now: Date) -> SignalDecision {
        var decision: SignalDecision!
        lock.lock()
        decision = pipeline.process(rssi: rssi, source: source, now: now)
        pipeline.latestRSSIs.append(Double(rssi))
        pipeline.rssiTimestamps.append(now)
        let cutoff = now.addingTimeInterval(-pipeline.windowDuration)
        while let first = pipeline.rssiTimestamps.first, first < cutoff {
            pipeline.rssiTimestamps.removeFirst()
            pipeline.latestRSSIs.removeFirst()
        }

        lastReceiveTime = now
        effectiveRSSI = decision.effectiveRSSI
        lock.unlock()

        return decision
    }

    private func updateDisplayRSSI(rssi: Int) {
        lock.lock()
        displayRSSI = 0.1 * Double(rssi) + 0.9 * displayRSSI
        lock.unlock()
    }

    private func checkProximity(rssi: Int) {
        let unlockThreshold = unlockRSSI == UNLOCK_DISABLED ? lockRSSI : unlockRSSI
        var shouldNotifyClose = false

        let dispRSSI: Double = lock.withLock {
            let disp = displayRSSI
            let wasPresent = presence
            if rssi >= unlockThreshold && !wasPresent {
                Log.sm.debug("Device is close")
                presence = true
                shouldNotifyClose = true
                pipeline.latestRSSIs.removeAll()
                pipeline.rssiTimestamps.removeAll()
            }
            return disp
        }

        if rssi >= unlockThreshold {
            if shouldNotifyClose {
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
            lock.lock()
            proximityTimer?.invalidate()
            proximityTimer = nil
            lock.unlock()
        } else {
            let (curPresence, curTimer) = lock.withLock { (presence, proximityTimer) }
            if curPresence && curTimer == nil {
                let lockOnIdle = UserDefaults.standard.object(forKey: "lockOnIdle") == nil
                    || UserDefaults.standard.bool(forKey: "lockOnIdle")
                if lockOnIdle && inputMonitor?.isActive == true {
                    Log.sm.debug("[SM] input active, rejecting lock signal")
                } else {
                    startLockTimer()
                }
            }
        }
    }

    func resetScanTimer(device: Device) {
        device.scanTimer?.invalidate()
        let timer = Timer(timeInterval: signalTimeout, repeats: false, block: { [weak self] _ in
            DispatchQueue.main.async {
                self?.delegate?.removeDevice(device: device)
            }
            if let p = device.peripheral {
                self?.centralMgr.cancelPeripheralConnection(p)
            }
            self?.devices.removeValue(forKey: device.uuid)
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
        lock.lock()
        connectionTimer = connTimer
        lock.unlock()
    }

    private func restartActiveModeTimer(peripheral: CBPeripheral) {
        lock.lock()
        activeModeTimer?.invalidate()
        let pollInterval = activePollInterval
        lock.unlock()

        let timer = Timer(timeInterval: pollInterval, repeats: true, block: { [weak self] _ in
            guard let self = self else { return }
            let lastRead = self.lock.withLock { self.lastReadAt }
            if Date().timeIntervalSince1970 > lastRead + 10 {
                Log.ble.debug("Falling back to passive mode")
                self.centralMgr.cancelPeripheralConnection(peripheral)
                self.lock.lock()
                self.activeModeTimer?.invalidate()
                self.activeModeTimer = nil
                self.lock.unlock()
                self.scanForPeripherals()
            } else if peripheral.state == .connected {
                peripheral.readRSSI()
            } else {
                self.connectMonitoredPeripheral()
            }
        })
        RunLoop.main.add(timer, forMode: .common)
        lock.lock()
        activeModeTimer = timer
        lock.unlock()
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber)
    {
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        if monitoredUUIDs.contains(peripheral.identifier) {
            let isMonitored: Bool
            lock.lock()
            isMonitored = peripheral.identifier == monitoredUUID
            if isMonitored && monitoredPeripheral == nil {
                monitoredPeripheral = peripheral
            }
            lock.unlock()
            if isMonitored {
                // 扫描回调：更新 presence 和锁定判断
                updateMonitoredPeripheral(rssi)
                let shouldConnect: Bool = lock.withLock { activeModeTimer == nil && !passiveMode }
                if shouldConnect {
                    connectMonitoredPeripheral()
                }
            }
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
                DispatchQueue.main.async {
                    self.delegate?.updateDevice(device: device)
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
            lock.lock()
            connectionTimer?.invalidate()
            connectionTimer = nil
            lock.unlock()
            peripheral.readRSSI()
        }
    }

    //MARK:CBCentralManagerDelegate end -

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Log.ble.debug("didDisconnectPeripheral: \(peripheral.identifier)")
        if peripheral == monitoredPeripheral {
            invalidateAllTimers()
            lock.lock()
            presence = false
            signalLostCount = 0
            lock.unlock()
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
        let kalmanNow: Double
        lock.lock()
        kalmanNow = pipeline.kalmanEstimate
        lastReadAt = now
        let fluctuation = abs(kalmanNow - Double(lastEstimatedRSSI))
        lastEstimatedRSSI = Int(kalmanNow)
        if fluctuation < 5 {
            stableCount += 1
        } else {
            stableCount = 0
        }
        if stableCount >= 10 && activePollInterval < 8.0 {
            activePollInterval = 8.0
            restartPolling = true
        } else if fluctuation >= 5 && activePollInterval > 2.0 {
            activePollInterval = 2.0
            stableCount = 0
            restartPolling = true
        }
        lock.unlock()

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
                    self.lock.lock()
                    self.activeModeTimer?.invalidate()
                    self.activeModeTimer = nil
                    self.lock.unlock()
                    self.scanForPeripherals()
                } else if peripheral.state == .connected {
                    peripheral.readRSSI()
                } else {
                    self.connectMonitoredPeripheral()
                }
            })
            RunLoop.main.add(timer, forMode: .common)
            lock.lock()
            activeModeTimer = timer
            lock.unlock()
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
