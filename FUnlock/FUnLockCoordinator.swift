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
                             lockThreshold: nil)
    }

    /// 信号中断期间的有效信号衰减：分段的温和曲线 + 与锁定阈值联动的封顶。
    /// 目的：BLE 采样短暂间隙（几秒）不应把信号强行压到锁阈值之下造成误锁；
    /// 但同时保证真实离场（长时间无采样）仍能衰减到阈值以下触发锁定。
    /// - Parameters:
    ///   - effectiveRSSI: 最近一次采样的有效信号（dBm）
    ///   - elapsedSinceLastReceive: 距离最后一次采样的时间（秒）
    ///   - lockThreshold: 锁定阈值（dBm）。封顶与阈值联动：
    ///     cap = max(20, effectiveRSSI − lockThreshold + 6)——强在场信号（≥阈值-20）
    ///     长时间衰减后仍能跌破锁定阈值，心跳锁路径不因封顶失效；nil 时封顶固定 20 dB
    static func decayedEffectiveRSSI(effectiveRSSI: Double, elapsedSinceLastReceive: TimeInterval,
                                     lockThreshold: Int?) -> Double {
        // 封顶：无阈值上下文固定 20 dB；有阈值时保证衰减深度足以跌破锁定阈值 6 dB
        let cap: Double = lockThreshold.map { max(20.0, effectiveRSSI - Double($0) + 6.0) } ?? 20.0
        let penalty: Double
        if elapsedSinceLastReceive <= 6.0 {
            // 6 秒内：不额外惩罚，信任管道 effectiveRSSI（缓冲 BLE 采样间隙）
            penalty = 0
        } else if elapsedSinceLastReceive <= 10.0 {
            // 6~10 秒：温和线性（0.75 dB/s，最多 3 dB）
            penalty = (elapsedSinceLastReceive - 6.0) * 0.75
        } else {
            // 10 秒后：1 dB/s，累计封顶 cap（长时间陈旧值不剧烈下探，但仍能触发锁定）
            penalty = min(3.0 + (elapsedSinceLastReceive - 10.0), cap)
        }
        return max(effectiveRSSI - penalty, -100.0)
    }

    func getEffectiveRSSI() -> Double {
        // 阈值与信号状态锁内成对快照（修复 unlockRSSI/lockRSSI 裸读竞态）
        let (lastRecv, effRSSI, uRSSI, lRSSI) = lock.withLock {
            (lastReceiveTime, effectiveRSSI, _unlockRSSI, _lockRSSI)
        }
        let elapsed = Date().timeIntervalSince(lastRecv)
        // 封顶与锁定阈值联动（强在场信号突然消失时心跳锁路径仍能触发）
        let lockThreshold = SignalHysteresisEngine.resolvedLockThreshold(unlockRSSI: uRSSI, lockRSSI: lRSSI)
        return Self.decayedEffectiveRSSI(effectiveRSSI: effRSSI,
                                         elapsedSinceLastReceive: elapsed,
                                         lockThreshold: lockThreshold)
    }

    // MARK: - 信号超时链

    /// 事件驱动的信号超时链（幂等「确保存在」）：
    /// 采样到达时 processSignal 已在锁内刷新 lastReceiveTime；本方法只保证存在
    /// 单一重复 Timer（周期 signalTimeout），不再每采样 invalidate+重建
    /// （此前快轮询 2Hz 下每秒重建 2 个 Timer，浪费且引入置换竞态）。
    /// fire block 按「距上次采样已超过 signalTimeout」计数，连续 3 次超时判定
    /// 信号丢失（markSignalLost），三次判定语义与原每采样重建版本一致。
    /// 线程契约：创建与引用置换在 lock 内完成；RunLoop.main 注册在锁外（注册无需锁）；
    /// invalidate 统一在其注册线程（主 RunLoop）执行——置换路径派发回主线程，
    /// fire block 内自停直接在主线程调用并配 `===` 身份校验。
    func resetSignalTimer() {
        let newTimer: Timer? = lock.withLock {
            guard signalTimer == nil else { return nil }
            let timer = Timer(timeInterval: signalTimeout, repeats: true, block: { [weak self] timer in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                // 过期 fire 丢弃：本 timer 已被置换/清空（startMonitor / invalidateAllTimers）
                let isCurrent = self.lock.withLock { self.signalTimer === timer }
                guard isCurrent else { return }
                let shouldLose: Bool = self.lock.withLock {
                    // 输入活动且 lockOnIdle 开启时，不判定信号丢失（与 applyLockTimer 行为一致），
                    // 仅重置超时计数与衰减基准，避免打字/用鼠标时因信号超时误锁
                    let lockOnIdle = ConfigStore.shared.bool(forKey: "lockOnIdle", default: true)
                    if lockOnIdle && self.isUserInputActive {
                        self.signalLostCount = 0
                        self.lastReceiveTime = Date()
                        self.pipeline.decayBaseline = Date()
                        return false
                    }
                    // 距上次采样不足 signalTimeout：窗口内有采样，不计超时
                    if Date().timeIntervalSince(self.lastReceiveTime) < self.signalTimeout {
                        return false
                    }
                    self.signalLostCount += 1
                    return self.signalLostCount >= 3
                }
                if shouldLose {
                    // 连续 3 次超时：自停本 timer（主线程 fire 内 invalidate 符合契约），
                    // 下一次采样由 resetSignalTimer 重建
                    timer.invalidate()
                    self.lock.withLock {
                        if self.signalTimer === timer { self.signalTimer = nil }
                    }
                    self.markSignalLost()
                } else {
                    Log.sm.debug("Signal timeout \(self.lock.withLock { self.signalLostCount })/3, waiting...")
                }
            })
            signalTimer = timer
            return timer
        }
        if let t = newTimer {
            RunLoop.main.add(t, forMode: .common)
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
        Log.sm.debug("Device is lost (3 consecutive timeouts)")
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
        // 注意：锁内读私有阈值存储（computed lockRSSI 会取锁，UnfairLock 不可重入）
        let (alreadyExists, lockOff) = lock.withLock {
            (heartbeatTimer != nil, _lockRSSI == Self.LOCK_DISABLED)
        }
        if lockOff {
            if alreadyExists { cancelHeartbeat() }
            return
        }
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

    private func makeHeartbeatTimer(interval: TimeInterval) -> Timer {
        return Timer(timeInterval: interval, repeats: true, block: { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            let shouldStop = self.lock.withLock {
                guard self.presence else { return true }
                return false
            }
            if shouldStop {
                // 自停用 block 参数 invalidate（主线程 fire 内，符合 Timer 线程契约），
                // 不依赖 self.heartbeatTimer 属性等值（重建竞态下可能已指向新 timer）；
                // 仅当本 timer 仍为当前心跳定时器时才清空引用
                timer.invalidate()
                self.lock.withLock {
                    if self.heartbeatTimer === timer { self.heartbeatTimer = nil }
                }
                return
            }
            // 统一语义：心跳与采样路径（applyLockTimer）都用 decayedEffectiveRSSI 后的
            // 有效信号做锁定判定——采样流动时 elapsed≈0 两者等价，信号中断期仅由
            // 心跳路径的衰减驱动锁定（设备突然消失的唯一快速兜底）
            let eff = self.getEffectiveRSSI()
            // 阈值锁内成对快照（修复裸读竞态）
            let (uRSSI, lRSSI) = self.lock.withLock { (self._unlockRSSI, self._lockRSSI) }
            let threshold = Double(SignalHysteresisEngine.resolvedLockThreshold(unlockRSSI: uRSSI, lockRSSI: lRSSI))
            let hasTimer = self.lock.withLock { self.proximityTimer != nil }
            // 冷静期：刚解锁后不立即触发锁定（lastProximityEventTime 锁内读）
            let lastProx = self.lock.withLock { self.lastProximityEventTime }
            let graceElapsed = Date().timeIntervalSince(lastProx)
            let inputActive = self.isUserInputActive
            // heartbeat 日志降频：仅接近阈值边界/有锁定计时器/输入活跃状态变化时逐拍记录，
            // 平稳在场期每 60s 补一条摘要，避免 debug.log 被稳定态心跳刷爆
            let nearThreshold = eff < threshold + 10
            if heartbeatLogGate.shouldLog(nearThreshold: nearThreshold, hasTimer: hasTimer, inputActive: inputActive) {
                lockLog("[LOCK] heartbeat eff=\(String(format: "%.1f", eff)) threshold=\(Int(threshold)) hasTimer=\(hasTimer) graceElapsed=\(String(format: "%.1f", graceElapsed)) inputActive=\(inputActive)")
            }
            if eff < threshold && !hasTimer && graceElapsed >= self.proximityGracePeriod {
                if inputActive {
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
            // P0 #4 修复：创建 + 状态更新在锁内完成，避免 cancelHeartbeat 竞态；
            // 旧 timer 的 invalidate 在本 fire block 的主线程直接调用（符合契约）
            let rebuild: (newTimer: Timer, oldTimer: Timer?)? = self.lock.withLock {
                let lastInterval = self.lastHeartbeatInterval
                guard abs(newInterval - lastInterval) > 0.5 else { return nil }
                Log.sm.debug("[HB] interval \(lastInterval)s → \(newInterval)s")
                let newTimer = self.makeHeartbeatTimer(interval: newInterval)
                let oldTimer = self.heartbeatTimer
                self.lastHeartbeatInterval = newInterval
                self.heartbeatTimer = newTimer
                return (newTimer, oldTimer)
            }
            if let (newTimer, oldTimer) = rebuild {
                if let oldTimer { oldTimer.invalidate() }
                RunLoop.main.add(newTimer, forMode: .common)
            }
        })
    }

    func cancelHeartbeat() {
        // 锁内取引用并清空，invalidate 派发回主线程（Timer 注册在主 RunLoop；
        // 本方法可被 bleQueue 的采样路径调用）
        let old: Timer? = lock.withLock {
            let t = heartbeatTimer
            heartbeatTimer = nil
            return t
        }
        if let t = old { DispatchQueue.main.async { t.invalidate() } }
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
        let timer = Timer(timeInterval: timeout, repeats: false, block: { [weak self] timer in
            guard let self = self else { return }
            // 身份守卫：本 timer 已被置换/取消时直接丢弃过期 fire（与 resetSignalTimer
            // 的 signalTimer 守卫同款），防孤立 Timer 执行锁定逻辑
            guard self.lock.withLock({ self.proximityTimer === timer }) else { return }
            let lockOnIdle = ConfigStore.shared.bool(forKey: "lockOnIdle", default: true)
            let nowEff = self.getEffectiveRSSI()
            // 阈值锁内成对快照（修复裸读竞态）
            let (uRSSI, lRSSI) = self.lock.withLock { (self._unlockRSSI, self._lockRSSI) }
            let nowThreshold = Double(SignalHysteresisEngine.resolvedLockThreshold(unlockRSSI: uRSSI, lockRSSI: lRSSI))
            let nowPresence = self.lock.withLock { self.presence }
            lockLog("[LOCK] timer FIRED eff=\(String(format: "%.1f", nowEff)) threshold=\(Int(nowThreshold)) presence=\(nowPresence) lockOnIdle=\(lockOnIdle) inputActive=\(self.isUserInputActive) effAboveThreshold=\(nowEff >= nowThreshold)")
            if nowEff >= nowThreshold {
                lockLog("[LOCK] timer fired but signal recovered (eff=\(String(format: "%.1f", nowEff)) >= threshold=\(Int(nowThreshold))), skipping lock")
                // 身份校验：仅清空仍是当前锁屏 timer 的引用（防过期 fire 误清新 timer）
                self.lock.withLock {
                    if self.proximityTimer === timer { self.proximityTimer = nil }
                }
                return
            }
            if lockOnIdle && self.isUserInputActive {
                lockLog("[LOCK] timer fired but input active, deferring lock")
                Log.sm.debug("[SM] input active at lock timer fire, deferring")
                self.lock.withLock {
                    if self.proximityTimer === timer { self.proximityTimer = nil }
                    self.lastReceiveTime = Date()
                    self.pipeline.decayBaseline = Date()
                }
                return
            }
            if self.isWithinLockGracePeriod() {
                lockLog("[LOCK] timer fired but within unlock grace period, skipping lock")
                self.lock.withLock {
                    if self.proximityTimer === timer { self.proximityTimer = nil }
                }
                return
            }
            Log.sm.debug("Device is away")
            // P1: 记录锁定事件
            SignalDataStore.shared.record(
                rawRSSI: -100, kalmanEstimate: -100,
                effectiveRSSI: -100, slope: 0, isAnomalous: false,
                event: .locked)
            self.lock.withLock {
                self.presence = false
                if self.proximityTimer === timer { self.proximityTimer = nil }
            }
            self.cancelHeartbeat()
            Task { @MainActor [weak self] in
                self?.delegate?.updatePresence(presence: false, reason: "away")
            }
        })
        // 锁内原子置换并取出旧 timer（P1-3）：防并发触发时后写覆盖前写，
        // 旧 Timer 沦为 RunLoop 中的孤立僵尸；invalidate 派发回主线程（注册在主 RunLoop）
        let oldTimer: Timer? = lock.withLock {
            let old = proximityTimer
            proximityTimer = timer
            return old
        }
        if let oldTimer { DispatchQueue.main.async { oldTimer.invalidate() } }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 锁定决策：信号低于锁定阈值（离开迟滞下沿）时按斜率启动锁屏计时器，
    /// 信号回升立即取消；冷静期与用户输入活跃时推迟锁定
    func applyLockTimer(rssi: Int, effectiveRSSI: Double) {
        // 阈值锁内成对快照（修复 unlockRSSI/lockRSSI 裸读竞态与中间态撕裂）
        let (uRSSI, lRSSI) = lock.withLock { (_unlockRSSI, _lockRSSI) }
        let decision = SignalHysteresisEngine.checkProximity(
            rssi: Double(rssi), effectiveRSSI: effectiveRSSI,
            unlockRSSI: uRSSI, lockRSSI: lRSSI)
        let threshold = Double(decision.lockThreshold)
        if !decision.isAway {
            // 取消锁屏计时器：锁内取引用并清空，invalidate 派发回主线程（Timer 注册在主 RunLoop）
            let oldTimer: Timer? = lock.withLock {
                let t = proximityTimer
                proximityTimer = nil
                return t
            }
            if let oldTimer { DispatchQueue.main.async { oldTimer.invalidate() } }
        } else {
            let (curPresence, curTimer) = lock.withLock { (presence, proximityTimer) }
            lockLog("[LOCK] applyLockTimer eff=\(String(format: "%.1f", effectiveRSSI)) threshold=\(Int(threshold)) presence=\(curPresence) hasTimer=\(curTimer != nil)")
            if curPresence && curTimer == nil {
                // 冷静期：刚解锁后不立即触发锁定，防止 effectiveRSSI 衰减导致振荡
                // （lastProximityEventTime 锁内读，修复锁外读 vs 锁内写竞态）
                let lastUnlock = lock.withLock { lastProximityEventTime }
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
                let lockOnIdle = ConfigStore.shared.bool(forKey: "lockOnIdle", default: true)
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
