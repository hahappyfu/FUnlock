import Foundation
@preconcurrency import CoreBluetooth
import os

// MARK: - 宿主回调协议

/// BLEScanner 向宿主（FUn）上报硬件事件、并自宿主获取信号判定上下文与 UI 派发目标的协议。
/// 所有回调均在 bleQueue 上触发。
protocol BLEScannerHost: AnyObject {
    /// 监控设备的原始 RSSI 采样（宿主执行滤波、在场判定与锁定决策）
    func scanner(_ scanner: BLEScanner, didSampleMonitoredRSSI rssi: Int)
    /// 被监控外设断开连接（宿主复位信号丢失计数）
    func scannerDidDisconnectMonitored(_ scanner: BLEScanner)
    /// 蓝牙就绪（宿主清除电源告警标志）
    func scannerDidPowerOn(_ scanner: BLEScanner)
    /// 蓝牙关闭（宿主取消全部计时器、清在场态并按需派发电源告警）
    func scannerDidPowerOff(_ scanner: BLEScanner)
    /// 轮询自适应上下文：卡尔曼估计 + 是否处于接近窗口（宿主在共享锁内计算）
    func scannerPollingContext(_ scanner: BLEScanner) -> BLEScanner.PollingContext
    /// 设备发现超时（s）：由宿主提供（对外仍由 FUn.signalTimeout 控制）
    func scannerDeviceScanTimeout(_ scanner: BLEScanner) -> TimeInterval
    /// 设备列表 UI 派发目标（@MainActor 协议，宿主统一以 Task { @MainActor } 派发）
    var bleDelegate: FUnDelegate? { get }
}

/// BLE 硬件驱动：CBCentralManager/CBPeripheral 代理、扫描/连接生命周期与主动模式 RSSI 轮询。
/// 线程契约（@unchecked Sendable 依据）：
/// - CoreBluetooth 回调与定时器回调严格运行在串行 `queue`（宿主传入的 bleQueue）上；
/// - 跨线程共享状态（devices / monitoredUUID / monitoredPeripheral / 轮询参数 / 设备计时器）
///   统一由与宿主共享的 `lock`（UnfairLock）保护；宿主在锁内直接读写这些字段，
///   以保持 startMonitor / unbindAllState 等跨对象复位的原子性；
/// - Timer 操作与向 `bleDelegate` 的派发统一走 `Task { @MainActor [weak self] }` 跨回主线程；
/// - 信号滤波、在场/锁定判定与心跳状态机属于宿主（FUn），本类只负责采集与上报。
final class BLEScanner: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    let queue: DispatchQueue
    private let lock: UnfairLock
    private weak var host: BLEScannerHost?

    var centralMgr: CBCentralManager!

    // MARK: - 共享状态（与宿主共用 `lock` 保护）

    var devices: [UUID: Device] = [:]
    var scanMode = false
    var monitoredUUID: UUID?
    var monitoredUUIDs: Set<UUID> = []
    var monitoredPeripheral: CBPeripheral?
    var passiveMode = false
    var thresholdRSSI = -90
    var activeModeTimer: Timer?
    var connectionTimer: Timer?
    var stableCount: Int = 0
    var activePollInterval: TimeInterval = 2.0
    var lastEstimatedRSSI: Int = 0

    // MARK: - 本类状态（仅在 `queue` 或主 RunLoop 上访问）

    /// 快速轮询间隔（s）：信号接近阈值时降低感知延迟
    private static let fastPollInterval: TimeInterval = 0.5
    /// 设备发现超时兜底值（宿主不可用时）：与 FUn.signalTimeout 默认值一致
    private static let defaultDeviceScanTimeout: TimeInterval = 60.0
    var lastReadAt = 0.0
    // 节流：非监控设备的 UI 刷新时间戳
    private var lastUIUpdateTime: [UUID: Date] = [:]
    private let uiThrottleInterval: TimeInterval = 1.0
    // 跟踪当前扫描的 AllowDuplicates 状态，避免重复启动
    private var currentScanAllowDuplicates: Bool = false

    /// 轮询自适应所需的信号上下文快照
    struct PollingContext {
        /// 卡尔曼滤波估计值（dBm）
        let kalman: Double
        /// 有效信号是否处于接近窗口（解锁爬升区或锁定阈值附近）
        let nearThreshold: Bool
    }

    init(queue: DispatchQueue, lock: UnfairLock, host: BLEScannerHost) {
        self.queue = queue
        self.lock = lock
        self.host = host
        super.init()
        let btAuth = CBManager.authorization
        logDebug(component: "FUn", "[DIAG] FUn.init() - CBCentralManager initializing, bluetooth authorization=\(btAuth.rawValue)")
        centralMgr = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: - 扫描 / 监控生命周期

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

    /// 绑定后重连已知外设并恢复扫描（FUn.startMonitor 的硬件侧尾部动作）
    func attachMonitoredPeripheral(uuid: UUID) {
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

    /// 锁内读取监控的 peripheral 引用（锁外取消连接）
    func withLockedPeripheral() -> CBPeripheral? {
        lock.withLock { monitoredPeripheral }
    }

    /// 锁内遍历 devices（Manager 解绑/清理时避免裸读字典）
    func withDevices(_ body: ([UUID: Device]) -> Void) {
        lock.withLock { body(devices) }
    }

    func invalidateAllDeviceTimers() {
        let timers: [Timer] = lock.withLock {
            var collected: [Timer] = []
            for (_, device) in devices {
                if let t = device.scanTimer {
                    collected.append(t)
                    device.scanTimer = nil
                }
            }
            return collected
        }
        for t in timers { t.invalidate() }
    }

    func invalidateAllTimers() {
        lock.withLock {
            activeModeTimer?.invalidate()
            activeModeTimer = nil
            connectionTimer?.invalidate()
            connectionTimer = nil
        }
    }

    /// 设备发现超时计时器：超时后移除设备并通知宿主 UI
    func resetScanTimer(device: Device, timeout: TimeInterval) {
        device.scanTimer?.invalidate()
        guard let uuid = device.uuid else { return }
        // peripheral 在闭包外提前取出（Sendable），避免 @Sendable Timer 闭包捕获非 Sendable 的 device
        let peripheral = device.peripheral
        let timer = Timer(timeInterval: timeout, repeats: false, block: { [weak self] _ in
            // 闭包只捕获 uuid（Sendable）；device 在 lock 保护下原子取出并移除，再派发主线程
            guard let self = self else { return }
            if let p = peripheral {
                self.centralMgr.cancelPeripheralConnection(p)
            }
            // 在 lock 保护下原子取出并移除；先取出再派发，避免异步执行时已被移除导致恒 nil
            if let device = self.lock.withLock({ self.devices.removeValue(forKey: uuid) }) {
                Task { @MainActor [weak self] in
                    self?.host?.bleDelegate?.removeDevice(device: device)
                }
            }
            // 防泄漏：设备过期时清理节流记录（派发到 bleQueue 串行队列保证线程安全）
            self.queue.async { [weak self] in
                self?.lastUIUpdateTime.removeValue(forKey: uuid)
            }
        })
        RunLoop.main.add(timer, forMode: .common)
        device.scanTimer = timer
    }

    // MARK: - 连接生命周期

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
                Log.ble.error("Connection timeout")
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
                Log.ble.info("Falling back to passive mode")
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

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logDebug(component: "FUn", "[DIAG] centralManagerDidUpdateState - state=\(central.state.rawValue), authorization=\(CBManager.authorization.rawValue)")
        switch central.state {
        case .poweredOn:
            Log.ble.debug("Bluetooth powered on")
            if activeModeTimer == nil {
                scanForPeripherals()
            }
            host?.scannerDidPowerOn(self)
        case .poweredOff:
            Log.ble.debug("Bluetooth powered off")
            // 宿主负责：取消全部计时器、清在场态、按需派发电源告警
            host?.scannerDidPowerOff(self)
        default:
            break
        }
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
        throttledBleLog("didDiscover", interval: 1.0, "[DEBUG] didDiscover \(peripheral.name ?? "unknown") rssi=\(rssi) inList=\(isInList) monitoredUUID=\(monitorInfo.monitoredUUID != nil ? "set" : "nil") uuidCount=\(monitorInfo.uuidCount)")
        let scanTimerTimeout = host?.scannerDeviceScanTimeout(self) ?? Self.defaultDeviceScanTimeout

        if monitoredUUIDs.contains(peripheral.identifier) {
            let isMonitored: Bool = lock.withLock {
                let match = peripheral.identifier == monitoredUUID
                if match && monitoredPeripheral == nil {
                    monitoredPeripheral = peripheral
                }
                return match
            }
            if isMonitored {
                // 扫描回调：上报宿主更新 presence 和锁定判断
                host?.scanner(self, didSampleMonitoredRSSI: rssi)
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
                    if uuid == BLEUUIDs.exposureNotification {
                        return
                    }
                }
            }
            let dev = lock.withLock { devices[peripheral.identifier] }
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
                    lock.withLock { devices[peripheral.identifier] = device }
                    central.connect(peripheral, options: nil)
                    // 闭包只捕获 peripheral.identifier（Sendable），device 在闭包内按 id 取锁内快照
                    let deviceId = peripheral.identifier
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        let snapshot = self.lock.withLock { self.devices[deviceId] }
                        if let snapshot = snapshot {
                            self.host?.bleDelegate?.newDevice(device: snapshot)
                        }
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
                    // 闭包只捕获 peripheral.identifier（Sendable），device 在闭包内按 id 取锁内快照
                    let deviceId = peripheral.identifier
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        let snapshot = self.lock.withLock { self.devices[deviceId] }
                        if let snapshot = snapshot {
                            self.host?.bleDelegate?.updateDevice(device: snapshot)
                        }
                    }
                }
            }
            resetScanTimer(device: device, timeout: scanTimerTimeout)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral)
    {
        peripheral.delegate = self
        if scanMode {
            peripheral.discoverServices([BLEUUIDs.deviceInformation])
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

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Log.ble.debug("didDisconnectPeripheral: \(peripheral.identifier)")
        if peripheral == monitoredPeripheral {
            // 只取消主动模式定时器，保留心跳和信号超时链用于检测离场
            lock.withLock {
                activeModeTimer?.invalidate()
                activeModeTimer = nil
                connectionTimer?.invalidate()
                connectionTimer = nil
            }
            // 不立即锁屏 — BLE 连接可能因干扰短暂断开
            // 由心跳衰减机制判断：设备真正离开后 ~10 秒锁屏
            host?.scannerDidDisconnectMonitored(self)
            // 恢复扫描，尝试重新发现设备
            scanForPeripherals()
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let shouldProcess: Bool = lock.withLock {
            guard peripheral.identifier == monitoredUUID else { return false }
            if monitoredPeripheral == nil { monitoredPeripheral = peripheral }
            return true
        }
        guard shouldProcess else { return }
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
        guard let host = self.host else { return }
        host.scanner(self, didSampleMonitoredRSSI: rssi)

        let polling = host.scannerPollingContext(self)

        let now = Date().timeIntervalSince1970
        var restartPolling = false
        _ = lock.withLock {
            let k = polling.kalman
            lastReadAt = now
            let fluctuation = abs(k - Double(lastEstimatedRSSI))
            lastEstimatedRSSI = Int(k)
            // 方案 A：信号接近阈值（有效信号进入 [threshold-window, threshold)）时启用快速轮询，
            // 信号一触线立刻被感知，缩短解锁/锁屏感知延迟
            // 走近方向：解锁爬升区 [stair-window, stair) 也启用快速轮询——用户从远处走回时
            // 若只按锁定阈值触发，爬升区用 8s 慢采样，会出现"走到面前等几十秒"的感知延迟
            if polling.nearThreshold {
                if activePollInterval != Self.fastPollInterval {
                    activePollInterval = Self.fastPollInterval
                    restartPolling = true
                }
            } else {
                if fluctuation < 5 {
                    stableCount += 1
                } else {
                    stableCount = 0
                }
                if activePollInterval == Self.fastPollInterval {
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
            restartActiveModeTimer(peripheral: peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        if let services = peripheral.services {
            for service in services {
                if service.uuid == BLEUUIDs.deviceInformation {
                    peripheral.discoverCharacteristics([BLEUUIDs.manufacturerName, BLEUUIDs.modelName], for: service)
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
                if chara.uuid == BLEUUIDs.manufacturerName || chara.uuid == BLEUUIDs.modelName {
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
                if let device = lock.withLock({ devices[peripheral.identifier] }) {
                    // 闭包只捕获 peripheral.identifier（Sendable），device 在闭包内按 id 取锁内快照
                    let deviceId = peripheral.identifier
                    if characteristic.uuid == BLEUUIDs.manufacturerName {
                        device.manufacture = s
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            if let snapshot = self.lock.withLock({ self.devices[deviceId] }) {
                                self.host?.bleDelegate?.updateDevice(device: snapshot)
                            }
                        }
                    }
                    if characteristic.uuid == BLEUUIDs.modelName {
                        device.model = s
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            if let snapshot = self.lock.withLock({ self.devices[deviceId] }) {
                                self.host?.bleDelegate?.updateDevice(device: snapshot)
                            }
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
        peripheral.discoverServices([BLEUUIDs.deviceInformation])
    }
}
