import Foundation
import os

/// heartbeat 日志降频器：设备在场且信号稳定时，心跳每 2~8s 打一条 `[LOCK] heartbeat ...`
/// 是 debug.log 快速膨胀的主因。仅在下列情形放行日志：
/// - 接近锁定阈值边界（eff < threshold + 10，值得逐拍观察）；
/// - 有锁定计时器在跑（hasTimer，处于锁定倒计时关键期）；
/// - 输入活跃状态相对上次心跳发生变化（行为切换点）。
/// 其余平稳在场期间每 60s 最多补一条摘要，保证可观测性又不刷屏。
/// 与 FUn.swift 的 bleLogThrottler 同源设计（私有 final class + 自带锁 + 文件级单例，
/// 心跳 block 在主 RunLoop 串行 fire，状态仅此一处读写）。
private final class HeartbeatLogGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastInputActive: Bool?
    private var lastSummaryTime = Date.distantPast

    /// 本次心跳是否应输出日志，并更新内部状态。
    func shouldLog(nearThreshold: Bool, hasTimer: Bool, inputActive: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let inputChanged = (lastInputActive != nil && lastInputActive != inputActive)
        lastInputActive = inputActive
        if nearThreshold || hasTimer || inputChanged { return true }
        let now = Date()
        if now.timeIntervalSince(lastSummaryTime) >= 60.0 {
            lastSummaryTime = now
            return true
        }
        return false
    }
}

private let heartbeatLogGate = HeartbeatLogGate()

/// FUn 的锁定时延与心跳状态机（自 FUn.swift 抽离，保持单文件 <300 行）：
/// - 信号超时链：resetSignalTimer / markSignalLost（3 次连续超时判定离场）
/// - 有效信号衰减：decayedEffectiveRSSI / getEffectiveRSSI（采样中断期的温和衰减）
/// - 心跳状态机：ensureHeartbeat / makeHeartbeatTimer / cancelHeartbeat（主动锁定检查）
/// - 锁定计时器：startLockTimer / applyLockTimer（按下降斜率自适应超时）+ 锁冷静期
///
/// 线程契约：所有状态由 FUn.lock（UnfairLock）保护；unlockRSSI/lockRSSI 的判定读
/// 统一锁内成对快照（`_unlockRSSI`/`_lockRSSI`）；Timer 注册在主 RunLoop，invalidate
/// 派发回主线程（fire block 内自停直接主线程调用，并配 `===` 身份校验防过期 fire 误伤新状态）；
/// 回调内跨线程派发统一走 Task { @MainActor [weak self] }。
extension FUn {
    // MARK: - Time decay computation (heartbeat fallback, depends only on self.effectiveRSSI)

    /// 无阈值上下文的通用衰减（测试/纯计算用）：惩罚封顶固定 20 dB
    static func decayedEffectiveRSSI(effectiveRSSI: Double, elapsedSinceLastReceive: TimeInterval) -> Double {
        decayedEffectiveRSSI(effectiveRSSI: effectiveRSSI,
                             elapsedSinceLastReceive: elapsedSinceLastReceive,
                             lockThreshold: nil,
                             pollInterval: 2.0)
    }

    /// 信号中断期间的有效信号衰减：分段的温和曲线 + 与锁定阈值联动的封顶。
    /// 免罚期与轮询间隔联动：max(6, pollInterval + 2)，8s 慢轮询不会因几秒采样间隙被额外惩罚。
    /// 目的：BLE 采样短暂间隙不应把信号强行压到锁阈值之下造成误锁；
    /// 但同时保证真实离场（长时间无采样）仍能衰减到阈值以下触发锁定。
    /// - Parameters:
    ///   - effectiveRSSI: 最近一次采样的有效信号（dBm）
    ///   - elapsedSinceLastReceive: 距离最后一次采样的时间（秒）
    ///   - lockThreshold: 锁定阈值（dBm）。封顶与阈值联动：
    ///     cap = max(20, effectiveRSSI − lockThreshold + 6)——强在场信号（≥阈值-20）
    ///     长时间衰减后仍能跌破锁定阈值，心跳锁路径不因封顶失效；nil 时封顶固定 20 dB
    ///   - pollInterval: 当前主动轮询间隔（0.5/2/8s），用于放宽免罚期
    static func decayedEffectiveRSSI(effectiveRSSI: Double, elapsedSinceLastReceive: TimeInterval,
                                     lockThreshold: Int?, pollInterval: TimeInterval = 2.0) -> Double {
        // 封顶：无阈值上下文固定 20 dB；有阈值时保证衰减深度足以跌破锁定阈值 6 dB
        let cap: Double = lockThreshold.map { max(20.0, effectiveRSSI - Double($0) + 6.0) } ?? 20.0
        let grace = max(6.0, pollInterval + 2.0)
        let penalty: Double
        if elapsedSinceLastReceive <= grace {
            // 免罚期：信任管道 effectiveRSSI（覆盖当前轮询间隔的采样间隙）
            penalty = 0
        } else if elapsedSinceLastReceive <= grace + 4.0 {
            // 免罚期后 4 秒：温和线性（0.75 dB/s，最多 3 dB）
            penalty = (elapsedSinceLastReceive - grace) * 0.75
        } else {
            // 之后 1 dB/s，累计封顶 cap（长时间陈旧值不剧烈下探，但仍能触发锁定）
            penalty = min(3.0 + (elapsedSinceLastReceive - grace - 4.0), cap)
        }
        return max(effectiveRSSI - penalty, -100.0)
    }

    func getEffectiveRSSI() -> Double {
        // 阈值、信号状态与轮询间隔锁内一次快照（修复裸读竞态）
        let timerActive = scheduler.isScheduled(.lockConfirm)
        let (lastRecv, effRSSI, uRSSI, lRSSI, pollBefore, activePoll) = lock.withLock {
            (lastReceiveTime, effectiveRSSI, _unlockRSSI, _lockRSSI,
             pollIntervalBeforeLockTimer, scanner.handler.activePollInterval)
        }
        let elapsed = Date().timeIntervalSince(lastRecv)
        // 封顶与锁定阈值联动（强在场信号突然消失时心跳锁路径仍能触发）
        let lockThreshold = SignalHysteresisEngine.resolvedLockThreshold(unlockRSSI: uRSSI, lockRSSI: lRSSI)
        // 锁屏计时器在途时使用启动前保存的间隔，防止切到 0.5s 快档后免罚期骤降
        let pollInterval = timerActive ? pollBefore : activePoll
        return Self.decayedEffectiveRSSI(effectiveRSSI: effRSSI,
                                         elapsedSinceLastReceive: elapsed,
                                         lockThreshold: lockThreshold,
                                         pollInterval: pollInterval)
    }

    // MARK: - 锁屏计时器单样本守卫

    /// 锁屏计时器结算决策。
    enum LockTimerSettlement: Equatable {
        case settleNow
        /// 尚无新样本且未到失联结算期限：单次延长指定秒数
        case extend(TimeInterval)
    }

    /// 失联结算期限：至少 10s；8s 轮询档为 12s（一个半周期）。
    static func staleLossDeadline(forPollInterval pollInterval: TimeInterval) -> TimeInterval {
        max(10.0, pollInterval + 4.0)
    }

    /// 计时器触发时的结算决策：
    /// 已收到新样本（恢复则已取消，确认跌落则照常锁）→ 立即结算；
    /// 已到失联结算期限，或已经延长过一次 → 立即结算；否则单次延长到期限，等待确认样本。
    static func lockTimerSettlementAction(hasFreshSample: Bool, elapsed: TimeInterval,
                                          pollIntervalBeforeTimer: TimeInterval,
                                          alreadyExtended: Bool) -> LockTimerSettlement {
        if hasFreshSample { return .settleNow }
        let deadline = staleLossDeadline(forPollInterval: pollIntervalBeforeTimer)
        if elapsed >= deadline || alreadyExtended { return .settleNow }
        return .extend(deadline - elapsed)
    }

    /// 锁屏结算使用的静默时长：必须以上次采样为基准，而不是计时器启动时刻。
    /// 心跳可能在设备已失联 10s 后才启动计时器；从启动时刻算会重复计算并多延长一个期限。
    static func lockTimerSilenceElapsed(now: Date, lastReceiveTime: Date) -> TimeInterval {
        now.timeIntervalSince(lastReceiveTime)
    }

    // MARK: - 信号超时链

    /// 事件驱动的信号超时链（幂等「确保存在」）：由 LiveDeadlineScheduler 单一调度器管理 `.signalTimeout`。
    func resetSignalTimer() {
        guard !scheduler.isScheduled(.signalTimeout) else { return }
        scheduler.scheduleAfter(.signalTimeout, interval: signalTimeout)
    }

    func handleSignalTimeoutTick() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            let shouldLose: Bool = self.lock.withLock {
                let lockOnIdle = ConfigStore.shared.bool(forKey: "lockOnIdle", default: true)
                if lockOnIdle && self.isUserInputActive {
                    self.signalLostCount = 0
                    self.lastReceiveTime = Date()
                    self.pipeline.decayBaseline = Date()
                    return false
                }
                if Date().timeIntervalSince(self.lastReceiveTime) < self.signalTimeout {
                    return false
                }
                self.signalLostCount += 1
                return self.signalLostCount >= 3
            }
            if shouldLose {
                self.markSignalLost()
            } else {
                AppLog.debug(.lock, "signalTimeoutWaiting", [("count", "\(self.lock.withLock { self.signalLostCount })"), ("max", "3")])
                self.scheduler.scheduleAfter(.signalTimeout, interval: self.signalTimeout)
            }
        }
    }

    /// 信号丢失（3 次连续超时）统一复位：清在场标志、有效信号复位到无信号档（-100）、
    /// 通知 UI（rssi 置 nil，与总览「无信号」判据一致），避免菜单栏残留冻结的旧信号值
    func markSignalLost() {
        let wasPresent = lock.withLock {
            let was = presence
            presence = false
            signalLostCount = 0
            if effectiveRSSI > -100.0 {
                effectiveRSSI = -100.0
            }
            return was
        }
        AppLog.info(.lock, "deviceLost", [("reason", "consecutiveTimeouts"), ("count", "3")])
        Task { @MainActor [weak self] in
            self?.delegate?.updateRSSI(rssi: nil, active: false)
        }
        if wasPresent {
            // P1: 记录信号丢失锁定事件
            SignalDataStore.shared.record(
                rawRSSI: -100, kalmanEstimate: -100,
                effectiveRSSI: -100, slope: 0, isAnomalous: false,
                event: .lockedLost)
            Task { @MainActor [weak self] in
                self?.delegate?.updatePresence(presence: false, reason: "lost")
            }
        }
    }

    // MARK: - Direction 3: Heartbeat — proactive lock check

    /// 心跳仅服务锁定判定：锁定禁用（lockRSSI 为禁用哨兵）时不再启动/立即停止，避免空转
    func ensureHeartbeat() {
        let alreadyExists = scheduler.isScheduled(.heartbeat)
        let lockOff = lock.withLock { _lockRSSI == Self.LOCK_DISABLED }
        if lockOff {
            if alreadyExists { cancelHeartbeat() }
            return
        }
        guard !alreadyExists else { return }
        let interval = computeHeartbeatInterval()
        lock.withLock { lastHeartbeatInterval = interval }
        scheduler.scheduleAfter(.heartbeat, interval: interval)
    }

    private func computeHeartbeatInterval() -> TimeInterval {
        // 阈值锁内成对快照（修复裸读竞态）
        let (uRSSI, lRSSI) = lock.withLock { (_unlockRSSI, _lockRSSI) }
        let eff = getEffectiveRSSI()
        let baseTh = Double(uRSSI) + 10.0
        // 哨兵感知：lockRSSI 为禁用哨兵时 lockTh 直接用 unlockRSSI（不加 10dB 偏移），
        // 保留 8/3/2s 三档，避免 lockTh == baseTh 使 3s 档永不出现
        let lockTh = lRSSI == Self.LOCK_DISABLED ? Double(uRSSI) : Double(lRSSI) + 10.0
        if eff > baseTh { return 8.0 }
        if eff < lockTh { return 2.0 }
        return 3.0
    }

    func handleHeartbeatTick() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            let shouldStop = self.lock.withLock { !self.presence }
            if shouldStop {
                self.cancelHeartbeat()
                return
            }
            let eff = self.getEffectiveRSSI()
            let (uRSSI, lRSSI, lastProx) = self.lock.withLock {
                (self._unlockRSSI, self._lockRSSI, self.lastProximityEventTime)
            }
            let threshold = Double(SignalHysteresisEngine.resolvedLockThreshold(unlockRSSI: uRSSI, lockRSSI: lRSSI))
            let hasTimer = self.scheduler.isScheduled(.lockConfirm)
            let graceElapsed = Date().timeIntervalSince(lastProx)
            let inputActive = self.isUserInputActive
            let nearThreshold = eff < threshold + 10
            if heartbeatLogGate.shouldLog(nearThreshold: nearThreshold, hasTimer: hasTimer, inputActive: inputActive) {
                AppLog.debug(.lock, "heartbeat", [("eff", String(format: "%.1f", eff)), ("threshold", "\(Int(threshold))"), ("hasTimer", "\(hasTimer)"), ("graceElapsed", String(format: "%.1f", graceElapsed)), ("inputActive", "\(inputActive)")])
            }
            if eff < threshold && !hasTimer && graceElapsed >= self.proximityGracePeriod {
                let lockOnIdle = ConfigStore.shared.bool(forKey: "lockOnIdle", default: true)
                if lockOnIdle && inputActive {
                    self.lock.withLock {
                        self.lastReceiveTime = Date()
                        self.pipeline.decayBaseline = Date()
                    }
                } else {
                    AppLog.info(.lock, "heartbeatLockTimerStart", [("effectiveRSSI", "\(Int(eff))"), ("threshold", "\(Int(threshold))")])
                    self.startLockTimer()
                }
            }
            let newInterval = self.computeHeartbeatInterval()
            let lastInterval = self.lock.withLock {
                let prev = self.lastHeartbeatInterval
                self.lastHeartbeatInterval = newInterval
                return prev
            }
            if abs(newInterval - lastInterval) > 0.5 {
                AppLog.debug(.lock, "heartbeatIntervalChange", [("from", "\(lastInterval)s"), ("to", "\(newInterval)s")])
            }
            self.scheduler.scheduleAfter(.heartbeat, interval: newInterval)
        }
    }

    func cancelHeartbeat() {
        scheduler.cancel(.heartbeat)
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

    /// 距离解锁冷静期结束的剩余秒数（供冷静期拦截后的补锁复查）。
    var lockGraceRemaining: TimeInterval {
        lock.withLock {
            max(0, proximityGracePeriod - Date().timeIntervalSince(lastProximityEventTime))
        }
    }

    // MARK: - Lock timer (shared by updateMonitoredPeripheral and heartbeat)
    /// 方案 C：按下降斜率计算锁屏超时 —— 陡降（slope ≤ -fastSlopeThreshold）→ fastLockTimeout；
    /// 缓降/平稳（slope ≥ -mildSlopeThreshold）→ base；中间线性插值
    static func lockTimeout(slope: Double, base: TimeInterval = 5.0) -> TimeInterval {
        SignalHysteresisEngine.lockTimeout(slope: slope, base: base)
    }

    private func startLockTimer() {
        // 方案 C：锁屏超时随下降斜率自适应
        let timeout: TimeInterval = lock.withLock {
            let slope = pipeline.smoothedSlope
            lockTimerStartedAt = Date()
            pollIntervalBeforeLockTimer = scanner.handler.activePollInterval
            lockTimerExtended = false
            return Self.lockTimeout(slope: slope, base: proximityTimeout)
        }
        scheduler.scheduleAfter(.lockConfirm, interval: timeout)
        // 立即补采一次：让单样本骤降在定时器到期前拿到确认样本
        scanner.handler.triggerImmediateRSSIProbe()
    }

    /// 仅在 lock 内调用：复位结算守卫。
    private func clearProximityTimerLocked() {
        lockTimerStartedAt = .distantPast
        lockTimerExtended = false
    }

    /// 锁屏计时器触发：先做单样本结算守卫，再执行常规阈值/输入/冷静期判定。
    func handleLockTimerFire() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            let (startedAt, pollBefore, extended, lastRecv) = self.lock.withLock {
                (self.lockTimerStartedAt, self.pollIntervalBeforeLockTimer, self.lockTimerExtended, self.lastReceiveTime)
            }
            guard startedAt != .distantPast else { return }
            let elapsed = Self.lockTimerSilenceElapsed(now: Date(), lastReceiveTime: lastRecv)
            let settlement = Self.lockTimerSettlementAction(
                hasFreshSample: lastRecv > startedAt,
                elapsed: elapsed,
                pollIntervalBeforeTimer: pollBefore,
                alreadyExtended: extended)
            if case .extend(let remaining) = settlement {
                self.lock.withLock { self.lockTimerExtended = true }
                self.scheduler.scheduleAfter(.lockConfirm, interval: max(1.0, remaining))
                self.scanner.handler.triggerImmediateRSSIProbe()
                AppLog.info(.lock, "lockTimerExtended", [("elapsed", String(format: "%.1fs", elapsed)), ("remaining", String(format: "%.1fs", remaining))])
                return
            }

            let lockOnIdle = ConfigStore.shared.bool(forKey: "lockOnIdle", default: true)
            let nowEff = self.getEffectiveRSSI()
            let (uRSSI, lRSSI, nowPresence) = self.lock.withLock { (self._unlockRSSI, self._lockRSSI, self.presence) }
            let nowThreshold = Double(SignalHysteresisEngine.resolvedLockThreshold(unlockRSSI: uRSSI, lockRSSI: lRSSI))
            AppLog.info(.lock, "lockTimerFired", [("eff", String(format: "%.1f", nowEff)), ("threshold", "\(Int(nowThreshold))"), ("presence", "\(nowPresence)"), ("lockOnIdle", "\(lockOnIdle)"), ("inputActive", "\(self.isUserInputActive)"), ("effAboveThreshold", "\(nowEff >= nowThreshold)")])
            if nowEff >= nowThreshold {
                AppLog.info(.lock, "lockTimerSkipped", [("reason", "signalRecovered"), ("eff", String(format: "%.1f", nowEff)), ("threshold", "\(Int(nowThreshold))")])
                self.lock.withLock { self.clearProximityTimerLocked() }
                return
            }
            if lockOnIdle && self.isUserInputActive {
                AppLog.info(.lock, "lockTimerDeferred", [("reason", "inputActive")])
                self.lock.withLock {
                    self.clearProximityTimerLocked()
                    self.lastReceiveTime = Date()
                    self.pipeline.decayBaseline = Date()
                }
                return
            }
            if self.isWithinLockGracePeriod() {
                AppLog.info(.lock, "lockTimerSkipped", [("reason", "withinUnlockGracePeriod")])
                self.lock.withLock { self.clearProximityTimerLocked() }
                return
            }
            AppLog.info(.lock, "deviceAway")
            self.lock.withLock {
                self.presence = false
                self.clearProximityTimerLocked()
            }
            self.cancelHeartbeat()
            Task { @MainActor [weak self] in
                self?.delegate?.updatePresence(presence: false, reason: "away")
            }
        }
    }

    /// 锁定决策：信号低于锁定阈值（离开迟滞下沿）时按斜率启动锁屏计时器，
    /// 信号回升立即取消；冷静期与用户输入活跃时推迟锁定
    func applyLockTimer(rssi: Int, effectiveRSSI: Double) {
        // 阈值锁内成对快照（修复 unlockRSSI/lockRSSI 裸读竞态与中间态撕裂）
        let (uRSSI, lRSSI) = lock.withLock { (_unlockRSSI, _lockRSSI) }
        // 锁定禁用（-100）：统一语义为「关闭自动锁屏」，不启动/不保留锁屏计时器
        if lRSSI == Self.LOCK_DISABLED {
            scheduler.cancel(.lockConfirm)
            lock.withLock { clearProximityTimerLocked() }
            return
        }
        let decision = SignalHysteresisEngine.checkProximity(
            rssi: Double(rssi), effectiveRSSI: effectiveRSSI,
            unlockRSSI: uRSSI, lockRSSI: lRSSI)
        let threshold = Double(decision.lockThreshold)
        if !decision.isAway {
            scheduler.cancel(.lockConfirm)
            lock.withLock { clearProximityTimerLocked() }
        } else {
            let curPresence = lock.withLock { presence }
            let hasTimer = scheduler.isScheduled(.lockConfirm)
            AppLog.debug(.lock, "applyLockTimer", [("eff", String(format: "%.1f", effectiveRSSI)), ("threshold", "\(Int(threshold))"), ("presence", "\(curPresence)"), ("hasTimer", "\(hasTimer)")])
            if curPresence && !hasTimer {
                // 冷静期：刚解锁后不立即触发锁定，防止 effectiveRSSI 衰减导致振荡
                let lastUnlock = lock.withLock { lastProximityEventTime }
                let now = Date()
                let elapsed = now.timeIntervalSince(lastUnlock)
                AppLog.debug(.lock, "lockGraceCheck", [("elapsed", String(format: "%.1fs", elapsed)), ("gracePeriod", "\(self.proximityGracePeriod)s")])
                if SignalHysteresisEngine.isWithinLockGracePeriod(
                    lastUnlockTime: lastUnlock,
                    gracePeriod: self.proximityGracePeriod, now: now) {
                    AppLog.info(.lock, "lockBlocked", [("reason", "proximityGracePeriod"), ("elapsed", String(format: "%.1fs", elapsed)), ("gracePeriod", "\(self.proximityGracePeriod)s")])
                    return
                }
                let lockOnIdle = ConfigStore.shared.bool(forKey: "lockOnIdle", default: true)
                if lockOnIdle && isUserInputActive {
                    AppLog.info(.lock, "lockBlocked", [("reason", "userInputActive"), ("lockOnIdle", "\(lockOnIdle)"), ("inputActive", "\(isUserInputActive)")])
                    lock.withLock {
                        lastReceiveTime = Date()
                        pipeline.decayBaseline = Date()
                    }
                } else {
                    AppLog.info(.lock, "lockTimerStart", [("trigger", "allGuardsPassed")])
                    startLockTimer()
                }
            } else {
                AppLog.debug(.lock, "applyLockTimerSkipped", [("presence", "\(curPresence)"), ("hasTimer", "\(hasTimer)")])
            }
        }
    }
}
