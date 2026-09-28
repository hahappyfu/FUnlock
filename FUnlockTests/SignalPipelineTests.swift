import XCTest
@testable import FUnlock

class FUnlockTests: XCTestCase {

    // MARK: - SignalPipeline: Kalman Filter Tests

    func testKalmanSingleValue() {
        var pipeline = SignalPipeline()
        let decision = pipeline.process(rssi: -60, source: .connected, now: Date())
        XCTAssertEqual(decision.kalmanEstimate, -60, accuracy: 5, "First value should be near raw RSSI")
    }

    func testKalmanDampensNoise() {
        var pipeline = SignalPipeline()
        let now = Date()
        for i in 0..<6 {
            _ = pipeline.process(rssi: -60 + (i % 2 == 0 ? -5 : 5), source: .connected, now: now.addingTimeInterval(Double(i) * 0.1))
        }
        let decision = pipeline.process(rssi: -60, source: .connected, now: now.addingTimeInterval(1.0))
        XCTAssertEqual(decision.kalmanEstimate, -60, accuracy: 10, "Kalman should dampen noise")
    }

    func testKalmanAsymmetricRising() {
        var pipeline = SignalPipeline()
        // 冷启动填充 6 个样本
        for i in 0..<6 {
            _ = pipeline.process(rssi: -80, source: .connected, now: Date().addingTimeInterval(Double(i) * 0.1))
        }
        let before = pipeline.kalmanEstimate
        let decision = pipeline.process(rssi: -50, source: .connected, now: Date().addingTimeInterval(1.0))
        XCTAssertGreaterThan(decision.kalmanEstimate, before, "Kalman should track upward jump")
    }

    func testKalmanAsymmetricFalling() {
        var pipeline = SignalPipeline()
        // 冷启动填充 6 个样本
        for i in 0..<6 {
            _ = pipeline.process(rssi: -50, source: .connected, now: Date().addingTimeInterval(Double(i) * 0.1))
        }
        let before = pipeline.kalmanEstimate
        let decision = pipeline.process(rssi: -80, source: .connected, now: Date().addingTimeInterval(1.0))
        // 下降时 Kalman 阻尼强，估计值不应大幅跳动
        XCTAssertGreaterThan(decision.kalmanEstimate, before - 15, "Kalman should dampen downward jump")
    }

    // MARK: - SignalPipeline: IQR Anomaly Detection

    func testIQR_normalValues() {
        var pipeline = SignalPipeline()
        let now = Date()
        // 填入正常窗口（process 不会自动 append，需手动模拟 processSignal 行为）
        for i in 0..<6 {
            let t = now.addingTimeInterval(Double(i) * 0.1)
            _ = pipeline.process(rssi: -60 + i, source: .connected, now: t)
            pipeline.latestRSSIs.append(Double(-60 + i))
            pipeline.rssiTimestamps.append(t)
        }
        let decision = pipeline.process(rssi: -62, source: .connected, now: now.addingTimeInterval(1.0))
        XCTAssertFalse(decision.isAnomalous, "Normal value should not be anomalous")
    }

    func testIQR_outlierDetected() {
        var pipeline = SignalPipeline()
        let now = Date()
        // 填入稳定窗口（process 不会自动 append，需手动模拟 processSignal 行为）
        for i in 0..<10 {
            let t = now.addingTimeInterval(Double(i) * 0.1)
            _ = pipeline.process(rssi: -60, source: .connected, now: t)
            pipeline.latestRSSIs.append(-60)
            pipeline.rssiTimestamps.append(t)
        }
        let outlierTime = now.addingTimeInterval(1.0)
        let decision = pipeline.process(rssi: -30, source: .connected, now: outlierTime)
        XCTAssertTrue(decision.isAnomalous, "Extreme outlier should be detected")
    }

    // MARK: - SignalPipeline: EWLR Slope

    func testSlope_rising() {
        var pipeline = SignalPipeline()
        let now = Date()
        // RSSI 逐渐上升（设备靠近），需手动维护时间窗口
        for i in 0..<8 {
            let rssi = -80 + i * 3  // -80, -77, -74, ..., -59
            let t = now.addingTimeInterval(Double(i) * 0.15)
            _ = pipeline.process(rssi: rssi, source: .connected, now: t)
            pipeline.latestRSSIs.append(Double(rssi))
            pipeline.rssiTimestamps.append(t)
        }
        let finalTime = now.addingTimeInterval(1.2)
        let decision = pipeline.process(rssi: -56, source: .connected, now: finalTime)
        XCTAssertGreaterThan(decision.slope, 0, "Slope should be positive when approaching")
    }

    func testSlope_falling() {
        var pipeline = SignalPipeline()
        let now = Date()
        // RSSI 逐渐下降（设备远离），需手动维护时间窗口
        for i in 0..<8 {
            let rssi = -60 - i * 3
            let t = now.addingTimeInterval(Double(i) * 0.15)
            _ = pipeline.process(rssi: rssi, source: .connected, now: t)
            pipeline.latestRSSIs.append(Double(rssi))
            pipeline.rssiTimestamps.append(t)
        }
        let finalTime = now.addingTimeInterval(1.2)
        let decision = pipeline.process(rssi: -85, source: .connected, now: finalTime)
        XCTAssertLessThan(decision.slope, 0, "Slope should be negative when departing")
    }

    // MARK: - SignalPipeline: Two-Stage Adaptive Decay

    func testDecay_fastWhenSlopeLarge() {
        var pipeline = SignalPipeline()
        let now = Date()
        // 快速衰减的 RSSI（|slope| > 2），需手动维护时间窗口
        for i in 0..<10 {
            let t = now.addingTimeInterval(Double(i) * 0.15)
            _ = pipeline.process(rssi: -60 - i * 4, source: .connected, now: t)
            pipeline.latestRSSIs.append(Double(-60 - i * 4))
            pipeline.rssiTimestamps.append(t)
        }
        // 最后一个历史样本在 now+1.35s，最终调用在 now+2.5s → elapsed ≈ 1.15s，产生衰减惩罚
        let finalTime = now.addingTimeInterval(2.5)
        let decision = pipeline.process(rssi: -90, source: .connected, now: finalTime)
        // 有效 RSSI 应低于 kalmanEstimate（有衰减惩罚）
        XCTAssertLessThan(decision.effectiveRSSI, decision.kalmanEstimate, "Fast decay should penalize")
    }

    func testDecay_floorClamp() {
        let pipeline = SignalPipeline()
        let now = Date()
        // 很久没有信号，模拟长衰减
        var pipeline2 = pipeline
        _ = pipeline2.process(rssi: -90, source: .scanning, now: now)
        // 再用一个很远的时间点
        let oldPipeline = pipeline2
        let decision2 = pipeline2.process(rssi: -90, source: .scanning, now: now.addingTimeInterval(500))
        XCTAssertGreaterThanOrEqual(decision2.effectiveRSSI, -100.0, "Should clamp to floor")
        _ = oldPipeline
    }

    // MARK: - SignalPipeline: Source Weight

    func testSourceWeight_connected() {
        var pipeline = SignalPipeline()
        let decision = pipeline.process(rssi: -60, source: .connected, now: Date())
        XCTAssertEqual(decision.sourceWeight, 1.0, "Connected source weight = 1.0")
    }

    func testSourceWeight_scanning() {
        var pipeline = SignalPipeline()
        let decision = pipeline.process(rssi: -60, source: .scanning, now: Date())
        XCTAssertEqual(decision.sourceWeight, 0.7, "Scanning source weight = 0.7")
    }

    // MARK: - SignalPipeline: Reset

    func testReset_clearsState() {
        var pipeline = SignalPipeline()
        for i in 0..<6 {
            _ = pipeline.process(rssi: -60 + i, source: .connected, now: Date().addingTimeInterval(Double(i) * 0.1))
        }
        pipeline.reset()
        XCTAssertEqual(pipeline.kalmanEstimate, -60.0)
        XCTAssertEqual(pipeline.kalmanP, 1.0)
        XCTAssertEqual(pipeline.kalmanSampleCount, 0)
        XCTAssertEqual(pipeline.smoothedSlope, 0.0)
        XCTAssertTrue(pipeline.latestRSSIs.isEmpty)
        XCTAssertTrue(pipeline.rssiTimestamps.isEmpty)
    }

    // MARK: - LockScreenState Tests

    func testIsEffectivelyLocked() {
        var state = LockScreenState()
        state.screen = .unlocked
        XCTAssertFalse(state.isEffectivelyLocked)
        state.screen = .locked(reason: .away)
        XCTAssertTrue(state.isEffectivelyLocked)
    }

    // MARK: - LockIntent Tests

    func testManualLockActive() {
        let intent = LockIntent.manualLock(deadline: Date().addingTimeInterval(60))
        XCTAssertTrue(intent.isManualLockActive)
    }

    func testManualLockStaysActiveAfterDeadlineExpires() {
        // manualLock 语义（审计修复）：deadline 过期后仍无条件阻止，直到 onUnlock 重置 intent；
        // deadline 仅作兜底标记保留，不参与判定
        let intent = LockIntent.manualLock(deadline: Date().addingTimeInterval(-1))
        XCTAssertTrue(intent.isManualLockActive)
    }

    func testAutoLockNeverActive() {
        XCTAssertFalse(LockIntent.autoLock.isManualLockActive)
    }

    // MARK: - Version Check

    func testVersionExists() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertNotNil(version)
    }
}

// MARK: - 预备唤醒（信号平滑 + 阶梯唤醒）测试

/// 测试 smoothedRSSI() EMA 信号平滑逻辑（时间归一化重构）
class SmoothedRSSITests: XCTestCase {

    func testSmoothedRSSIFirstSampleInitializesDirectly() {
        let fun = FUn()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let result = fun.smoothedRSSI(-60, now: t0)
        XCTAssertEqual(result, -60.0, accuracy: 0.001,
                       "首个样本应直接初始化平滑值，不从 -100 开始加权迟滞")
    }

    func testSmoothedRSSIConvergesToRepeatedValue() {
        let fun = FUn()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // 初始首样本 -80，随后按 0.5s 步长持续输入 -50，经过 20 步（10s）应完全收敛到 -50
        _ = fun.smoothedRSSI(-80, now: t0)
        var last: Double = 0
        for i in 1...20 {
            let t = t0.addingTimeInterval(Double(i) * 0.5)
            last = fun.smoothedRSSI(-50, now: t)
        }
        XCTAssertEqual(last, -50.0, accuracy: 0.01,
                       "连续输入相同值应随时间推移收敛到该目标值")
    }

    func testSmoothedRSSIFormulaCorrectness() {
        let fun = FUn()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // 首样本初始化为 -80
        let r0 = fun.smoothedRSSI(-80, now: t0)
        XCTAssertEqual(r0, -80.0, accuracy: 0.001)

        // dt = 0.5s, tau = 1.0s -> alpha = 1 - exp(-0.5) ≈ 0.39346934
        let dt: TimeInterval = 0.5
        let tau: TimeInterval = FUn.preWakeEMATau
        let alpha = 1.0 - exp(-dt / tau)

        // 第2步输入 -50: 预期 value = alpha * (-50) + (1 - alpha) * (-80)
        let t1 = t0.addingTimeInterval(dt)
        let r1 = fun.smoothedRSSI(-50, now: t1)
        let expected1 = alpha * (-50.0) + (1.0 - alpha) * (-80.0)
        XCTAssertEqual(r1, expected1, accuracy: 0.001,
                       "单步时间归一化 EMA 应严格遵循 alpha = 1 - exp(-dt/tau)")

        // 第3步输入 -40: 预期 value = alpha * (-40) + (1 - alpha) * expected1
        let t2 = t1.addingTimeInterval(dt)
        let r2 = fun.smoothedRSSI(-40, now: t2)
        let expected2 = alpha * (-40.0) + (1.0 - alpha) * expected1
        XCTAssertEqual(r2, expected2, accuracy: 0.001,
                       "多步时间归一化 EMA 应严格符合迭代期望")
    }

    func testSmoothedRSSIFrequencyInvariance() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // 路径 A: 1 步驱动，dt = 3.0s
        let funA = FUn()
        _ = funA.smoothedRSSI(-80, now: t0) // 首样本 -80
        let result1Step = funA.smoothedRSSI(-50, now: t0.addingTimeInterval(3.0))

        // 路径 B: 6 步驱动，每步 dt = 0.5s，总时长同样为 3.0s
        let funB = FUn()
        _ = funB.smoothedRSSI(-80, now: t0) // 首样本 -80
        var result6Step: Double = -80.0
        for i in 1...6 {
            let t = t0.addingTimeInterval(Double(i) * 0.5)
            result6Step = funB.smoothedRSSI(-50, now: t)
        }

        XCTAssertEqual(result1Step, result6Step, accuracy: 0.01,
                       "频率无关性：总时长相同且输入相同常数时，1步驱动与6步驱动结果必须严格相等（当前 1步=\(result1Step), 6步=\(result6Step)）")
    }

    func testSmoothedRSSISlowSamplingInstantConvergence() {
        let fun = FUn()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let r0 = fun.smoothedRSSI(-60, now: t0)
        XCTAssertEqual(r0, -60.0, accuracy: 0.001)

        // 8 秒后（被动扫描间隔）喂入 -55
        // alpha = 1 - exp(-8.0 / 1.0) ≈ 0.9996645
        let t1 = t0.addingTimeInterval(8.0)
        let r1 = fun.smoothedRSSI(-55, now: t1)
        XCTAssertEqual(r1, -55.0, accuracy: 0.05,
                       "慢采样模式（dt=8s）下 alpha 接近 1，应一步即采即收敛到新测量值")
    }

    func testSmoothedRSSIResetReinitializesOnNextSample() {
        let fun = FUn()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = fun.smoothedRSSI(-50, now: t0)
        _ = fun.smoothedRSSI(-40, now: t0.addingTimeInterval(0.5))

        fun.resetSmoothedRSSI()
        XCTAssertEqual(fun.currentSmoothedRSSI, -100.0, "reset 后平滑值重置为 -100")

        let t1 = t0.addingTimeInterval(10.0)
        let afterReset = fun.smoothedRSSI(-60, now: t1)
        XCTAssertEqual(afterReset, -60.0, accuracy: 0.001,
                       "重置后首次调用应作为首样本直接初始化为测量值 -60")
    }

    func testSmoothedRSSIThreadSafety() {
        // 多线程并发调用不崩溃（验证 UnfairLock 保护）
        let fun = FUn()
        let group = DispatchGroup()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                let t = t0.addingTimeInterval(Double(i) * 0.1)
                _ = fun.smoothedRSSI(Int.random(in: -90 ... -30), now: t)
                group.leave()
            }
        }
        group.wait()
        // 无崩溃即通过
        let final = fun.smoothedRSSI(-60, now: t0.addingTimeInterval(20.0))
        XCTAssertNotNil(final, "并发调用后仍能正常返回值")
    }
}

/// 测试阶梯唤醒阈值（由解锁阈值 - 用户偏移派生）
class StaircaseThresholdTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // 快照生产域原值并注册恢复（FUn 经 SignalHysteresisEngine 硬编码读 ConfigStore.shared），
        // 再清空保证派生阈值从默认值出发，避免测试间与真实配置相互污染
        let snapshot = ConfigKeySnapshot(keys: ["wakeAdvance", "preUnlockTrigger"])
        addTeardownBlock { snapshot.restore() }
        ConfigStore.shared.defaults.removeObject(forKey: "wakeAdvance")
        ConfigStore.shared.defaults.removeObject(forKey: "preUnlockTrigger")
    }

    func testPreWakeThresholdDerivedFromUnlockRSSI() {
        let fun = FUn()
        ConfigStore.shared.defaults.set(20, forKey: "wakeAdvance")
        XCTAssertEqual(fun.preWakeThreshold, fun.unlockRSSI - 20,
                       "预备唤醒阈值 = 解锁阈值 - 唤醒提前量（默认 20dB）")
    }

    func testUnlockStairThresholdUsesPreUnlockTrigger() {
        let fun = FUn()
        ConfigStore.shared.defaults.set(10, forKey: "preUnlockTrigger")
        XCTAssertEqual(fun.unlockStairThreshold, fun.unlockRSSI - 10,
                       "阶梯解锁阈值 = 解锁阈值 - 预解锁触发量（默认 10dB）")
    }

    func testStaircaseGapIs10dBm() {
        let fun = FUn()
        ConfigStore.shared.defaults.set(20, forKey: "wakeAdvance")
        ConfigStore.shared.defaults.set(10, forKey: "preUnlockTrigger")
        let gap = fun.unlockStairThreshold - fun.preWakeThreshold
        XCTAssertEqual(gap, 10,
                       "阶梯间距应为 10dB（唤醒提前 20dB、预解锁触发提前 10dB）")
    }

    func testPreWakeThresholdIsWeakerThanUnlockThreshold() {
        let fun = FUn()
        ConfigStore.shared.defaults.set(20, forKey: "wakeAdvance")
        ConfigStore.shared.defaults.set(10, forKey: "preUnlockTrigger")
        XCTAssertLessThan(fun.preWakeThreshold, fun.unlockStairThreshold,
                          "preWakeThreshold 应比 unlockStairThreshold 更远（更负）")
    }

    func testCustomOffsetsApply() {
        let fun = FUn()
        ConfigStore.shared.defaults.set(20, forKey: "wakeAdvance")
        ConfigStore.shared.defaults.set(10, forKey: "preUnlockTrigger")
        XCTAssertEqual(fun.preWakeThreshold, fun.unlockRSSI - 20, "自定义唤醒提前量生效")
        XCTAssertEqual(fun.unlockStairThreshold, fun.unlockRSSI - 10, "自定义预解锁触发量生效")
    }

    func testOffsetClampNegative() {
        XCTAssertEqual(FUn.clampOffset(-5), 0, "负偏移应钳制为 0")
        XCTAssertEqual(FUn.clampOffset(30), 20, "超大偏移应钳制为 20")
        XCTAssertEqual(FUn.clampOffset(12), 12, "范围内偏移保持不变")
    }

    func testDerivedThresholdUsesClampedValues() {
        let fun = FUn()
        // 越界输入在 getter 层钳制，防止无意义阈值
        ConfigStore.shared.defaults.set(-10, forKey: "wakeAdvance")
        ConfigStore.shared.defaults.set(50, forKey: "preUnlockTrigger")
        XCTAssertEqual(fun.preWakeThreshold, fun.unlockRSSI,
                       "wakeAdvance -10 应钳制为 0（唤醒点=解锁阈值）")
        XCTAssertEqual(fun.unlockStairThreshold, fun.unlockRSSI - 20,
                       "preUnlockTrigger 50 应钳制为 20")
    }

    /// 审计 B5 #14：解锁阈值放宽到 -100 时外推值（-120/-110）钳制到物理下限 -100。
    /// 此前 -120 的 preWake 永不可能被信号触达，displaySleeping 下任意信号即触发唤醒
    func testDerivedThresholdClampedAtMinus100() {
        let fun = FUn()
        fun.unlockRSSI = -100  // 最低可配置解锁阈值
        ConfigStore.shared.defaults.set(20, forKey: "wakeAdvance")
        ConfigStore.shared.defaults.set(10, forKey: "preUnlockTrigger")
        XCTAssertEqual(fun.preWakeThreshold, -100,
                       "外推值 -120 应钳制到物理下限 -100（避免任意信号触发预备唤醒）")
        XCTAssertEqual(fun.unlockStairThreshold, -100,
                       "外推值 -110 应钳制到物理下限 -100")
    }

    /// 哨兵语义：解锁禁用（unlockRSSI == UNLOCK_DISABLED == 1）时原样返回，
    /// 调用方据此跳过阶梯唤醒（不受 -100 钳制影响）
    func testDerivedThresholdUnlockDisabledSentinel() {
        let fun = FUn()
        fun.unlockRSSI = FUn.UNLOCK_DISABLED
        XCTAssertEqual(fun.preWakeThreshold, FUn.UNLOCK_DISABLED,
                       "解锁禁用哨兵应原样返回（不参与 -100 钳制）")
        XCTAssertEqual(fun.unlockStairThreshold, FUn.UNLOCK_DISABLED,
                       "解锁禁用哨兵应原样返回（不参与 -100 钳制）")
    }
}
