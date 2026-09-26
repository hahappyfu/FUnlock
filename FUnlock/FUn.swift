import Foundation
@preconcurrency import CoreBluetooth
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
/// 设备事件（newDevice/updateDevice/removeDevice）统一携带不可变纯值 `DeviceSnapshot`，
/// 由派发方在 `lock` 保护下调用 `Device.toSnapshot(isMonitored:)` 生成，杜绝堆引用跨 Actor 共享。
/// FUn 内部派发时统一通过 `Task { @MainActor [weak self] in ... }` 跨回主线程。
@MainActor
protocol FUnDelegate: AnyObject {
    func newDevice(device: DeviceSnapshot)
    func updateDevice(device: DeviceSnapshot)
    func removeDevice(device: DeviceSnapshot)
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
/// - lockRSSI / unlockRSSI / thresholdRSSI 经 computed 访问器自动走 lock
///   （UnfairLock 不可重入，锁内上下文须直接读 `_lockRSSI` / `_unlockRSSI` 私有存储）；
/// - Timer 统一注册在主 RunLoop；invalidate 必须在其注册线程执行——置换路径
///   在锁内取引用并清空字段，invalidate 派发回主线程（fire block 内自停直接主线程调用）；
/// - 向 `delegate`（@MainActor 协议）的派发统一走 `Task { @MainActor [weak self] }` 跨回主线程。
class FUn: NSObject, @unchecked Sendable, BLEScannerHost {
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
    /// 解锁阈值（dBm）：主线程写（设置界面）/ bleQueue 判定读，统一走 lock 保护的私有存储——
    /// computed getter/setter 自带锁，外部裸读写无需改调用点。
    /// 注意：UnfairLock 不可重入，锁内上下文直接访问 `_unlockRSSI`（如 scannerPollingContext）。
    var unlockRSSI: Int {
        get { lock.withLock { _unlockRSSI } }
        set { lock.withLock { _unlockRSSI = newValue } }
    }
    private(set) var _unlockRSSI = -60
    /// 锁定阈值（dBm）：与 unlockRSSI 同模式，computed 访问器自带锁（锁内用 `_lockRSSI`）
    var lockRSSI: Int {
        get { lock.withLock { _lockRSSI } }
        set { lock.withLock { _lockRSSI = newValue } }
    }
    private(set) var _lockRSSI = -80
    var proximityTimeout = 5.0
    var signalTimeout = 60.0
    private var powerWarn = true
    /// 设备发现入库的最低信号门限（AppDelegate 从偏好写入；读写转发到 BLEScanner 并统一走 lock，
    /// 修复此前独立存储导致偏好写入被丢弃、扫描侧仍用默认值的问题）。
    /// 默认 -100：与最低可配置解锁阈值（-100）对齐——此前默认 -90 会导致解锁阈值放宽到 -100 时
    /// 可解锁设备先被列表门限过滤、永不出现
    var thresholdRSSI: Int {
        get { lock.withLock { scanner.thresholdRSSI } }
        set { lock.withLock { scanner.thresholdRSSI = newValue } }
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
        // 共享状态复位与 Timer 引用置换在锁内原子完成；需锁外操作的旧引用（peripheral）取出后，
        // Timer 的 invalidate 派发回主线程（Timer 注册在主 RunLoop，invalidate 必须在其注册线程执行）
        let oldPeripheral: CBPeripheral?
        let oldTimers: [Timer]
        (oldPeripheral, oldTimers) = lock.withLock {
            let old = scanner.monitoredUUID != uuid ? scanner.monitoredPeripheral : nil

            // 重置所有共享状态
            scanner.monitoredUUID = uuid
            scanner.scanMode = true
            // presence 不强制置 true：绑定后须信号实际达到解锁阈值（checkProximity）才标记在场，
            // 避免"设备从未靠近"（如忘带手表）时因 presence 残留触发锁屏
            presence = false
            scanner.monitoredPeripheral = nil
            var timers: [Timer] = []
            if let t = scanner.handler.activeModeTimer { timers.append(t) }
            scanner.handler.activeModeTimer = nil
            if let t = scanner.handler.connectionTimer { timers.append(t) }
            scanner.handler.connectionTimer = nil
            if let t = signalTimer { timers.append(t) }
            signalTimer = nil
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
            return (old, timers)
        }
        for t in oldTimers { DispatchQueue.main.async { t.invalidate() } }

        // proximityTimer 置换：锁内取引用并清空，invalidate 派发回主线程
        let oldProximity: Timer? = lock.withLock {
            let t = proximityTimer
            proximityTimer = nil
            return t
        }
        if let t = oldProximity { DispatchQueue.main.async { t.invalidate() } }
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
        // Timer 的 invalidate 必须在其注册线程（主 RunLoop）执行：锁内取引用并清空，
        // invalidate 派发回主线程（本方法可被 bleQueue 的 scannerDidPowerOff 调用）
        let timers: [Timer] = lock.withLock {
            var collected: [Timer] = []
            if let t = signalTimer { collected.append(t); signalTimer = nil }
            if let t = proximityTimer { collected.append(t); proximityTimer = nil }
            if let t = heartbeatTimer { collected.append(t); heartbeatTimer = nil }
            return collected
        }
        for t in timers { DispatchQueue.main.async { t.invalidate() } }
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
            // 注意：锁内只能读私有阈值存储并内联派生（unlockStairThreshold 等 computed 属性
            // 内部会取锁，UnfairLock 不可重入，不能嵌套调用）
            let isNear: Bool
            if _unlockRSSI != SignalHysteresisEngine.unlockDisabled {
                let trigger = SignalHysteresisEngine.offsetSetting("preUnlockTrigger", default: Self.defaultPreUnlockTrigger)
                let stair = _unlockRSSI - trigger
                let nearClimb = SignalHysteresisEngine.isNearThreshold(effectiveRSSI, threshold: Double(stair))
                let lockThreshold = SignalHysteresisEngine.resolvedLockThreshold(unlockRSSI: _unlockRSSI, lockRSSI: _lockRSSI)
                let nearLock = SignalHysteresisEngine.isNearThreshold(effectiveRSSI, threshold: Double(lockThreshold))
                isNear = nearClimb || nearLock
            } else if _lockRSSI != SignalHysteresisEngine.lockDisabled {
                isNear = SignalHysteresisEngine.isNearThreshold(effectiveRSSI, threshold: Double(_lockRSSI))
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
