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
/// - Timer 操作在主 RunLoop；对宿主的回调经由 `scanner.host`（BLEScannerHost）。
final class BLEPeripheralHandler: NSObject, CBPeripheralDelegate, @unchecked Sendable {
    private let lock: UnfairLock
    private weak var scanner: BLEScanner?

    // MARK: - 轮询状态（与宿主共用 `lock` 保护）

    var activeModeTimer: Timer?
    var connectionTimer: Timer?
    var stableCount: Int = 0
    var activePollInterval: TimeInterval = 2.0
    var lastEstimatedRSSI: Int = 0
    var lastReadAt = 0.0

    /// 快速轮询间隔（s）：信号接近阈值时降低感知延迟
    private static let fastPollInterval: TimeInterval = 0.5

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
        Log.ble.debug("Connecting")
        scanner.centralMgr.connect(p, options: nil)
        connectionTimer?.invalidate()
        let connTimer = Timer(timeInterval: 60, repeats: false, block: { [weak self] _ in
            if p.state == .connecting {
                Log.ble.error("Connection timeout")
                self?.scanner?.centralMgr.cancelPeripheralConnection(p)
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
                self.scanner?.centralMgr.cancelPeripheralConnection(peripheral)
                self.lock.withLock {
                    self.activeModeTimer?.invalidate()
                    self.activeModeTimer = nil
                }
                self.scanner?.scanForPeripherals()
            } else if peripheral.state == .connected {
                peripheral.readRSSI()
            } else {
                self.connectMonitoredPeripheral()
            }
        })
        RunLoop.main.add(timer, forMode: .common)
        lock.withLock { activeModeTimer = timer }
    }

    /// 只取消主动模式与连接计时器，保留心跳和信号超时链用于检测离场
    func invalidateAllTimers() {
        lock.withLock {
            activeModeTimer?.invalidate()
            activeModeTimer = nil
            connectionTimer?.invalidate()
            connectionTimer = nil
        }
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
        let shouldConnect: Bool = lock.withLock { self.activeModeTimer == nil && !scanner.passiveMode }
        if shouldConnect {
            connectMonitoredPeripheral()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let scanner = scanner else { return }
        peripheral.delegate = self
        if scanner.scanMode {
            peripheral.discoverServices([BLEUUIDs.deviceInformation])
        }
        let shouldActivate: Bool = lock.withLock {
            peripheral == scanner.monitoredPeripheral && !scanner.passiveMode
        }
        if shouldActivate {
            Log.ble.debug("Connected")
            lock.withLock {
                connectionTimer?.invalidate()
                connectionTimer = nil
            }
            // 优化 4：主动模式已连接，停掉全局扫描
            scanner.centralMgr.stopScan()
            peripheral.readRSSI()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let scanner = scanner else { return }
        Log.ble.debug("didDisconnectPeripheral: \(peripheral.identifier)")
        if peripheral == scanner.monitoredPeripheral {
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
        let shouldProcess: Bool = lock.withLock {
            guard peripheral.identifier == scanner.monitoredUUID else { return false }
            if scanner.monitoredPeripheral == nil { scanner.monitoredPeripheral = peripheral }
            return true
        }
        guard shouldProcess else { return }
        let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
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

        let shouldStartActiveMode = lock.withLock { activeModeTimer == nil && !scanner.passiveMode }
        if shouldStartActiveMode {
            Log.ble.debug("Entering active mode")
            if !scanner.scanMode {
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
                if let device = lock.withLock({ scanner.devices[peripheral.identifier] }) {
                    // 闭包只捕获 peripheral.identifier（Sendable），device 在闭包内按 id 取锁内快照
                    let deviceId = peripheral.identifier
                    if characteristic.uuid == BLEUUIDs.manufacturerName {
                        device.manufacture = s
                        Task { @MainActor [weak self] in
                            guard let self = self, let scanner = self.scanner else { return }
                            // 闭包只捕获 deviceId（Sendable）；device 在锁内取值并立刻转为不可变快照再派发
                            let snapshot: DeviceSnapshot? = self.lock.withLock {
                                guard let device = scanner.devices[deviceId] else { return nil }
                                return device.toSnapshot(isMonitored: scanner.monitoredUUID == deviceId)
                            }
                            if let snapshot {
                                scanner.host?.bleDelegate?.updateDevice(device: snapshot)
                            }
                        }
                    }
                    if characteristic.uuid == BLEUUIDs.modelName {
                        device.model = s
                        Task { @MainActor [weak self] in
                            guard let self = self, let scanner = self.scanner else { return }
                            // 闭包只捕获 deviceId（Sendable）；device 在锁内取值并立刻转为不可变快照再派发
                            let snapshot: DeviceSnapshot? = self.lock.withLock {
                                guard let device = scanner.devices[deviceId] else { return nil }
                                return device.toSnapshot(isMonitored: scanner.monitoredUUID == deviceId)
                            }
                            if let snapshot {
                                scanner.host?.bleDelegate?.updateDevice(device: snapshot)
                            }
                        }
                    }
                    if device.model != nil && device.manufacture != nil && device.peripheral != scanner.monitoredPeripheral {
                        scanner.centralMgr.cancelPeripheralConnection(peripheral)
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
