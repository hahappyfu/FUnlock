import Foundation
@preconcurrency import CoreBluetooth
import os

/// FUn 的信号处理与在场判定层（自 FUn.swift 抽离，保持单文件 <300 行）：
/// - 原始 RSSI 采样摄入：updateMonitoredPeripheral / processSignal（管道滤波 + 样本落库）
/// - 显示平滑：updateDisplayRSSI / smoothedRSSI（EMA，供阶梯唤醒阈值判断）
/// - 在场判定：checkProximity（快速解锁分支，锁定决策转发 FUnLockCoordinator.applyLockTimer）
/// - 共享状态快照与锁内访问器：SignalSnapshot / signalSnapshot / withDevices / withLockedPeripheral / unbindAllState
///
/// 线程契约：所有共享状态由 FUn.lock（UnfairLock）保护；向 delegate 的派发统一走 Task { @MainActor }。
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
    func withDevices(_ body: ([UUID: Device]) -> Void) {
        lock.withLock { body(devices) }
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
        }
    }

    // MARK: - 采样摄入

    func updateMonitoredPeripheral(_ rssi: Int) {
        let now = Date()
        let source: SignalSource = (scanner.handler.activeModeTimer != nil) ? .connected : .scanning

        // 1. 信号处理（纯计算）
        let decision = processSignal(rssi: rssi, source: source, now: now)

        // 调试日志：追踪 effectiveRSSI 计算
        let isActive = lock.withLock { scanner.handler.activeModeTimer != nil }
        throttledBleLog("updateMonitored", interval: 1.0, "[DEBUG] updateMonitored rssi=\(rssi) effectiveRSSI=\(String(format: "%.1f", decision.effectiveRSSI)) kalman=\(String(format: "%.1f", decision.kalmanEstimate)) source=\(source == .connected ? "connected" : "scanning") activeMode=\(isActive)")

        // 2. 更新 displayRSSI
        updateDisplayRSSI(rssi: rssi)

        // 3. 在场检测（基于原始 RSSI 快速解锁）
        checkProximity(rssi: rssi, effectiveRSSI: decision.effectiveRSSI)

        // 4. 锁定决策（基于 effectiveRSSI）
        applyLockTimer(rssi: rssi, effectiveRSSI: decision.effectiveRSSI)

        // 5. 心跳 + 信号超时
        ensureHeartbeat()
        resetSignalTimer()
    }

    private func processSignal(rssi: Int, source: SignalSource, now: Date) -> SignalDecision {
        let decision: SignalDecision = lock.withLock {
            // P1 #5 修复：先追加当前 RSSI 再计算，确保斜率包含当前点
            pipeline.latestRSSIs.append(Double(rssi))
            pipeline.rssiTimestamps.append(now)
            let cutoff = now.addingTimeInterval(-pipeline.windowDuration)
            while let first = pipeline.rssiTimestamps.first, first < cutoff {
                pipeline.rssiTimestamps.removeFirst()
                pipeline.latestRSSIs.removeFirst()
            }

            let d = pipeline.process(rssi: rssi, source: source, now: now)

            lastReceiveTime = now
            effectiveRSSI = d.effectiveRSSI
            lastSignalAnomalous = d.isAnomalous
            return d
        }

        // EMA 平滑 RSSI：用于阶梯唤醒阈值判断
        smoothedRSSI(rssi)

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

    /// EMA 信号平滑：返回指数移动平均 RSSI，用于阶梯唤醒阈值判断
    /// - Parameter rssi: 原始 RSSI 采样值（dBm，负数）
    /// - Returns: 平滑后的 RSSI（dBm）
    @discardableResult
    func smoothedRSSI(_ rssi: Int) -> Double {
        lock.withLock {
            let measurement = Double(rssi)
            smoothedRSSIValue = smoothedRSSIAlpha * measurement + (1 - smoothedRSSIAlpha) * smoothedRSSIValue
            return smoothedRSSIValue
        }
    }

    /// 重置 EMA 平滑 RSSI 到初始值（解绑设备时调用）
    func resetSmoothedRSSI() {
        lock.withLock {
            smoothedRSSIValue = -100.0
        }
    }

    // MARK: - 在场判定

    private func checkProximity(rssi: Int, effectiveRSSI: Double) {
        // 用 effectiveRSSI（与 applyLockTimer 同源）判断解锁，避免原始 RSSI 尖峰导致振荡
        let decision = SignalHysteresisEngine.checkProximity(
            rssi: Double(rssi), effectiveRSSI: effectiveRSSI,
            unlockRSSI: unlockRSSI, lockRSSI: lockRSSI)
        var shouldNotifyClose = false

        // 调试日志：追踪 presence 判断条件
        let debugInfo: (isMonitored: Bool, presence: Bool, uuidCount: Int) = lock.withLock {
            (monitoredUUID != nil, presence, scanner.monitoredUUIDs.count)
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
                // P1: 记录解锁事件
                SignalDataStore.shared.record(
                    rawRSSI: Double(rssi), kalmanEstimate: effectiveRSSI,
                    effectiveRSSI: effectiveRSSI, slope: 0, isAnomalous: false,
                    event: "unlocked")
                Task { @MainActor [weak self] in
                    self?.delegate?.updatePresence(presence: true, reason: "close")
                }
            }
            Task { @MainActor [weak self] in
                self?.delegate?.updateRSSI(rssi: Int(dispRSSI), active: activeMode)
                self?.delegate?.onDeviceApproached()
            }
        } else {
            Task { @MainActor [weak self] in
                self?.delegate?.updateRSSI(rssi: Int(dispRSSI), active: activeMode)
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
    /// 预备唤醒阈值（dBm）：解锁阈值往更远方向提前 wakeAdvance（UI 可填，默认 20）
    var preWakeThreshold: Int {
        guard unlockRSSI != Self.UNLOCK_DISABLED else { return unlockRSSI }
        let advance = SignalHysteresisEngine.offsetSetting("wakeAdvance", default: Self.defaultWakeAdvance)
        return unlockRSSI - advance
    }
    /// 预解锁触发阈值（dBm）：解锁阈值往更远方向提前 preUnlockTrigger（UI 可填，默认 10），
    /// 信号进入该接近窗口时启用 0.5s 快速轮询（开足马力探测）；不再直接触发解锁，
    /// 真正解锁由信号达到 unlockRSSI 决定
    var unlockStairThreshold: Int {
        guard unlockRSSI != Self.UNLOCK_DISABLED else { return unlockRSSI }
        let trigger = SignalHysteresisEngine.offsetSetting("preUnlockTrigger", default: Self.defaultPreUnlockTrigger)
        return unlockRSSI - trigger
    }
}
