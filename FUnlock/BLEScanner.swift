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
        logDebug(component: "FUn", "[DIAG] FUn.init() - CBCentralManager initializing, bluetooth authorization=\(btAuth.rawValue)")
        handler = BLEPeripheralHandler(lock: lock, scanner: self)
        centralMgr = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: - 扫描 / 监控生命周期

    func scanForPeripherals() {
        // 优化：根据当前模式动态决定 AllowDuplicates。
        // monitoredUUID/passiveMode/currentScanAllowDuplicates 均为跨线程共享状态
        // （主线程写 vs bleQueue 读），统一锁内快照并锁内完成 AllowDuplicates 状态置换
        let (restartNeeded, allowDuplicates): (Bool, Bool) = lock.withLock {
            let duplicates: Bool
            if monitoredUUID == nil {
                // 未绑定设备，只需发现列表，不需要重复广播
                duplicates = false
            } else if passiveMode {
                // 被动模式：靠扫描回调获取 RSSI，需要重复
                duplicates = true
            } else {
                // 主动模式 + 有目标：靠 readRSSI 轮询，不需要重复
                duplicates = false
            }
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

    func stopScanning() {
        lock.withLock {
            scanMode = false
            currentScanAllowDuplicates = false
        }
        centralMgr.stopScan()
    }

    func setPassiveMode(_ mode: Bool) {
        let (peripheralToCancel, oldTimer): (CBPeripheral?, Timer?) = lock.withLock {
            passiveMode = mode
            var t: Timer?
            if passiveMode {
                t = handler.activeModeTimer
                handler.activeModeTimer = nil
            }
            return (passiveMode ? monitoredPeripheral : nil, t)
        }

        // invalidate 派发回主线程（Timer 注册在主 RunLoop）
        if let t = oldTimer { DispatchQueue.main.async { t.invalidate() } }
        if let p = peripheralToCancel {
            centralMgr.cancelPeripheralConnection(p)
        }
        scanForPeripherals()
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
        // invalidate 派发回主线程（Timer 注册在主 RunLoop）
        for t in timers { DispatchQueue.main.async { t.invalidate() } }
    }

    /// 锁内按 id 取设备并转为不可变快照，供统一派发点复用
    func snapshotLocked(for deviceId: UUID) -> DeviceSnapshot? {
        lock.withLock {
            guard let device = devices[deviceId] else { return nil }
            return device.toSnapshot(isMonitored: monitoredUUID == deviceId)
        }
    }

    /// 设备发现超时计时器：超时后移除设备并通知宿主 UI
    func resetScanTimer(device: Device, timeout: TimeInterval) {
        // 旧 scanTimer：锁内取引用并清空，invalidate 派发回主线程（Timer 注册在主 RunLoop）
        let oldTimer: Timer? = lock.withLock {
            let t = device.scanTimer
            device.scanTimer = nil
            return t
        }
        if let t = oldTimer { DispatchQueue.main.async { t.invalidate() } }
        let uuid = device.uuid
        // peripheral 在闭包外提前取出（Sendable），避免 @Sendable Timer 闭包捕获非 Sendable 的 device
        let peripheral = device.peripheral
        let timer = Timer(timeInterval: timeout, repeats: false, block: { [weak self] timer in
            // 闭包只捕获 uuid（Sendable）；device 在 lock 保护下原子取出并移除，
            // 锁内即刻转成不可变快照，杜绝堆引用跨 Actor 共享，再派发主线程
            guard let self = self else { return }
            // 过期 fire 丢弃：设备已由新广播换新 scanTimer（防置换后旧 fire 重复移除）
            let isCurrent = self.lock.withLock { self.devices[uuid]?.scanTimer === timer }
            guard isCurrent else { return }
            if let p = peripheral {
                self.centralMgr.cancelPeripheralConnection(p)
            }
            let snapshot: DeviceSnapshot? = self.lock.withLock {
                guard let device = self.devices.removeValue(forKey: uuid) else { return nil }
                return device.toSnapshot(isMonitored: self.monitoredUUID == uuid)
            }
            if let snapshot {
                Task { @MainActor [weak self] in
                    self?.host?.bleDelegate?.removeDevice(device: snapshot)
                }
            }
            // 防泄漏：设备过期时清理节流记录（派发到 bleQueue 串行队列保证线程安全）
            self.queue.async { [weak self] in
                self?.lastUIUpdateTime.removeValue(forKey: uuid)
            }
        })
        RunLoop.main.add(timer, forMode: .common)
        lock.withLock { device.scanTimer = timer }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logDebug(component: "FUn", "[DIAG] centralManagerDidUpdateState - state=\(central.state.rawValue), authorization=\(CBManager.authorization.rawValue)")
        switch central.state {
        case .poweredOn:
            Log.ble.debug("Bluetooth powered on")
            // activeModeTimer 锁内快照（修复锁外读 vs 锁内写竞态）
            if lock.withLock({ handler.activeModeTimer == nil }) {
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

        // 监控上下文与 scanMode 一次锁内快照（修复 monitoredUUIDs 锁外 contains 与
        // scanMode 锁外读的竞态）
        let monitorInfo: (monitoredUUID: UUID?, isInList: Bool, uuidCount: Int, scanMode: Bool) = lock.withLock {
            (monitoredUUID, monitoredUUIDs.contains(peripheral.identifier), monitoredUUIDs.count, scanMode)
        }
        throttledBleLog("didDiscover", interval: 1.0, "[DEBUG] didDiscover \(peripheral.name ?? "unknown") rssi=\(rssi) inList=\(monitorInfo.isInList) monitoredUUID=\(monitorInfo.monitoredUUID != nil ? "set" : "nil") uuidCount=\(monitorInfo.uuidCount)")
        let scanTimerTimeout = host?.scannerDeviceScanTimeout(self) ?? Self.defaultDeviceScanTimeout

        // 监控设备分支：上报宿主并确保连接（见 BLEPeripheralHandler）
        handler.handleMonitoredAdvertisement(peripheral, rssi: rssi)

        // 优化 1：监控模式下，非目标设备直接丢弃
        if monitorInfo.monitoredUUID != nil && !monitorInfo.isInList {
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
