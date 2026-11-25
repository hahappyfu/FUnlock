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
    /// 单一截止时间调度器（宿主拥有，替代所有散装 Timer）
    var scheduler: LiveDeadlineScheduler { get }
    /// 设备列表 UI 派发目标（@MainActor 协议，宿主统一以 Task { @MainActor } 派发）
    var bleDelegate: FUnDelegate? { get }
}

/// BLE 中央管理器：扫描/设备列表生命周期与 CBCentralManager 代理。
/// 线程契约：CoreBluetooth 与定时器运行在 queue 上；共享状态（含 Device 字段）由 lock 保护，
/// 字段修改/比较统一锁内完成；Timer 注册在主 RunLoop、invalidate 派发回主线程；
/// 向 bleDelegate 走 Task {@MainActor}。
final class BLEScanner: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    let queue: DispatchQueue
    let lock: UnfairLock
    weak var host: BLEScannerHost?

    var centralMgr: CBCentralManager!
    /// 外设连接与 RSSI 轮询处理器（在 init 完成 phase-1 后创建）
    var handler: BLEPeripheralHandler!

    // MARK: - 共享状态（与宿主共用 `lock` 保护）

    var devices: [UUID: Device] = [:]
    /// 是否处于扫描模式：主线程写（startScanning/stopScanning）/ bleQueue 读（didDiscover 等），统一走 lock
    var scanMode = false
    var monitoredUUID: UUID?
    var monitoredUUIDs: Set<UUID> = []
    var monitoredPeripheral: CBPeripheral?
    /// 是否被动模式：所有访问统一走 lock
    var passiveMode = false
    /// 设备发现入库的最低信号门限（dBm）：主线程写（AppDelegate 偏好经 FUn 转发）/
    /// bleQueue 读（didDiscover），统一走 lock。
    /// 默认 -100：与最低可配置解锁阈值（-100）对齐——此前默认 -90 会导致解锁阈值放宽到
    /// -100 时设备列表先被门限过滤、可解锁设备永不出现
    var thresholdRSSI = -100
    /// 当前扫描的 AllowDuplicates 状态：主线程写（startScanning/stopScanning）/
    /// bleQueue 读写（scanForPeripherals），统一走 lock（避免重复启停判断的撕裂）
    private var currentScanAllowDuplicates: Bool = false

    // MARK: - 本类状态（仅在 `queue` 或主 RunLoop 上访问）

    /// 设备发现超时兜底值（宿主不可用时）：与 FUn.signalTimeout 默认值一致
    private static let defaultDeviceScanTimeout: TimeInterval = 60.0
    // 节流：非监控设备的 UI 刷新时间戳
    private var lastUIUpdateTime: [UUID: Date] = [:]
    private let uiThrottleInterval: TimeInterval = 1.0

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
        AppLog.info(.ble, "initCBCentralManager", [("btAuth", "\(btAuth.rawValue)")])
        handler = BLEPeripheralHandler(lock: lock, scanner: self)
        centralMgr = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: - 纯函数（供单元测试）

    /// 清洗 CoreBluetooth 原始 RSSI：`127` 是不可用哨兵，`>= 0` 与 `< -127` 均为非法值。
    /// 返回 nil 表示本次样本必须丢弃，绝不能钳制为 0 dBm（会被误判为极近距离）。
    static func sanitizeRSSI(_ raw: Int) -> Int? {
        guard raw < 0, raw >= -127 else { return nil }
        return raw
    }

    /// 是否应丢弃本次设备发现：仅在「非扫描模式 + 已绑定 + 非目标」时过滤。
    /// 扫描模式（用户点「更换设备」）必须放行其他设备，否则永远搜不到候选。
    static func shouldDropDiscovery(monitoredUUID: UUID?, isInList: Bool, scanMode: Bool) -> Bool {
        !scanMode && monitoredUUID != nil && !isInList
    }

    // MARK: - 扫描 / 监控生命周期

    /// 当前扫描是否需要 AllowDuplicates（调用方必须持锁）。
    /// 已绑定设备且处于被动模式、或主动模式尚未进入轮询（连接/重连期）时需要重复广播；
    /// 未绑定设备或主动轮询健康（readRSSI 驱动）时不需要。
    func computeAllowDuplicatesLocked() -> Bool {
        guard monitoredUUID != nil else { return false }
        if passiveMode { return true }
        return !(host?.scheduler.isScheduled(.activePoll) ?? false)
    }

    func scanForPeripherals() {
        // 优化：根据当前模式动态决定 AllowDuplicates。
        // monitoredUUID/passiveMode/currentScanAllowDuplicates 均为跨线程共享状态
        // （主线程写 vs bleQueue 读），统一锁内快照并锁内完成 AllowDuplicates 状态置换
        let (restartNeeded, allowDuplicates): (Bool, Bool) = lock.withLock {
            let duplicates = computeAllowDuplicatesLocked()
            // 参数没变且正在扫描，跳过重启
            if centralMgr.isScanning && currentScanAllowDuplicates == duplicates {
                return (false, duplicates)
            }
            currentScanAllowDuplicates = duplicates
            return (true, duplicates)
        }
        guard restartNeeded else { return }
        // 参数变了，需要先停再启
        if centralMgr.isScanning {
            centralMgr.stopScan()
        }
        let options: [String: Any] = allowDuplicates
            ? [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            : [:]
        centralMgr.scanForPeripherals(withServices: nil, options: options)
    }

    func startScanning() {
        lock.withLock { scanMode = true }
        scanForPeripherals()
    }

    /// UI（设备发现列表）停止扫描时，是否应同时停止底层 CBCentralManager。
    /// 已绑定设备且仍在后台监控时必须保留扫描：被动模式靠广播采样，
    /// 主动模式在尚未进入轮询（连接/重连期）时也需要广播流兜底；
    /// 只有未绑定、或主动模式已在轮询（连接健康，靠 readRSSI）时才真正停扫。
    func shouldStopCentralScanOnStopDiscovery() -> Bool {
        let activeScheduled = host?.scheduler.isScheduled(.activePoll) == true
        return lock.withLock {
            if monitoredUUID == nil { return true }
            if !passiveMode && activeScheduled { return true }
            return false
        }
    }

    /// 无条件停止扫描（解绑路径专用，确保清除监控后不再保留后台扫描）。
    func stopAllScanning() {
        lock.withLock {
            scanMode = false
            currentScanAllowDuplicates = false
        }
        centralMgr.stopScan()
    }

    func stopScanning() {
        lock.withLock { scanMode = false }
        if shouldStopCentralScanOnStopDiscovery() {
            lock.withLock { currentScanAllowDuplicates = false }
            centralMgr.stopScan()
        } else {
            // 仍有绑定设备在后台监控：按监控模式参数重建扫描，而不是杀掉扫描
            scanForPeripherals()
        }
    }

    func setPassiveMode(_ mode: Bool) {
        let peripheralToCancel: CBPeripheral? = lock.withLock {
            passiveMode = mode
            return passiveMode ? monitoredPeripheral : nil
        }

        if mode {
            host?.scheduler.cancel(.activePoll)
        }
        if let p = peripheralToCancel {
            centralMgr.cancelPeripheralConnection(p)
        }
        scanForPeripherals()
    }

    func invalidateAllDeviceTimers() {
        host?.scheduler.cancelWhere {
            if case .deviceExpiry = $0 { return true }
            return false
        }
    }

    /// 锁内按 id 取设备并转为不可变快照，供统一派发点复用
    func snapshotLocked(for deviceId: UUID) -> DeviceSnapshot? {
        lock.withLock {
            guard let device = devices[deviceId] else { return nil }
            return device.toSnapshot(isMonitored: monitoredUUID == deviceId)
        }
    }

    /// 设备发现超时计时器：通过单一调度器登记 .deviceExpiry(uuid)
    func resetScanTimer(device: Device, timeout: TimeInterval) {
        host?.scheduler.scheduleAfter(.deviceExpiry(device.uuid), interval: timeout)
    }

    func handleDeviceExpiry(uuid: UUID, scheduledAt: Date) {
        _ = scheduledAt
        queue.async { [weak self] in
            guard let self else { return }
            // 若在投递排队期间设备刚收到新广播并重新排期，放弃过期移除
            guard self.host?.scheduler.isScheduled(.deviceExpiry(uuid)) != true else { return }
            let (peripheral, snapshot): (CBPeripheral?, DeviceSnapshot?) = self.lock.withLock {
                guard let device = self.devices.removeValue(forKey: uuid) else { return (nil, nil) }
                return (device.peripheral, device.toSnapshot(isMonitored: self.monitoredUUID == uuid))
            }
            if let p = peripheral {
                self.centralMgr.cancelPeripheralConnection(p)
            }
            self.lastUIUpdateTime.removeValue(forKey: uuid)
            if let snapshot {
                Task { @MainActor [weak self] in
                    self?.host?.bleDelegate?.removeDevice(device: snapshot)
                }
            }
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        AppLog.info(.ble, "centralStateUpdate", [("state", "\(central.state.rawValue)"), ("authorization", "\(CBManager.authorization.rawValue)")])
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("com.funlock.bluetoothStateChanged"), object: nil)
        }
        switch central.state {
        case .poweredOn:
            AppLog.info(.ble, "bluetoothPoweredOn")
            if host?.scheduler.isScheduled(.activePoll) != true {
                scanForPeripherals()
            }
            host?.scannerDidPowerOn(self)
        case .poweredOff:
            AppLog.info(.ble, "bluetoothPoweredOff")
            // 宿主负责：取消全部计时器、清在场态、按需派发电源告警
            host?.scannerDidPowerOff(self)
        case .unauthorized:
            AppLog.error(.ble, "bluetoothUnauthorized", [("authorization", "\(CBManager.authorization.rawValue)")])
        case .unsupported:
            AppLog.error(.ble, "bluetoothUnsupported")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber)
    {
        guard let rssi = Self.sanitizeRSSI(RSSI.intValue) else {
            throttledBleLog("didDiscoverInvalidRSSI", interval: 5.0, "didDiscoverInvalidRSSI", [
                ("raw", "\(RSSI.intValue)"),
                ("name", peripheral.name ?? "unknown")
            ])
            return
        }

        // 监控上下文与 scanMode 一次锁内快照（修复 monitoredUUIDs 锁外 contains 与
        // scanMode 锁外读的竞态）
        let monitorInfo: (monitoredUUID: UUID?, isInList: Bool, uuidCount: Int, scanMode: Bool) = lock.withLock {
            (monitoredUUID, monitoredUUIDs.contains(peripheral.identifier), monitoredUUIDs.count, scanMode)
        }
        throttledBleLog("didDiscover", interval: 1.0, "didDiscover", [
            ("name", peripheral.name ?? "unknown"),
            ("rssi", "\(rssi)"),
            ("inList", "\(monitorInfo.isInList)"),
            ("monitoredUUID", monitorInfo.monitoredUUID != nil ? "set" : "nil"),
            ("uuidCount", "\(monitorInfo.uuidCount)"),
        ])
        let scanTimerTimeout = host?.scannerDeviceScanTimeout(self) ?? Self.defaultDeviceScanTimeout

        // 监控设备分支：上报宿主并确保连接（见 BLEPeripheralHandler）
        handler.handleMonitoredAdvertisement(peripheral, rssi: rssi)

        // 优化 1：监控模式下，非目标设备直接丢弃；扫描模式（更换设备）必须放行
        if Self.shouldDropDiscovery(monitoredUUID: monitorInfo.monitoredUUID,
                                    isInList: monitorInfo.isInList,
                                    scanMode: monitorInfo.scanMode) {
            return
        }

        if (monitorInfo.scanMode) {
            if let uuids = advertisementData["kCBAdvDataServiceUUIDs"] as? [CBUUID] {
                for uuid in uuids {
                    if uuid == BLEUUIDs.exposureNotification {
                        return
                    }
                }
            }
            // P1-5: SQLite 查询移出 UnfairLock 临界区——入参 peripheral 为局部变量，
            // 进锁前预查（getLEDeviceInfoFromUUID 内部取 leDbLock 并做磁盘 I/O），
            // 锁内仅剩纯内存赋值；多余查询仅落在已有设备/低于门限路径，成本可忽略
            let leInfo = getLEDeviceInfoFromUUID(peripheral.identifier.description)
            // Device 字段的创建/更新/比较统一在锁内完成（修复锁外写/锁内读竞态）；
            // 锁外仅执行 CoreBluetooth 调用与快照派发
            let (device, isNew, passedThreshold): (Device, Bool, Bool) = lock.withLock {
                if let existing = devices[peripheral.identifier] {
                    existing.rssi = rssi
                    return (existing, false, false)
                }
                let d = Device(uuid: peripheral.identifier)
                if rssi >= thresholdRSSI {
                    d.peripheral = peripheral
                    d.rssi = rssi
                    d.advData = advertisementData["kCBAdvDataManufacturerData"] as? Data
                    if let info = leInfo {
                        d.blName = info.name
                        d.macAddr = info.macAddr
                    }
                    devices[peripheral.identifier] = d
                    return (d, true, true)
                }
                // 低于入库门限的新设备不入库（维持原语义），仅以超时计时器兜底
                return (d, true, false)
            }
            if isNew && passedThreshold {
                central.connect(peripheral, options: nil)
                // 闭包只捕获 peripheral.identifier（Sendable）；device 在闭包内按 id 锁内取值，
                // 并立刻转为不可变快照再派发，杜绝堆引用跨 Actor 共享
                let deviceId = peripheral.identifier
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if let snapshot = self.snapshotLocked(for: deviceId) {
                        self.host?.bleDelegate?.newDevice(device: snapshot)
                    }
                }
            } else if !isNew {
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
                    let deviceId = peripheral.identifier
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        if let snapshot = self.snapshotLocked(for: deviceId) {
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
        handler.centralManager(central, didConnect: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handler.centralManager(central, didDisconnectPeripheral: peripheral, error: error)
    }
}
