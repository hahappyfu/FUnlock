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
        // 填入正常窗口
        for i in 0..<6 {
            _ = pipeline.process(rssi: -60 + i, source: .connected, now: now.addingTimeInterval(Double(i) * 0.1))
        }
        let decision = pipeline.process(rssi: -62, source: .connected, now: now.addingTimeInterval(1.0))
        XCTAssertFalse(decision.isAnomalous, "Normal value should not be anomalous")
    }

    func testIQR_outlierDetected() {
        var pipeline = SignalPipeline()
        let now = Date()
        // 填入稳定窗口
        for i in 0..<10 {
            _ = pipeline.process(rssi: -60, source: .connected, now: now.addingTimeInterval(Double(i) * 0.1))
        }
        let decision = pipeline.process(rssi: -30, source: .connected, now: now.addingTimeInterval(1.0))
        XCTAssertTrue(decision.isAnomalous, "Extreme outlier should be detected")
    }

    // MARK: - SignalPipeline: EWLR Slope

    func testSlope_rising() {
        var pipeline = SignalPipeline()
        let now = Date()
        // RSSI 逐渐上升（设备靠近）
        for i in 0..<8 {
            let rssi = -80 + i * 3  // -80, -77, -74, ..., -59
            _ = pipeline.process(rssi: rssi, source: .connected, now: now.addingTimeInterval(Double(i) * 0.15))
        }
        let decision = pipeline.process(rssi: -56, source: .connected, now: now.addingTimeInterval(1.2))
        XCTAssertGreaterThan(decision.slope, 0, "Slope should be positive when approaching")
    }

    func testSlope_falling() {
        var pipeline = SignalPipeline()
        let now = Date()
        // RSSI 逐渐下降（设备远离）
        for i in 0..<8 {
            let rssi = -60 - i * 3
            _ = pipeline.process(rssi: rssi, source: .connected, now: now.addingTimeInterval(Double(i) * 0.15))
        }
        let decision = pipeline.process(rssi: -85, source: .connected, now: now.addingTimeInterval(1.2))
        XCTAssertLessThan(decision.slope, 0, "Slope should be negative when departing")
    }

    // MARK: - SignalPipeline: Two-Stage Adaptive Decay

    func testDecay_fastWhenSlopeLarge() {
        var pipeline = SignalPipeline()
        let now = Date()
        // 快速衰减的 RSSI（|slope| > 2）
        for i in 0..<10 {
            _ = pipeline.process(rssi: -60 - i * 4, source: .connected, now: now.addingTimeInterval(Double(i) * 0.15))
        }
        let decision = pipeline.process(rssi: -90, source: .connected, now: now.addingTimeInterval(1.5))
        // 有效 RSSI 应低于 kalmanEstimate（有衰减惩罚）
        XCTAssertLessThan(decision.effectiveRSSI, decision.kalmanEstimate, "Fast decay should penalize")
    }

    func testDecay_floorClamp() {
        var pipeline = SignalPipeline()
        let now = Date()
        // 很久没有信号，模拟长衰减
        var pipeline2 = pipeline
        let decision = pipeline2.process(rssi: -90, source: .scanning, now: now)
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

    func testCanAutoUnlockNormal() {
        var state = LockScreenState()
        state.screen = .unlocked
        state.system = .awake
        state.intent = .autoLock
        XCTAssertTrue(state.canAutoUnlock)
    }

    func testCanAutoUnlockBlockedByManualLock() {
        var state = LockScreenState()
        state.screen = .locked(reason: .manual)
        state.system = .awake
        state.intent = .manualLock(deadline: Date().addingTimeInterval(60))
        XCTAssertFalse(state.canAutoUnlock)
    }

    func testCanAutoUnlockBlockedBySleep() {
        var state = LockScreenState()
        state.screen = .locked(reason: .away)
        state.system = .sleeping
        XCTAssertFalse(state.canAutoUnlock)
    }

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

    func testManualLockExpired() {
        let intent = LockIntent.manualLock(deadline: Date().addingTimeInterval(-1))
        XCTAssertFalse(intent.isManualLockActive)
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
