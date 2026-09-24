import Foundation
import os

/// FUn 的锁定时延与心跳状态机（自 FUn.swift 抽离，保持单文件 <300 行）：
/// - 信号超时链：resetSignalTimer / markSignalLost（3 次连续超时判定离场）
/// - 有效信号衰减：decayedEffectiveRSSI / getEffectiveRSSI（采样中断期的温和衰减）
/// - 心跳状态机：ensureHeartbeat / makeHeartbeatTimer / cancelHeartbeat（主动锁定检查）
/// - 锁定计时器：startLockTimer / applyLockTimer（按下降斜率自适应超时）+ 锁冷静期
///
/// 线程契约：所有状态由 FUn.lock（UnfairLock）保护；Timer 注册/失效在主 RunLoop；
/// 回调内跨线程派发统一走 Task { @MainActor [weak self] }。
extension FUn {
    // MARK: - Time decay computation (heartbeat fallback, depends only on self.effectiveRSSI)

    /// 信号中断期间的有效信号衰减：分段的温和曲线 + 封顶。
    /// 目的：BLE 采样短暂间隙（几秒）不应把信号强行压到锁阈值之下造成误锁；
    /// 但同时保证真实离场（长时间无采样）仍能衰减到阈值以下触发锁定。
    /// - Parameters:
    ///   - effectiveRSSI: 最近一次采样的有效信号（dBm）
    ///   - elapsedSinceLastReceive: 距离最后一次采样的时间（秒）
    static func decayedEffectiveRSSI(effectiveRSSI: Double, elapsedSinceLastReceive: TimeInterval) -> Double {
        let penalty: Double
        if elapsedSinceLastReceive <= 6.0 {
            // 6 秒内：不额外惩罚，信任管道 effectiveRSSI（缓冲 BLE 采样间隙）
            penalty = 0
        } else if elapsedSinceLastReceive <= 10.0 {
            // 6~10 秒：温和线性（0.75 dB/s，最多 3 dB）
            penalty = (elapsedSinceLastReceive - 6.0) * 0.75
        } else {
            // 10 秒后：1 dB/s，累计最多 20 dB（防止长时间陈旧值剧烈下探）
            penalty = min(3.0 + (elapsedSinceLastReceive - 10.0), 20.0)
        }
        return max(effectiveRSSI - penalty, -100.0)
    }

    func getEffectiveRSSI() -> Double {
        let (lastRecv, effRSSI) = lock.withLock { (lastReceiveTime, effectiveRSSI) }
        let elapsed = Date().timeIntervalSince(lastRecv)
        return Self.decayedEffectiveRSSI(effectiveRSSI: effRSSI, elapsedSinceLastReceive: elapsed)
    }

    // MARK: - 信号超时链

    func resetSignalTimer() {
        signalTimer?.invalidate()
        let timer = Timer(timeInterval: signalTimeout, repeats: true, block: { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            let shouldLose: Bool = self.lock.withLock {
                // 输入活动且 lockOnIdle 开启时，不判定信号丢失（与 applyLockTimer 行为一致），
                // 仅重置超时计数与衰减基准，避免打字/用鼠标时因信号超时误锁
                let lockOnIdle = ConfigStore.shared.object(forKey: "lockOnIdle") == nil
                    || ConfigStore.shared.bool(forKey: "lockOnIdle")
                if lockOnIdle && self.isUserInputActive {
                    self.signalLostCount = 0
                    self.lastReceiveTime = Date()
                    self.pipeline.decayBaseline = Date()
                    return false
                }
                self.signalLostCount += 1
                return self.signalLostCount >= 3
            }
            if shouldLose {
                timer.invalidate()
                self.markSignalLost()
            } else {
                Log.sm.debug("Signal timeout \(self.lock.withLock { self.signalLostCount })/3, waiting...")
            }
        })
        RunLoop.main.add(timer, forMode: .common)
        signalTimer = timer
    }

    /// 信号丢失（3 次连续超时）统一复位：清在场标志、有效信号复位到无信号档（-100）、
    /// 通知 UI（rssi 置 nil，与总览「无信号」判据一致），避免菜单栏残留冻结的旧信号值
    func markSignalLost() {
        let wasPresent = lock.withLock { self.presence }
        lock.withLock {
            presence = false
            signalLostCount = 0
            if effectiveRSSI > -100.0 {
                effectiveRSSI = -100.0
            }
        }
        Log.sm.debug("Device is lost (3 consecutive timeouts)")
        Task { @MainActor [weak self] in
            self?.delegate?.updateRSSI(rssi: nil, active: false)
        }
        if wasPresent {
            // P1: 记录信号丢失锁定事件
            SignalDataStore.shared.record(
                rawRSSI: -100, kalmanEstimate: -100,
                effectiveRSSI: -100, slope: 0, isAnomalous: false,
                event: "locked: lost")
            Task { @MainActor [weak self] in
                self?.delegate?.updatePresence(presence: false, reason: "lost")
            }
        }
    }

    // MARK: - Direction 3: Heartbeat — proactive lock check
    func ensureHeartbeat() {
        let alreadyExists = lock.withLock { heartbeatTimer != nil }
        guard !alreadyExists else { return }
        let interval = computeHeartbeatInterval()
        let timer: Timer = lock.withLock {
            lastHeartbeatInterval = interval
            heartbeatTimer = makeHeartbeatTimer(interval: interval)
            return heartbeatTimer!
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func computeHeartbeatInterval() -> TimeInterval {
        let eff = getEffectiveRSSI()
        let baseTh = Double(unlockRSSI) + 10.0
        let lockTh = Double(lockRSSI == Self.LOCK_DISABLED ? unlockRSSI : lockRSSI) + 10.0
        if eff > baseTh { return 8.0 }
        if eff < lockTh { return 2.0 }
        return 3.0
    }

    private func makeHeartbeatTimer(interval: TimeInterval) -> Timer {
        return Timer(timeInterval: interval, repeats: true, block: { [weak self] _ in
            guard let self = self else { return }
            let shouldStop = self.lock.withLock {
                guard self.presence else {
                    self.heartbeatTimer?.invalidate()
                    self.heartbeatTimer = nil
                    return true
                }
                return false
            }
            guard !shouldStop else { return }
            let eff = self.getEffectiveRSSI()
            let threshold = Double(self.lockRSSI == Self.LOCK_DISABLED ? self.unlockRSSI : self.lockRSSI)
            let hasTimer = self.lock.withLock { self.proximityTimer != nil }
            // 冷静期：刚解锁后不立即触发锁定
            let graceElapsed = Date().timeIntervalSince(self.lastProximityEventTime)
            lockLog("[LOCK] heartbeat eff=\(String(format: "%.1f", eff)) threshold=\(Int(threshold)) hasTimer=\(hasTimer) graceElapsed=\(String(format: "%.1f", graceElapsed)) inputActive=\(self.isUserInputActive)")
            if eff < threshold && !hasTimer && graceElapsed >= self.proximityGracePeriod {
                if self.isUserInputActive {
                    // 用户活跃时重置衰减基准，阻止衰减累积
                    self.lock.withLock {
                        self.lastReceiveTime = Date()
                        self.pipeline.decayBaseline = Date()
                    }
                } else {
                    Log.sm.debug("[HB] effectiveRSSI=\(Int(eff)) < threshold=\(Int(threshold)), starting lock timer")
                    self.startLockTimer()
                }
            }
            let newInterval = self.computeHeartbeatInterval()
            // P0 #4 修复：invalidate + 创建 + 状态更新全部在锁内完成，避免 cancelHeartbeat 竞态
            let timerToAdd: Timer? = self.lock.withLock {
                let lastInterval = self.lastHeartbeatInterval
                guard abs(newInterval - lastInterval) > 0.5 else { return nil }
                Log.sm.debug("[HB] interval \(lastInterval)s → \(newInterval)s")
                self.heartbeatTimer?.invalidate()
                let newTimer = self.makeHeartbeatTimer(interval: newInterval)
                self.lastHeartbeatInterval = newInterval
                self.heartbeatTimer = newTimer
                return newTimer
            }
            if let timerToAdd = timerToAdd {
                RunLoop.main.add(timerToAdd, forMode: .common)
            }
        })
    }

    func cancelHeartbeat() {
        lock.withLock {
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
        }
    }

    // MARK: - 锁冷静期

    /// 刷新锁冷静基准（所有解锁成功路径调用）：重置 lastProximityEventTime，
    /// 使心跳锁检查与锁计时器触发时都能看到「距最近解锁 < proximityGracePeriod」
    func refreshProximityGrace() {
        lock.withLock { lastProximityEventTime = Date() }
    }

    /// 是否处于锁冷静期（距最近解锁/靠近 < proximityGracePeriod）
    func isWithinLockGracePeriod(now: Date = Date()) -> Bool {
        let last = lock.withLock { lastProximityEventTime }
        return SignalHysteresisEngine.isWithinLockGracePeriod(
            lastUnlockTime: last, gracePeriod: proximityGracePeriod, now: now)
    }

    // MARK: - Lock timer (shared by updateMonitoredPeripheral and heartbeat)
    /// 方案 C：按下降斜率计算锁屏超时 —— 陡降（slope ≤ -fastSlopeThreshold）→ fastLockTimeout；
    /// 缓降/平稳（slope ≥ -mildSlopeThreshold）→ base；中间线性插值
    static func lockTimeout(slope: Double, base: TimeInterval = 5.0) -> TimeInterval {
        SignalHysteresisEngine.lockTimeout(slope: slope, base: base)
    }

    private func startLockTimer() {
        // 方案 C：锁屏超时随下降斜率自适应
        let slope = lock.withLock { pipeline.smoothedSlope }
        let timeout = Self.lockTimeout(slope: slope, base: proximityTimeout)
        let timer = Timer(timeInterval: timeout, repeats: false, block: { [weak self] _ in
            guard let self = self else { return }
            let lockOnIdle = ConfigStore.shared.object(forKey: "lockOnIdle") == nil
                || ConfigStore.shared.bool(forKey: "lockOnIdle")
            let nowEff = self.getEffectiveRSSI()
            let nowThreshold = Double(self.lockRSSI == Self.LOCK_DISABLED ? self.unlockRSSI : self.lockRSSI)
            let nowPresence = self.lock.withLock { self.presence }
            lockLog("[LOCK] timer FIRED eff=\(String(format: "%.1f", nowEff)) threshold=\(Int(nowThreshold)) presence=\(nowPresence) lockOnIdle=\(lockOnIdle) inputActive=\(self.isUserInputActive) effAboveThreshold=\(nowEff >= nowThreshold)")
            if nowEff >= nowThreshold {
                lockLog("[LOCK] timer fired but signal recovered (eff=\(String(format: "%.1f", nowEff)) >= threshold=\(Int(nowThreshold))), skipping lock")
                self.lock.withLock { self.proximityTimer = nil }
                return
            }
            if lockOnIdle && self.isUserInputActive {
                lockLog("[LOCK] timer fired but input active, deferring lock")
                Log.sm.debug("[SM] input active at lock timer fire, deferring")
                self.lock.withLock {
                    self.proximityTimer = nil
                    self.lastReceiveTime = Date()
                    self.pipeline.decayBaseline = Date()
                }
                return
            }
            if self.isWithinLockGracePeriod() {
                lockLog("[LOCK] timer fired but within unlock grace period, skipping lock")
                self.lock.withLock { self.proximityTimer = nil }
                return
            }
            Log.sm.debug("Device is away")
            // P1: 记录锁定事件
            SignalDataStore.shared.record(
                rawRSSI: -100, kalmanEstimate: -100,
                effectiveRSSI: -100, slope: 0, isAnomalous: false,
                event: "locked")
            self.lock.withLock { self.presence = false }
            self.cancelHeartbeat()
            Task { @MainActor [weak self] in
                self?.delegate?.updatePresence(presence: false, reason: "away")
            }
            self.lock.withLock { self.proximityTimer = nil }
        })
        lock.withLock { proximityTimer = timer }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 锁定决策：信号低于锁定阈值（离开迟滞下沿）时按斜率启动锁屏计时器，
    /// 信号回升立即取消；冷静期与用户输入活跃时推迟锁定
    func applyLockTimer(rssi: Int, effectiveRSSI: Double) {
        let decision = SignalHysteresisEngine.checkProximity(
            rssi: Double(rssi), effectiveRSSI: effectiveRSSI,
            unlockRSSI: unlockRSSI, lockRSSI: lockRSSI)
        let threshold = Double(decision.lockThreshold)
        if !decision.isAway {
            lock.withLock {
                proximityTimer?.invalidate()
                proximityTimer = nil
            }
        } else {
            let (curPresence, curTimer) = lock.withLock { (presence, proximityTimer) }
            lockLog("[LOCK] applyLockTimer eff=\(String(format: "%.1f", effectiveRSSI)) threshold=\(Int(threshold)) presence=\(curPresence) hasTimer=\(curTimer != nil)")
            if curPresence && curTimer == nil {
                // 冷静期：刚解锁后不立即触发锁定，防止 effectiveRSSI 衰减导致振荡
                let lastUnlock = lastProximityEventTime
                let now = Date()
                let elapsed = now.timeIntervalSince(lastUnlock)
                lockLog("[LOCK] graceElapsed=\(String(format: "%.1f", elapsed))s gracePeriod=\(self.proximityGracePeriod)s")
                if SignalHysteresisEngine.isWithinLockGracePeriod(
                    lastUnlockTime: lastUnlock,
                    gracePeriod: self.proximityGracePeriod, now: now) {
                    lockLog("[LOCK] BLOCKED by proximityGracePeriod")
                    Log.sm.debug("[SM] grace period \(String(format: "%.1f", elapsed))s < \(self.proximityGracePeriod)s, deferring lock")
                    return
                }
                let lockOnIdle = ConfigStore.shared.object(forKey: "lockOnIdle") == nil
                    || ConfigStore.shared.bool(forKey: "lockOnIdle")
                if lockOnIdle && isUserInputActive {
                    lockLog("[LOCK] BLOCKED by isUserInputActive (lockOnIdle=\(lockOnIdle) inputActive=\(isUserInputActive))")
                    Log.sm.debug("[SM] input active, rejecting lock signal + resetting decay")
                    lock.withLock {
                        lastReceiveTime = Date()
                        pipeline.decayBaseline = Date()
                    }
                } else {
                    lockLog("[LOCK] all guards passed -> startLockTimer")
                    startLockTimer()
                }
            } else {
                lockLog("[LOCK] SKIPPED: presence=\(curPresence) hasTimer=\(curTimer != nil)")
            }
        }
    }
}
