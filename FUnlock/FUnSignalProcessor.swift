import Foundation
@preconcurrency import CoreBluetooth
import os

/// updateRSSI 主线程派发节流器：快速轮询期（~2Hz/0.5s）每个采样都向 @MainActor 派发一次
/// UI 更新，纯数字刷新对 1dB 内的抖动无感，高频派发徒增主线程负载。
/// 去重规则：展示 RSSI 与上次派发值相同、或距上次派发 < 0.25s 且变化 ≤ 1dB 时跳过；
/// active（连接态）变化、或 presence 翻转瞬间（force）无条件放行保证 UI 及时。
/// 单例安全：displayRSSI 派发仅来自 bleQueue（串行）上的 checkProximity，且全 App 仅一个 FUn 实例；
/// 与 FUn.swift 的 bleLogThrottler 同源设计（私有 final class + 自带锁，消除裸全局可变状态）。
private final class DisplayRSSIDispatchThrottler: @unchecked Sendable {
    private let lock = NSLock()
    private var lastInt: Int?
    private var lastActive = false
    private var lastTime = Date.distantPast

    /// 需要派发返回 true 并更新缓存，否则跳过。
    func shouldDispatch(_ rssi: Int, active: Bool, force: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if !force, let last = lastInt, active == lastActive {
            if rssi == last { return false }
            if now.timeIntervalSince(lastTime) < 0.25 && abs(rssi - last) <= 1 { return false }
        }
        lastInt = rssi
        lastActive = active
        lastTime = now
        return true
    }

    /// 解绑/重置时清空缓存，确保下次绑定后首个采样必然派发。
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastInt = nil
        lastActive = false
        lastTime = .distantPast
    }
}

private let displayRSSIDispatchThrottler = DisplayRSSIDispatchThrottler()

/// FUn 的信号处理与在场判定层（自 FUn.swift 抽离，保持单文件 <300 行）：
/// - 原始 RSSI 采样摄入：updateMonitoredPeripheral / processSignal（管道滤波 + 样本落库 + 预唤醒单驱动）
/// - 显示平滑与预唤醒 EMA：updateDisplayRSSI / smoothedRSSI（时间归一化 EMA，仅在 processSignal 单驱动，供阶梯唤醒阈值判断）
/// - 在场判定：checkProximity（快速解锁分支，锁定决策转发 FUnLockCoordinator.applyLockTimer）
/// - 共享状态快照与锁内访问器：SignalSnapshot / signalSnapshot / withDevices / withLockedPeripheral / unbindAllState
///
/// 线程契约：所有共享状态由 FUn.lock（UnfairLock）保护；unlockRSSI/lockRSSI 的判定读
/// 统一锁内成对快照（`_unlockRSSI`/`_lockRSSI`）；向 delegate 的派发统一走 Task { @MainActor }。
/// 预唤醒 EMA 仅由 bleQueue 采样经 processSignal 驱动，主线程等外部消费者仅读 currentSmoothedRSSI。
extension FUn {
    /// 跨线程共享信号状态的锁内快照（Manager/UI 统一走快照，避免逐字段裸读）
    struct SignalSnapshot {
        let effectiveRSSI: Double
        let presence: Bool
        let kalmanEstimate: Double
        let smoothedSlope: Double
        let lastSignalAnomalous: Bool
        let activeModeActive: Bool
    }

    func signalSnapshot() -> SignalSnapshot {
        lock.withLock {
            SignalSnapshot(
                effectiveRSSI: effectiveRSSI,
                presence: presence,
                kalmanEstimate: pipeline.kalmanEstimate,
                smoothedSlope: pipeline.smoothedSlope,
                lastSignalAnomalous: lastSignalAnomalous,
                activeModeActive: scanner.handler.activeModeTimer != nil
            )
        }
    }

    /// 锁内遍历 devices（Manager 解绑/清理时避免裸读字典）
    /// 注意：UnfairLock 不可重入，锁内直访 scanner.devices 裸存储（FUn.devices computed 自带锁）
    func withDevices(_ body: ([UUID: Device]) -> Void) {
        lock.withLock { body(scanner.devices) }
    }

    /// 锁内读取监控的 peripheral 引用（锁外取消连接）
    func withLockedPeripheral() -> CBPeripheral? {
        lock.withLock { scanner.monitoredPeripheral }
    }

    /// 锁内重置解绑状态（unbindDevice 改用它，替代 Manager 无锁覆写）
    func unbindAllState() {
        lock.withLock {
            scanner.monitoredUUID = nil
            scanner.monitoredUUIDs.removeAll()
            scanner.monitoredPeripheral = nil
            scanner.scanMode = false
            presence = false
            signalLostCount = 0
            scanner.handler.stableCount = 0
            scanner.handler.activePollInterval = 2.0
            scanner.handler.lastEstimatedRSSI = 0
            pipeline.reset()
            effectiveRSSI = -60.0
            displayRSSI = -60.0
            smoothedRSSIValue = -100.0
            smoothedLastUpdate = nil
        }
        // 派发节流缓存独立于 FUn.lock（自带 NSLock，非同一把锁，无重入风险），锁外复位即可：
        // 解绑后清空「上次已派发值」，确保重新绑定的首个采样必然刷新 UI
        displayRSSIDispatchThrottler.reset()
    }

    // MARK: - 采样摄入

    func updateMonitoredPeripheral(_ rssi: Int) {
        let now = Date()
        // activeModeTimer 锁内快照（修复锁外读 vs 锁内写竞态；source 与下方日志共用一次快照）
        let isActive = lock.withLock { scanner.handler.activeModeTimer != nil }
        let source: SignalSource = isActive ? .connected : .scanning

        // 1. 信号处理（纯计算）
        let decision = processSignal(rssi: rssi, source: source, now: now)

        // 调试日志：追踪 effectiveRSSI 计算
        throttledBleLog("updateMonitored", interval: 1.0, "[DEBUG] updateMonitored rssi=\(rssi) effectiveRSSI=\(String(format: "%.1f", decision.effectiveRSSI)) kalman=\(String(format: "%.1f", decision.kalmanEstimate)) source=\(source == .connected ? "connected" : "scanning") activeMode=\(isActive)")

        // 2. 更新 displayRSSI
        updateDisplayRSSI(rssi: rssi)

        // 3. 在场检测（基于原始 RSSI 快速解锁）
        checkProximity(rssi: rssi, effectiveRSSI: decision.effectiveRSSI)

        // 4. 锁定决策（锁定判定统一用 decayedEffectiveRSSI 后的有效信号，与心跳路径同源：
        // 采样时刻 elapsed≈0 与 decision.effectiveRSSI 等价，语义见 FUnLockCoordinator 注释）
        applyLockTimer(rssi: rssi, effectiveRSSI: getEffectiveRSSI())

        // 5. 心跳 + 信号超时（resetSignalTimer 幂等：仅首次创建，采样到达时仅刷新 lastReceiveTime）
        ensureHeartbeat()
        resetSignalTimer()
    }

    private func processSignal(rssi: Int, source: SignalSource, now: Date) -> SignalDecision {
        let decision: SignalDecision = lock.withLock {
            // P1 #5 修复：先追加当前 RSSI 再计算，确保斜率包含当前点
            pipeline.latestRSSIs.append(Double(rssi))
            pipeline.rssiTimestamps.append(now)
            // 时间窗随采样间隔自适应（2s/8s 档固定 1.5s 窗只剩 1 个样本，斜率恒 0）；
            // 同时保底保留最近 8 个样本供 IQR 异常检测（固定计数窗，不受时间窗裁剪影响）
            let cutoff = now.addingTimeInterval(-pipeline.effectiveWindowDuration())
            while let first = pipeline.rssiTimestamps.first, first < cutoff,
                  pipeline.rssiTimestamps.count > pipeline.iqrSampleCount {
                pipeline.rssiTimestamps.removeFirst()
                pipeline.latestRSSIs.removeFirst()
            }

            let d = pipeline.process(rssi: rssi, source: source, now: now)

            lastReceiveTime = now
            effectiveRSSI = d.effectiveRSSI
            lastSignalAnomalous = d.isAnomalous
            return d
        }

        // EMA 平滑 RSSI：用于阶梯唤醒阈值判断（单驱动点，时间归一化）
        smoothedRSSI(rssi, now: now)

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

    /// EMA 信号平滑：返回时间归一化指数移动平均 RSSI，用于阶梯唤醒阈值判断
    /// - Parameters:
    ///   - rssi: 原始 RSSI 采样值（dBm，负数）
    ///   - now: 当前采样时间戳
    /// - Returns: 平滑后的 RSSI（dBm）
    @discardableResult
    func smoothedRSSI(_ rssi: Int, now: Date) -> Double {
        lock.withLock {
            let measurement = Double(rssi)
            guard let last = smoothedLastUpdate else {
                smoothedRSSIValue = measurement
                smoothedLastUpdate = now
                return smoothedRSSIValue
            }
            let dt = max(0, now.timeIntervalSince(last))
            let alpha = 1.0 - exp(-dt / Self.preWakeEMATau)
            smoothedRSSIValue = alpha * measurement + (1.0 - alpha) * smoothedRSSIValue
            smoothedLastUpdate = now
            return smoothedRSSIValue
        }
    }

    /// 重置 EMA 平滑 RSSI 到初始值（解绑设备时调用）
    func resetSmoothedRSSI() {
        lock.withLock {
            smoothedRSSIValue = -100.0
            smoothedLastUpdate = nil
        }
    }

    // MARK: - 在场判定

    private func checkProximity(rssi: Int, effectiveRSSI: Double) {
        // 阈值成对快照：锁内一次取两值再计算（修复 unlockRSSI/lockRSSI 裸读竞态与中间态撕裂）
        let (uRSSI, lRSSI): (Int, Int) = lock.withLock { (_unlockRSSI, _lockRSSI) }
        // 解锁禁用（unlockRSSI == UNLOCK_DISABLED）时仍维持 presence 翻转语义（isClose 按 lockRSSI 判定），
        // 但不记 unlocked 事件、不派发 onDeviceApproached（避免假解锁/假唤醒链）
        let unlockEnabled = uRSSI != Self.UNLOCK_DISABLED
        // 用 effectiveRSSI（与 applyLockTimer 同源）判断解锁，避免原始 RSSI 尖峰导致振荡
        let decision = SignalHysteresisEngine.checkProximity(
            rssi: Double(rssi), effectiveRSSI: effectiveRSSI,
            unlockRSSI: uRSSI, lockRSSI: lRSSI)
        var shouldNotifyClose = false

        // 调试日志：追踪 presence 判断条件
        let debugInfo: (isMonitored: Bool, presence: Bool, uuidCount: Int) = lock.withLock {
            // 锁内直访裸存储：FUn.monitoredUUID computed 自带锁，UnfairLock 不可重入
            (scanner.monitoredUUID != nil, presence, scanner.monitoredUUIDs.count)
        }
        throttledBleLog("checkProximity", interval: 1.0, "[DEBUG] checkProximity rssi=\(rssi) effectiveRSSI=\(String(format: "%.1f", effectiveRSSI)) threshold=\(decision.unlockThreshold) monitored=\(debugInfo.isMonitored) presence=\(debugInfo.presence) uuidCount=\(debugInfo.uuidCount)")

        let dispRSSI: Double = lock.withLock {
            let disp = displayRSSI
            let wasPresent = presence
            if decision.isClose && !wasPresent {
                Log.sm.debug("Device is close (eff=\(String(format: "%.1f", effectiveRSSI)))")
                presence = true
                shouldNotifyClose = true
                lastProximityEventTime = Date()
                pipeline.latestRSSIs.removeAll()
                pipeline.rssiTimestamps.removeAll()
            }
            return disp
        }
        let activeMode = lock.withLock { scanner.handler.activeModeTimer != nil }

        if decision.isClose {
            if shouldNotifyClose {
                if unlockEnabled {
                    // P1: 记录解锁事件（解锁禁用时不记，防止 presence 翻转产生假 unlocked 事件）
                    SignalDataStore.shared.record(
                        rawRSSI: Double(rssi), kalmanEstimate: effectiveRSSI,
                        effectiveRSSI: effectiveRSSI, slope: 0, isAnomalous: false,
                        event: .unlocked)
                }
                Task { @MainActor [weak self] in
                    self?.delegate?.updatePresence(presence: true, reason: "close")
                }
            }
            // 到位事件走解锁判定链，不节流（解锁禁用时不派发 approach，避免假解锁/假唤醒链）
            if unlockEnabled {
                Task { @MainActor [weak self] in
                    self?.delegate?.onDeviceApproached()
                }
            }
            // UI 数字刷新走派发节流去重；presence 翻转瞬间（shouldNotifyClose）强制放行保证及时刷新
            let dispInt = Int(dispRSSI)
            if displayRSSIDispatchThrottler.shouldDispatch(dispInt, active: activeMode, force: shouldNotifyClose) {
                Task { @MainActor [weak self] in
                    self?.delegate?.updateRSSI(rssi: dispInt, active: activeMode)
                }
            }
        } else {
            let dispInt = Int(dispRSSI)
            if displayRSSIDispatchThrottler.shouldDispatch(dispInt, active: activeMode, force: false) {
                Task { @MainActor [weak self] in
                    self?.delegate?.updateRSSI(rssi: dispInt, active: activeMode)
                }
            }
        }
    }
}

// MARK: - 阶梯唤醒阈值（由解锁阈值 - 用户偏移派生）

extension FUn {
    /// 默认唤醒提前量（dB）
    static let defaultWakeAdvance = SignalHysteresisEngine.defaultWakeAdvance
    /// 默认预解锁触发量（dB）
    static let defaultPreUnlockTrigger = SignalHysteresisEngine.defaultPreUnlockTrigger
    /// 偏移量允许范围（dB）
    static let offsetRange = SignalHysteresisEngine.offsetRange
    /// 将偏移量钳制到允许范围（UI 可能输入越界值）
    static func clampOffset(_ value: Int) -> Int {
        SignalHysteresisEngine.clampOffset(value)
    }
    /// 方案 A：信号是否处于接近窗口（有效信号进入 [threshold-window, threshold)）
    static func isNearThreshold(_ effectiveRSSI: Double, threshold: Double) -> Bool {
        SignalHysteresisEngine.isNearThreshold(effectiveRSSI, threshold: threshold)
    }
    /// 预备唤醒阈值（dBm）：解锁阈值往更远方向提前 wakeAdvance（UI 可填，默认 20）。
    /// 外推值钳制到物理下限 -100：解锁阈值放宽到 -100 时原始外推值（如 -120）永不可能被信号
    /// 触达，会导致 displaySleeping 下任意信号即触发唤醒
    var preWakeThreshold: Int {
        // 阈值锁内快照（computed 属性自身取锁，此处一次快照避免多次取锁出现中间态撕裂）
        let u = lock.withLock { _unlockRSSI }
        // 哨兵语义：解锁禁用（unlockRSSI == UNLOCK_DISABLED == 1）时原样返回，
        // 调用方（FUnManager+Events）据此跳过阶梯唤醒与预备唤醒
        guard u != Self.UNLOCK_DISABLED else { return u }
        let advance = SignalHysteresisEngine.offsetSetting("wakeAdvance", default: Self.defaultWakeAdvance)
        return max(u - advance, -100)
    }
    /// 预解锁触发阈值（dBm）：解锁阈值往更远方向提前 preUnlockTrigger（UI 可填，默认 10），
    /// 信号进入该接近窗口时启用 0.5s 快速轮询（开足马力探测）；不再直接触发解锁，
    /// 真正解锁由信号达到 unlockRSSI 决定。外推值同样钳制到物理下限 -100
    var unlockStairThreshold: Int {
        let u = lock.withLock { _unlockRSSI }
        // 哨兵语义同上：解锁禁用时原样返回
        guard u != Self.UNLOCK_DISABLED else { return u }
        let trigger = SignalHysteresisEngine.offsetSetting("preUnlockTrigger", default: Self.defaultPreUnlockTrigger)
        return max(u - trigger, -100)
    }
}
