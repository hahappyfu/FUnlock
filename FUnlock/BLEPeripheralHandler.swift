import Foundation
@preconcurrency import CoreBluetooth
import os

/// BLE 外设连接与 RSSI 轮询驱动（自 BLEScanner 抽离，保持单文件 <300 行）：
/// - 连接生命周期：connectMonitoredPeripheral / 连接超时兜底 / didConnect / didDisconnect
/// - 主动模式轮询：restartActiveModeTimer + didReadRSSI 中的自适应轮询状态机
///   （接近窗口快速轮询 0.5s / 平稳 2s / 静置 8s，区间由宿主 scannerPollingContext 判定）
/// - 设备信息服务发现：didDiscoverServices / didDiscoverCharacteristicsFor / didUpdateValueFor
///
/// 线程契约（@unchecked Sendable 依据）：
/// - 所有回调（CBCentralManager 转发与 CBPeripheralDelegate）运行在串行 `scanner.queue`（bleQueue）上；
/// - 轮询状态（activeModeTimer / connectionTimer / stableCount / activePollInterval /
///   lastEstimatedRSSI / lastReadAt）与扫描器共享状态统一由与宿主共用的 `lock`（UnfairLock）保护，
///   宿主在锁内直接读写这些字段，以保持 startMonitor / unbindAllState 等跨对象复位的原子性；
/// - Device 字段（manufacture/model/rssi 等）的修改与比较统一在锁内完成；
/// - Timer 注册在主 RunLoop；invalidate 派发回主线程（Timer 必须在其注册线程 invalidate），
///   fire block 内的自停/置换用 block 参数并配 `===` 身份校验，防过期 fire 误伤新状态；
/// - 对宿主的回调经由 `scanner.host`（BLEScannerHost）。
final class BLEPeripheralHandler: NSObject, CBPeripheralDelegate, @unchecked Sendable {
    private let lock: UnfairLock
    private weak var scanner: BLEScanner?

    // MARK: - 轮询状态（与宿主共用 `lock` 保护，定时收编进宿主的 LiveDeadlineScheduler）

    var stableCount: Int = 0
    var activePollInterval: TimeInterval = 2.0
    var lastEstimatedRSSI: Int = 0
    var lastReadAt = 0.0

    var isActiveModeActive: Bool {
        scanner?.host?.scheduler.isScheduled(.activePoll) == true
    }

    /// 快速轮询间隔（s）：信号接近阈值时降低感知延迟
    private static let fastPollInterval: TimeInterval = 0.5

    /// 主动轮询回退被动模式的超时（s）：至少覆盖 2.5 个轮询周期。
    /// 旧硬编码 10s 不足以覆盖 8s 档的一个完整周期，轻微丢读就被误判断流。
    static func fallbackTimeout(forPollInterval pollInterval: TimeInterval) -> TimeInterval {
        max(12.0, pollInterval * 2.5)
    }

    /// 立即补采一次 RSSI 并切到快轮询档：锁屏结算前的确认样本，避免单样本骤降误锁。
    /// 调用方不得持锁（内部取锁并调用 CoreBluetooth）。
    func triggerImmediateRSSIProbe() {
        guard let scanner = scanner else { return }
        let peripheral: CBPeripheral? = lock.withLock {
            if activePollInterval > Self.fastPollInterval {
                activePollInterval = Self.fastPollInterval
                stableCount = 0
            }
            return scanner.monitoredPeripheral
        }
        if peripheral?.state == .connected {
            peripheral?.readRSSI()
        }
    }

    init(lock: UnfairLock, scanner: BLEScanner) {
        self.lock = lock
        self.scanner = scanner
        super.init()
    }

    // MARK: - 连接生命周期

    func connectMonitoredPeripheral() {
        guard let scanner = scanner, let p = lock.withLock({ scanner.monitoredPeripheral }) else { return }

        // Idk why but this works like a charm when 'didConnect' won't get called.
        // However, this generates warnings in the log.
        p.readRSSI()

        guard p.state == .disconnected else { return }
        AppLog.info(.ble, "connecting", [("id", "\(p.identifier)")])
        scanner.centralMgr.connect(p, options: nil)
        scanner.host?.scheduler.scheduleAfter(.peripheralConnectTimeout, interval: 60.0)
    }

    func handleConnectionTimeout() {
        guard let scanner else { return }
        scanner.queue.async { [weak self] in
            guard let self, let scanner = self.scanner else { return }
            let p = self.lock.withLock { scanner.monitoredPeripheral }
            if let p, p.state == .connecting {
                AppLog.error(.ble, "connectionTimeout", [("id", "\(p.identifier)")])
                scanner.centralMgr.cancelPeripheralConnection(p)
            }
        }
    }

    private func restartActiveModeTimer(peripheral: CBPeripheral) {
        let pollInterval: TimeInterval = lock.withLock { activePollInterval }
        scanner?.host?.scheduler.scheduleAfter(.activePoll, interval: pollInterval)
        _ = peripheral
    }

    func handleActivePollTick() {
        guard let scanner else { return }
        scanner.queue.async { [weak self] in
            guard let self, let scanner = self.scanner else { return }
            let snapshot: (peripheral: CBPeripheral?, pollInterval: TimeInterval, lastRead: TimeInterval, passive: Bool) = self.lock.withLock {
                (scanner.monitoredPeripheral, self.activePollInterval, self.lastReadAt, scanner.passiveMode)
            }
            guard let peripheral = snapshot.peripheral, !snapshot.passive else { return }
            if Date().timeIntervalSince1970 > snapshot.lastRead + Self.fallbackTimeout(forPollInterval: snapshot.pollInterval) {
                AppLog.info(.ble, "fallbackToPassiveMode", [("id", "\(peripheral.identifier)")])
                scanner.centralMgr.cancelPeripheralConnection(peripheral)
                scanner.host?.scheduler.cancel(.activePoll)
                scanner.scanForPeripherals()
            } else if peripheral.state == .connected {
                peripheral.readRSSI()
                scanner.host?.scheduler.scheduleAfter(.activePoll, interval: snapshot.pollInterval)
            } else {
                self.connectMonitoredPeripheral()
            }
        }
    }

    /// 只取消主动模式与连接计时器，保留心跳和信号超时链用于检测离场
    func invalidateAllTimers() {
        scanner?.host?.scheduler.cancel(.activePoll)
        scanner?.host?.scheduler.cancel(.peripheralConnectTimeout)
    }

    // MARK: - 中央管理器转发

    /// 扫描回调命中监控设备：更新 monitoredPeripheral 引用、上报宿主并确保连接
    /// （自 BLEScanner.didDiscover 的 monitored 分支移入）
    func handleMonitoredAdvertisement(_ peripheral: CBPeripheral, rssi: Int) {
        guard let scanner = scanner else { return }
        let isMonitored: Bool = lock.withLock {
            guard scanner.monitoredUUIDs.contains(peripheral.identifier) else { return false }
            let match = peripheral.identifier == scanner.monitoredUUID
            if match && scanner.monitoredPeripheral == nil {
                scanner.monitoredPeripheral = peripheral
            }
            return match
        }
        guard isMonitored else { return }
        // 扫描回调：上报宿主更新 presence 和锁定判断
        scanner.host?.scanner(scanner, didSampleMonitoredRSSI: rssi)
        let shouldConnect = lock.withLock { !scanner.passiveMode } && !isActiveModeActive
        if shouldConnect {
            connectMonitoredPeripheral()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let scanner = scanner else { return }
        peripheral.delegate = self
        // scanMode 与 monitoredPeripheral 比较统一锁内快照（修复锁外读/锁外比较竞态）
        let (shouldDiscover, shouldActivate): (Bool, Bool) = lock.withLock {
            // 同 UUID 的新 CBPeripheral 实例可能不等于旧对象，按 identifier 匹配并刷新引用
            let isMonitored = peripheral.identifier == scanner.monitoredUUID
                || peripheral.identifier == scanner.monitoredPeripheral?.identifier
            if peripheral.identifier == scanner.monitoredUUID {
                scanner.monitoredPeripheral = peripheral
            }
            return (scanner.scanMode, isMonitored && !scanner.passiveMode)
        }
        if shouldDiscover {
            peripheral.discoverServices([BLEUUIDs.deviceInformation])
        }
        if shouldActivate {
            AppLog.info(.ble, "connected", [("id", "\(peripheral.identifier)")])
            scanner.host?.scheduler.cancel(.peripheralConnectTimeout)
            // 优化 4：主动模式已连接，停掉全局扫描
            scanner.centralMgr.stopScan()
            peripheral.readRSSI()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let scanner = scanner else { return }
        AppLog.info(.ble, "disconnected", [("id", "\(peripheral.identifier)"), ("error", error?.localizedDescription)])
        // 同 UUID 的新 CBPeripheral 实例可能不等于旧对象，按 identifier 匹配防漏触发重扫
        let isMonitored = lock.withLock {
            peripheral.identifier == scanner.monitoredUUID ||
            peripheral.identifier == scanner.monitoredPeripheral?.identifier
        }
        if isMonitored {
            invalidateAllTimers()
            // 不立即锁屏 — BLE 连接可能因干扰短暂断开
            // 由心跳衰减机制判断：设备真正离开后 ~10 秒锁屏
            scanner.host?.scannerDidDisconnectMonitored(scanner)
            // 恢复扫描，尝试重新发现设备
            scanner.scanForPeripherals()
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard let scanner = scanner else { return }
        guard error == nil else {
            AppLog.error(.ble, "readRSSIError", [("error", error?.localizedDescription)])
            return
        }
        // 127 为不可用哨兵；任何非负值与越界值都必须丢弃，不能钳成 0 dBm
        guard let rssi = BLEScanner.sanitizeRSSI(RSSI.intValue) else {
            AppLog.error(.ble, "invalidRSSI", [("raw", "\(RSSI.intValue)"), ("id", "\(peripheral.identifier)")])
            return
        }
        let shouldProcess: Bool = lock.withLock {
            guard peripheral.identifier == scanner.monitoredUUID else { return false }
            if scanner.monitoredPeripheral == nil { scanner.monitoredPeripheral = peripheral }
            return true
        }
        guard shouldProcess else { return }
        guard let host = scanner.host else { return }
        host.scanner(scanner, didSampleMonitoredRSSI: rssi)

        let polling = host.scannerPollingContext(scanner)

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

        let activeOn = isActiveModeActive
        let scanModeOn = lock.withLock { scanner.scanMode }
        let shouldStartActiveMode = lock.withLock { !activeOn && !scanner.passiveMode }
        if shouldStartActiveMode {
            AppLog.info(.ble, "enterActiveMode", [("id", "\(peripheral.identifier)")])
            if !scanModeOn {
                scanner.centralMgr.stopScan()
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
        guard let scanner = scanner else { return }
        if let value = characteristic.value {
            let str: String? = String(data: value, encoding: .utf8)
            if let s = str {
                let deviceId = peripheral.identifier
                // Device 字段修改与 monitoredPeripheral 比较统一在锁内完成
                // （修复锁外写/锁内读竞态）；快照派发在锁外（锁内已转纯值）
                let changed: Bool = lock.withLock {
                    guard let device = scanner.devices[deviceId] else { return false }
                    if characteristic.uuid == BLEUUIDs.manufacturerName {
                        device.manufacture = s
                    }
                    if characteristic.uuid == BLEUUIDs.modelName {
                        device.model = s
                    }
                    if device.model != nil && device.manufacture != nil
                        && device.peripheral?.identifier != scanner.monitoredPeripheral?.identifier {
                        scanner.centralMgr.cancelPeripheralConnection(peripheral)
                    }
                    return true
                }
                guard changed else { return }
                // 闭包只捕获 peripheral.identifier（Sendable），快照在锁内按 id 生成
                Task { @MainActor [weak self] in
                    guard let self = self, let scanner = self.scanner else { return }
                    if let snapshot = scanner.snapshotLocked(for: deviceId) {
                        scanner.host?.bleDelegate?.updateDevice(device: snapshot)
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
