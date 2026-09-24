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

/// BLE 中央管理器（协调 Facade）。
/// 状态机细节拆分：锁定时延/心跳/信号超时见 `FUnLockCoordinator.swift`，
/// 信号处理/在场判定/共享状态快照见 `FUnSignalProcessor.swift`。
/// 线程契约（@unchecked Sendable 依据）：
/// - CBCentralManager 回调与设备扫描在串行 `bleQueue` 上执行，跨线程共享状态
///   （devices / monitoredUUID / presence / pipeline 等）统一由 `lock`（UnfairLock）保护；
///   同一把 `lock` 传入 BLEScanner / BLEPeripheralHandler，三方在锁内直接读写共享字段
///   以保持 startMonitor / unbindAllState 等跨对象复位的原子性；
/// - Timer 操作与 `@Published`（lockRSSI/unlockRSSI）读写收敛在主 RunLoop 与主线程；
/// - 向 `delegate`（@MainActor 协议）的派发统一走 `Task { @MainActor [weak self] }` 跨回主线程。
class FUn: NSObject, ObservableObject, @unchecked Sendable, BLEScannerHost {
    static let UNLOCK_DISABLED = SignalHysteresisEngine.unlockDisabled
    static let LOCK_DISABLED = SignalHysteresisEngine.lockDisabled
    let bleQueue = DispatchQueue(label: "com.funlock.ble")
    let lock = UnfairLock()
    private(set) var scanner: BLEScanner!
    var centralMgr: CBCentralManager! { scanner.centralMgr }
    var devices: [UUID: Device] {
        get { scanner.devices }
        set { scanner.devices = newValue }
    }
    weak var delegate: FUnDelegate?
    var inputMonitor: InputActivityMonitor?

    /// 用户是否有输入活动（nil-safe，线程安全）
    var isUserInputActive: Bool {
        inputMonitor?.isActive == true
    }

    var monitoredUUID: UUID? {
        get { scanner.monitoredUUID }
        set { scanner.monitoredUUID = newValue }
    }
    var presence = false
    @Published var lockRSSI = -80
    @Published var unlockRSSI = -60
    var proximityTimeout = 5.0
    var signalTimeout = 60.0
    private var powerWarn = true
    /// 设备发现入库的最低信号门限（AppDelegate 从偏好写入；读写转发到 BLEScanner，
    /// 修复此前独立存储导致偏好写入被丢弃、扫描侧仍用默认值的问题）
    var thresholdRSSI: Int {
        get { scanner.thresholdRSSI }
        set { scanner.thresholdRSSI = newValue }
    }
    // 管道状态 (替代旧的散装字段)
    var pipeline = SignalPipeline()
    var effectiveRSSI: Double = -60.0
    var displayRSSI: Double = -60.0
    /// EMA 平滑 RSSI（alpha=0.3），用于预备唤醒阈值判断
    var smoothedRSSIValue: Double = -100.0
    let smoothedRSSIAlpha: Double = 0.3
    var lastReceiveTime: Date = Date()
    var lastSignalAnomalous: Bool = false
    // Heartbeat timer (独立状态机，不在管道内)
    var heartbeatTimer: Timer?
    var lastHeartbeatInterval: TimeInterval = 2.0
    var signalLostCount: Int = 0
    // 冷静期：解锁后短时间内不触发锁定，防止振荡
    var lastProximityEventTime: Date = .distantPast
    let proximityGracePeriod: TimeInterval = 5.0
    var proximityTimer: Timer?
    var signalTimer: Timer?

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
            let old = scanner.monitoredUUID != uuid ? scanner.monitoredPeripheral : nil

            // 重置所有共享状态
            scanner.monitoredUUID = uuid
            scanner.scanMode = true
            // presence 不强制置 true：绑定后须信号实际达到解锁阈值（checkProximity）才标记在场，
            // 避免"设备从未靠近"（如忘带手表）时因 presence 残留触发锁屏
            presence = false
            scanner.monitoredPeripheral = nil
            scanner.handler.activeModeTimer?.invalidate()
            scanner.handler.activeModeTimer = nil
            scanner.handler.connectionTimer?.invalidate()
            scanner.handler.connectionTimer = nil
            scanner.handler.stableCount = 0
            scanner.handler.activePollInterval = 2.0
            scanner.handler.lastEstimatedRSSI = 0
            signalLostCount = 0
            pipeline.reset()
            lastReceiveTime = Date()
            effectiveRSSI = -60.0
            displayRSSI = -60.0
            smoothedRSSIValue = -100.0
            scanner.monitoredUUIDs = [uuid]
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
            lock.withLock { scanner.monitoredPeripheral = peripheral }
            if peripheral.state == .disconnected {
                centralMgr.connect(peripheral, options: nil)
            }
        }

        scanForPeripherals()
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
        scanner?.handler.invalidateAllTimers()
    }

    func invalidateAllDeviceTimers() {
        scanner?.invalidateAllDeviceTimers()
    }

    func resetScanTimer(device: Device) {
        scanner.resetScanTimer(device: device, timeout: signalTimeout)
    }

    func connectMonitoredPeripheral() {
        scanner.handler.connectMonitoredPeripheral()
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
        // 锁内复位信号丢失计数（与 resetSignalTimer / markSignalLost 的读写保持同锁）
        lock.withLock { signalLostCount = 0 }
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

    /// 轮询自适应上下文：卡尔曼估计 + 是否处于快速轮询接近窗口。
    /// 三段式判定（对齐重构前语义）：
    /// 1. 解锁开启：走近方向的解锁爬升区 [stair-window, stair) 即启用快速轮询——
    ///    用户从远处走回时若只按锁定阈值触发，爬升区用 8s 慢采样会出现"走到面前等几十秒"；
    /// 2. 解锁禁用但锁定阈值有效：按锁定阈值判定接近窗口；
    /// 3. 两者皆禁用：不做快速轮询。
    func scannerPollingContext(_ scanner: BLEScanner) -> BLEScanner.PollingContext {
        let (k, near) = lock.withLock {
            let isNear: Bool
            if unlockRSSI != SignalHysteresisEngine.unlockDisabled {
                let nearClimb = SignalHysteresisEngine.isNearThreshold(effectiveRSSI, threshold: Double(unlockStairThreshold))
                let lockThreshold = lockRSSI == SignalHysteresisEngine.lockDisabled ? unlockRSSI : lockRSSI
                let nearLock = SignalHysteresisEngine.isNearThreshold(effectiveRSSI, threshold: Double(lockThreshold))
                isNear = nearClimb || nearLock
            } else if lockRSSI != SignalHysteresisEngine.lockDisabled {
                isNear = SignalHysteresisEngine.isNearThreshold(effectiveRSSI, threshold: Double(lockRSSI))
            } else {
                isNear = false
            }
            return (pipeline.kalmanEstimate, isNear)
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
