import Foundation
import CoreBluetooth
import Combine

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
    var centralMgr : CBCentralManager!
    var devices : [UUID : Device] = [:]
    var delegate: FUnDelegate?
    weak var inputMonitor: InputActivityMonitor?
    var scanMode = false
    var monitoredUUID: UUID?
    var monitoredUUIDs: Set<UUID> = []
    var monitoredPeripheral: CBPeripheral?
    var devicePresence: [UUID: Bool] = [:]
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
    var activeModeTimer : Timer? = nil
    var connectionTimer : Timer? = nil
    var stableCount: Int = 0
    var activePollInterval: TimeInterval = 2.0
    var lastEstimatedRSSI: Int = 0
    var signalLostCount: Int = 0

    func scanForPeripherals() {
        guard !centralMgr.isScanning else { return }
        centralMgr.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        //print("Start scanning")
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
        passiveMode = mode
        if passiveMode {
            activeModeTimer?.invalidate()
            activeModeTimer = nil
            if let p = monitoredPeripheral {
                centralMgr.cancelPeripheralConnection(p)
            }
        }
        scanForPeripherals()
    }

    func startMonitor(uuid: UUID) {
        if let p = monitoredPeripheral, monitoredUUID != uuid {
            centralMgr.cancelPeripheralConnection(p)
        }
        monitoredUUID = uuid
        scanMode = true
        proximityTimer?.invalidate()
        proximityTimer = nil
        resetSignalTimer()
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
        cancelHeartbeat()
        monitoredUUIDs = [uuid]
        devicePresence.removeAll()

        // 直接获取已知外设（不依赖扫描发现）
        let known = centralMgr.retrievePeripherals(withIdentifiers: [uuid])
        if let peripheral = known.first {
            print("[FUn] Found known peripheral: \(peripheral.identifier) state=\(peripheral.state)")
            monitoredPeripheral = peripheral
            if peripheral.state == .disconnected {
                centralMgr.connect(peripheral, options: nil)
            }
        }

        scanForPeripherals()
    }

    func addMonitoredDevice(uuid: UUID) {
        monitoredUUIDs.insert(uuid)
        devicePresence[uuid] = false
    }

    func removeMonitoredDevice(uuid: UUID) {
        monitoredUUIDs.remove(uuid)
        devicePresence.removeValue(forKey: uuid)
    }

    func updateDevicePresence(_ uuid: UUID, present: Bool) {
        devicePresence[uuid] = present
        let anyPresent = devicePresence.values.contains(true)
        if anyPresent != presence {
            presence = anyPresent
            DispatchQueue.main.async {
                self.delegate?.updatePresence(presence: self.presence, reason: present ? "close" : "away")
            }
        }
    }

    func resetSignalTimer() {
        signalTimer?.invalidate()
        signalTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { _ in
            self.signalLostCount += 1
            if self.signalLostCount >= 3 {
                print("Device is lost (3 consecutive timeouts)")
                self.delegate?.updateRSSI(rssi: nil, active: false)
                if self.presence {
                    self.presence = false
                    self.delegate?.updatePresence(presence: self.presence, reason: "lost")
                }
            } else {
                print("Signal timeout \(self.signalLostCount)/3, waiting...")
                self.resetSignalTimer()
            }
        })
        if let timer = signalTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("Bluetooth powered on")
            if activeModeTimer == nil {
                scanForPeripherals()
            }
            powerWarn = false
        case .poweredOff:
            print("Bluetooth powered off")
            presence = false
            signalTimer?.invalidate()
            signalTimer = nil
            if powerWarn {
                powerWarn = false
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
        let elapsed = Date().timeIntervalSince(lastReceiveTime)
        // 使用管道相同的自适应衰减率（heartbeat 读取时的增量惩罚）
        let rate: Double
        if abs(pipeline.smoothedSlope) > 2.0 {
            rate = 0.5 * (1 + 0.3 * abs(pipeline.smoothedSlope))
        } else {
            rate = 0.5 / (1 + 0.05 * elapsed)
        }
        let eff = self.effectiveRSSI - rate * elapsed
        return max(eff, -100.0)
    }

    // MARK: - Direction 3: Heartbeat — proactive lock check
    private func ensureHeartbeat() {
        guard heartbeatTimer == nil else { return }
        // Check every 2s if we should lock even without RSSI packets
        heartbeatTimer = Timer(timeInterval: 2.0, repeats: true, block: { [weak self] _ in
            guard let self = self else { return }
            guard self.presence else {
                self.heartbeatTimer?.invalidate()
                self.heartbeatTimer = nil
                return
            }
            let eff = self.getEffectiveRSSI()
            let threshold = Double(self.lockRSSI == self.LOCK_DISABLED ? self.unlockRSSI : self.lockRSSI)
            if eff < threshold && self.proximityTimer == nil && self.inputMonitor?.isActive != true {
                print("[HB] effectiveRSSI=\(Int(eff)) < threshold=\(Int(threshold)), starting lock timer")
                self.startLockTimer()
            }
        })
        RunLoop.main.add(heartbeatTimer!, forMode: .common)
    }

    private func cancelHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - Lock timer (shared by updateMonitoredPeripheral and heartbeat)
    private func startLockTimer() {
        let timer = Timer(timeInterval: proximityTimeout, repeats: false, block: { [weak self] _ in
            guard let self = self else { return }
            // Direction 3: final input check before locking
            let lockOnIdle = UserDefaults.standard.object(forKey: "lockOnIdle") == nil
                || UserDefaults.standard.bool(forKey: "lockOnIdle")
            if lockOnIdle && self.inputMonitor?.isActive == true {
                print("[SM] input active at lock timer fire, deferring")
                self.proximityTimer = nil
                return
            }
            print("Device is away")
            self.presence = false
            self.cancelHeartbeat()
            DispatchQueue.main.async {
                self.delegate?.updatePresence(presence: false, reason: "away")
            }
            self.proximityTimer = nil
        })
        RunLoop.main.add(timer, forMode: .common)
        proximityTimer = timer
    }

    func updateMonitoredPeripheral(_ rssi: Int) {
        let now = Date()
        let source: SignalSource = (activeModeTimer != nil) ? .connected : .scanning
        let decision = pipeline.process(rssi: rssi, source: source, now: now)

        // 维护窗口
        pipeline.latestRSSIs.append(Double(rssi))
        pipeline.rssiTimestamps.append(now)
        let cutoff = now.addingTimeInterval(-pipeline.windowDuration)
        while let first = pipeline.rssiTimestamps.first, first < cutoff {
            pipeline.rssiTimestamps.removeFirst()
            pipeline.latestRSSIs.removeFirst()
        }

        // 更新有效 RSSI（来自管道 S4 自适应衰减）
        lastReceiveTime = now
        effectiveRSSI = decision.effectiveRSSI

        // displayRSSI: raw RSSI EMA（在管道 process 中已计算，这里用旧路径保持兼容）
        displayRSSI = 0.1 * Double(rssi) + 0.9 * displayRSSI

        // Presence check: use raw rssi for fast unlock detection
        let unlockThreshold = unlockRSSI == UNLOCK_DISABLED ? lockRSSI : unlockRSSI
        if rssi >= unlockThreshold {
            if !presence {
                print("Device is close")
                presence = true
                DispatchQueue.main.async {
                    self.delegate?.updatePresence(presence: true, reason: "close")
                }
                pipeline.latestRSSIs.removeAll()
                pipeline.rssiTimestamps.removeAll()
            }
            // Always attempt unlock when signal is strong and screen might be locked
            DispatchQueue.main.async {
                self.delegate?.updateRSSI(rssi: Int(self.displayRSSI), active: self.activeModeTimer != nil)
                self.delegate?.onDeviceApproached()
            }
        } else {
            DispatchQueue.main.async {
                self.delegate?.updateRSSI(rssi: Int(self.displayRSSI), active: self.activeModeTimer != nil)
            }
        }

        // Direction 2 + 3: use effectiveRSSI for lock decision
        let threshold = Double(lockRSSI == LOCK_DISABLED ? unlockRSSI : lockRSSI)
        if effectiveRSSI >= threshold {
            // Signal strong → cancel any pending lock
            if let timer = proximityTimer {
                timer.invalidate()
                proximityTimer = nil
            }
        } else if presence && proximityTimer == nil {
            // Direction 3: input activity veto — no timer, no locking
            let lockOnIdle = UserDefaults.standard.object(forKey: "lockOnIdle") == nil
                || UserDefaults.standard.bool(forKey: "lockOnIdle")
            if lockOnIdle && inputMonitor?.isActive == true {
                print("[SM] input active, rejecting lock signal")
                // Don't start proximityTimer; heartbeat will catch it later if needed
            } else {
                startLockTimer()
            }
        }

        ensureHeartbeat()
        resetSignalTimer()
    }

    func resetScanTimer(device: Device) {
        device.scanTimer?.invalidate()
        device.scanTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { _ in
            DispatchQueue.main.async {
                self.delegate?.removeDevice(device: device)
            }
            if let p = device.peripheral {
                self.centralMgr.cancelPeripheralConnection(p)
            }
            self.devices.removeValue(forKey: device.uuid)
        })
        if let timer = device.scanTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func connectMonitoredPeripheral() {
        guard let p = monitoredPeripheral else { return }

        // Idk why but this works like a charm when 'didConnect' won't get called.
        // However, this generates warnings in the log.
        p.readRSSI()

        guard p.state == .disconnected else { return }
        print("Connecting")
        centralMgr.connect(p, options: nil)
        connectionTimer?.invalidate()
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false, block: { _ in
            if p.state == .connecting {
                print("Connection timeout")
                self.centralMgr.cancelPeripheralConnection(p)
            }
        })
        RunLoop.main.add(connectionTimer!, forMode: .common)
    }

    private func restartActiveModeTimer(peripheral: CBPeripheral) {
        activeModeTimer?.invalidate()
        let timer = Timer(timeInterval: activePollInterval, repeats: true, block: { [weak self] _ in
            guard let self = self else { return }
            if Date().timeIntervalSince1970 > self.lastReadAt + 10 {
                print("Falling back to passive mode")
                self.centralMgr.cancelPeripheralConnection(peripheral)
                self.activeModeTimer?.invalidate()
                self.activeModeTimer = nil
                self.scanForPeripherals()
            } else if peripheral.state == .connected {
                peripheral.readRSSI()
            } else {
                self.connectMonitoredPeripheral()
            }
        })
        RunLoop.main.add(timer, forMode: .common)
        activeModeTimer = timer
    }

    //MARK:- CBCentralManagerDelegate start

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber)
    {
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        if monitoredUUIDs.contains(peripheral.identifier) {
            if peripheral.identifier == monitoredUUID {
                if monitoredPeripheral == nil {
                    monitoredPeripheral = peripheral
                }
                // 扫描回调：更新 presence 和锁定判断
                updateMonitoredPeripheral(rssi)
                if activeModeTimer == nil && !passiveMode {
                    connectMonitoredPeripheral()
                }
            }
        }

        if (scanMode) {
            if let uuids = advertisementData["kCBAdvDataServiceUUIDs"] as? [CBUUID] {
                for uuid in uuids {
                    if uuid == ExposureNotification {
                        //print("Device \(peripheral.identifier) Exposure Notification")
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
        if peripheral == monitoredPeripheral && !passiveMode {
            print("Connected")
            connectionTimer?.invalidate()
            connectionTimer = nil
            peripheral.readRSSI()
        }
    }

    //MARK:CBCentralManagerDelegate end -
    
    //MARK:- CBPeripheralDelegate start

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        // 按 UUID 匹配，不依赖对象引用相等
        guard peripheral.identifier == monitoredUUID else { return }
        if monitoredPeripheral == nil { monitoredPeripheral = peripheral }
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        updateMonitoredPeripheral(rssi)
        lastReadAt = Date().timeIntervalSince1970

        // Track RSSI stability for adaptive polling
        let fluctuation = abs(pipeline.kalmanEstimate - Double(lastEstimatedRSSI))
        lastEstimatedRSSI = Int(pipeline.kalmanEstimate)
        if fluctuation < 5 {
            stableCount += 1
        } else {
            stableCount = 0
        }
        if stableCount >= 10 && activePollInterval < 8.0 {
            activePollInterval = 8.0
            restartActiveModeTimer(peripheral: peripheral)
        } else if fluctuation >= 5 && activePollInterval > 2.0 {
            activePollInterval = 2.0
            stableCount = 0
            restartActiveModeTimer(peripheral: peripheral)
        }

        if activeModeTimer == nil && !passiveMode {
            print("Entering active mode")
            if !scanMode {
                centralMgr.stopScan()
            }
            let timer = Timer(timeInterval: activePollInterval, repeats: true, block: { [weak self] _ in
                guard let self = self else { return }
                if Date().timeIntervalSince1970 > self.lastReadAt + 10 {
                    print("Falling back to passive mode")
                    self.centralMgr.cancelPeripheralConnection(peripheral)
                    self.activeModeTimer?.invalidate()
                    self.activeModeTimer = nil
                    self.scanForPeripherals()
                } else if peripheral.state == .connected {
                    peripheral.readRSSI()
                } else {
                    self.connectMonitoredPeripheral()
                }
            })
            RunLoop.main.add(timer, forMode: .common)
            activeModeTimer = timer
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
