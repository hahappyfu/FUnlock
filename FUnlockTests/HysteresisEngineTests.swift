// SignalHysteresisEngine 迟滞核心测试(Wave 2 Agent B 填充)
import XCTest
@testable import FUnlock

/// checkProximity 双阈值迟滞判定矩阵。
/// 引擎无状态："迟滞带维持上一状态"在引擎侧表现为 isClose/isAway 双否，
/// presence 的保持由 FUnSignalProcessor 依据双否结果实现。
final class SignalHysteresisProximityTests: XCTestCase {
    // 标准配置：unlock=-60, lock=unlock-gap=-70（lockUnlockDelayGap=10）
    private let unlock = -60
    private let lock = -70

    func testFarFieldIsAway() {
        let d = SignalHysteresisEngine.checkProximity(effectiveRSSI: -75, unlockRSSI: unlock, lockRSSI: lock)
        XCTAssertFalse(d.isClose)
        XCTAssertTrue(d.isAway)
    }

    func testNearFieldIsClose() {
        let d = SignalHysteresisEngine.checkProximity(effectiveRSSI: -55, unlockRSSI: unlock, lockRSSI: lock)
        XCTAssertTrue(d.isClose)
        XCTAssertFalse(d.isAway)
    }

    func testHysteresisBandHoldsPreviousState() {
        // 中间带（-70 < eff < -60）：双否 = 调用方保持 presence 不翻转
        let d = SignalHysteresisEngine.checkProximity(effectiveRSSI: -65, unlockRSSI: unlock, lockRSSI: lock)
        XCTAssertFalse(d.isClose, "迟滞带内不应触发靠近")
        XCTAssertFalse(d.isAway, "迟滞带内不应触发离开（否则反复锁屏）")
    }

    func testUnlockBoundaryIsInclusive() {
        // 从 away 越过解锁阈值：eff == unlockThreshold 即算靠近（>= 语义）
        let d = SignalHysteresisEngine.checkProximity(effectiveRSSI: -60, unlockRSSI: unlock, lockRSSI: lock)
        XCTAssertTrue(d.isClose)
        XCTAssertFalse(d.isAway)
    }

    func testLockBoundaryIsExclusive() {
        // 从 near 跌落：eff == lockThreshold 时既不靠近也不离开（< 语义），再低才离开
        let atBoundary = SignalHysteresisEngine.checkProximity(effectiveRSSI: -70, unlockRSSI: unlock, lockRSSI: lock)
        XCTAssertFalse(atBoundary.isClose)
        XCTAssertFalse(atBoundary.isAway, "eff == lockThreshold 处于迟滞下沿内侧，不应立即判离")

        let below = SignalHysteresisEngine.checkProximity(effectiveRSSI: -70.5, unlockRSSI: unlock, lockRSSI: lock)
        XCTAssertTrue(below.isAway)
    }

    func testHysteresisGapWidthMatchesLockUnlockDelayGap() {
        // gap=10 标准联动：迟滞带两侧边界——紧贴解锁阈值下沿保持，跌破锁定阈值离开
        let belowUnlock = SignalHysteresisEngine.checkProximity(effectiveRSSI: -60.1, unlockRSSI: unlock, lockRSSI: lock)
        XCTAssertFalse(belowUnlock.isClose)
        XCTAssertFalse(belowUnlock.isAway)

        let belowLock = SignalHysteresisEngine.checkProximity(effectiveRSSI: -70.1, unlockRSSI: unlock, lockRSSI: lock)
        XCTAssertFalse(belowLock.isClose)
        XCTAssertTrue(belowLock.isAway)
        XCTAssertEqual(belowLock.unlockThreshold, unlock)
        XCTAssertEqual(belowLock.lockThreshold, lock)
    }

    func testAwayCrossingUnlockThresholdFlipsToClose() {
        var d = SignalHysteresisEngine.checkProximity(effectiveRSSI: -75, unlockRSSI: unlock, lockRSSI: lock)
        XCTAssertTrue(d.isAway, "前置：处于 away")
        d = SignalHysteresisEngine.checkProximity(effectiveRSSI: -59, unlockRSSI: unlock, lockRSSI: lock)
        XCTAssertTrue(d.isClose, "从 away 越过解锁阈值应翻转为靠近")
    }

    func testNearDroppingBelowLockThresholdFlipsToAway() {
        var d = SignalHysteresisEngine.checkProximity(effectiveRSSI: -55, unlockRSSI: unlock, lockRSSI: lock)
        XCTAssertTrue(d.isClose, "前置：处于 near")
        d = SignalHysteresisEngine.checkProximity(effectiveRSSI: -71, unlockRSSI: unlock, lockRSSI: lock)
        XCTAssertTrue(d.isAway, "从 near 跌破锁定阈值应翻转为离开")
    }

    func testUnlockDisabledSentinelFallsBackToLockThreshold() {
        // 解锁禁用哨兵：解锁阈值回退 lockRSSI（是否解锁由调用方 unlockEnabled 门控）
        let d = SignalHysteresisEngine.checkProximity(
            effectiveRSSI: -75, unlockRSSI: FUn.UNLOCK_DISABLED, lockRSSI: lock)
        XCTAssertEqual(d.unlockThreshold, lock, "禁用哨兵下解锁阈值应回退锁定阈值")
        XCTAssertFalse(d.isClose)
        XCTAssertTrue(d.isAway)
    }

    func testLockDisabledSentinelCollapsesHysteresisBand() {
        // 锁定禁用哨兵：锁定阈值回退解锁阈值 → 无保持区，isClose 与 isAway 互补
        let near = SignalHysteresisEngine.checkProximity(
            effectiveRSSI: -59.9, unlockRSSI: unlock, lockRSSI: FUn.LOCK_DISABLED)
        XCTAssertTrue(near.isClose)
        XCTAssertFalse(near.isAway)

        let away = SignalHysteresisEngine.checkProximity(
            effectiveRSSI: -60.1, unlockRSSI: unlock, lockRSSI: FUn.LOCK_DISABLED)
        XCTAssertFalse(away.isClose)
        XCTAssertTrue(away.isAway, "窗口坍缩后跌破单阈值即离开，无迟滞保护")
        XCTAssertEqual(away.lockThreshold, unlock)
    }
}

/// 阈值解析与钳制、动态锁屏超时的边界测试
final class SignalHysteresisThresholdTests: XCTestCase {

    func testClampRSSIBoundaryValues() {
        XCTAssertEqual(SignalHysteresisEngine.clampRSSI(SignalHysteresisEngine.rssiRange.lowerBound), -95)
        XCTAssertEqual(SignalHysteresisEngine.clampRSSI(SignalHysteresisEngine.rssiRange.upperBound), -30)
    }

    func testClampRSSIOutOfRangeValues() {
        XCTAssertEqual(SignalHysteresisEngine.clampRSSI(-120), -95, "越下界钳到 -95")
        XCTAssertEqual(SignalHysteresisEngine.clampRSSI(-100), -95)
        XCTAssertEqual(SignalHysteresisEngine.clampRSSI(0), -30, "越上界钳到 -30")
        XCTAssertEqual(SignalHysteresisEngine.clampRSSI(1), -30)
    }

    func testClampRSSINormalValuePassesThrough() {
        XCTAssertEqual(SignalHysteresisEngine.clampRSSI(-60), -60)
    }

    func testResolvedLockThresholdNormalPair() {
        XCTAssertEqual(SignalHysteresisEngine.resolvedLockThreshold(unlockRSSI: -60, lockRSSI: -70), -70)
    }

    func testResolvedLockThresholdLockDisabledFallsBackToUnlock() {
        XCTAssertEqual(
            SignalHysteresisEngine.resolvedLockThreshold(unlockRSSI: -60, lockRSSI: FUn.LOCK_DISABLED),
            -60, "锁定禁用哨兵下锁定阈值回退解锁阈值（迟滞窗口关闭）")
    }

    func testResolvedLockThresholdIgnoresUnlockDisabledSentinel() {
        // lock 侧解析只认 lockDisabled 哨兵；unlock 侧哨兵不影响 lock 阈值
        XCTAssertEqual(
            SignalHysteresisEngine.resolvedLockThreshold(unlockRSSI: FUn.UNLOCK_DISABLED, lockRSSI: -70),
            -70)
    }

    func testResolvedLockThresholdBothDisabledPassesUnlockThrough() {
        // 双哨兵成对输入：lockDisabled 命中 → 透传 unlockRSSI（纯透传语义，不二次判哨兵）
        XCTAssertEqual(
            SignalHysteresisEngine.resolvedLockThreshold(unlockRSSI: FUn.UNLOCK_DISABLED, lockRSSI: FUn.LOCK_DISABLED),
            FUn.UNLOCK_DISABLED)
    }

    func testLockTimeoutMonotonicAcrossInterpolationBandAndContinuousAtEdges() {
        // 陡降/缓降/精确插值已在 UIAndUtilityTests 覆盖（经 FUn 转发同一实现）；
        // 此处补中间带单调性与两边界连续无跳变（引擎入口直测）
        let slopes = stride(from: -8.0, through: -1.0, by: 0.5).map { $0 }
        var previous = SignalHysteresisEngine.lockTimeout(slope: slopes[0])
        XCTAssertEqual(previous, 2.5, "快速档边界应取 fastLockTimeout")
        for slope in slopes.dropFirst() {
            let t = SignalHysteresisEngine.lockTimeout(slope: slope)
            XCTAssertGreaterThanOrEqual(t, previous, "下降斜率放缓（slope 上升）超时应单调不减")
            previous = t
        }
        XCTAssertEqual(previous, 5.0, "缓降档边界应取 base")
        XCTAssertEqual(SignalHysteresisEngine.lockTimeout(slope: -8.001), 2.5, accuracy: 0.01, "快速档边界外连续无跳变")
        XCTAssertEqual(SignalHysteresisEngine.lockTimeout(slope: -1.001), 5.0, accuracy: 0.001, "缓降档边界外连续无跳变")
    }
}
