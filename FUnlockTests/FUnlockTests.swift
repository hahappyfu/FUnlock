import XCTest
@testable import FUnlock

class FUnlockTests: XCTestCase {

    // MARK: - EMA (Exponential Moving Average) Tests

    func testEMASingleValue() {
        let fun = FUn()
        let result = fun.getEstimatedRSSI(rssi: -60)
        XCTAssertEqual(result, -60, "First value should be the raw RSSI")
    }

    func testEMATwoValues() {
        let fun = FUn()
        _ = fun.getEstimatedRSSI(rssi: -60)
        let result = fun.getEstimatedRSSI(rssi: -70)
        // EMA: -60 * 0.7 + (-70) * 0.3 = -42 + (-21) = -63
        XCTAssertEqual(result, -63, "EMA with alpha=0.3 should weight recent value less")
    }

    func testEMAConvergence() {
        let fun = FUn()
        // Feed many values at -80, then one at -50
        for _ in 0..<20 {
            _ = fun.getEstimatedRSSI(rssi: -80)
        }
        let result = fun.getEstimatedRSSI(rssi: -50)
        // After convergence to -80, one -50 should shift slightly
        // EMA: -80 * 0.7 + (-50) * 0.3 = -56 + (-15) = -71
        XCTAssertEqual(result, -71, "EMA should shift toward new value")
    }

    func testEMABufferLimit() {
        let fun = FUn()
        fun.latestN = 3
        _ = fun.getEstimatedRSSI(rssi: -60)
        _ = fun.getEstimatedRSSI(rssi: -70)
        _ = fun.getEstimatedRSSI(rssi: -80)
        _ = fun.getEstimatedRSSI(rssi: -90)
        XCTAssertTrue(fun.latestRSSIs.count <= fun.latestN, "Buffer should respect latestN limit")
    }

    // MARK: - Signal Lost Count Tests

    func testSignalLostCountReset() {
        let fun = FUn()
        fun.signalLostCount = 2
        // Simulate signal received by calling updateMonitoredPeripheral
        _ = fun.updateMonitoredPeripheral(-60)
        XCTAssertEqual(fun.signalLostCount, 0, "Signal lost count should reset on signal receipt")
    }

    // MARK: - Adaptive Polling Tests

    func testStableCountTracking() {
        let fun = FUn()
        fun.lastEstimatedRSSI = -60
        // Feed stable values (within 5 dBm threshold)
        _ = fun.updateMonitoredPeripheral(-62)
        _ = fun.updateMonitoredPeripheral(-61)
        _ = fun.updateMonitoredPeripheral(-59)
        XCTAssertGreaterThan(fun.stableCount, 0, "Stable RSSI should increase stableCount")
    }

    func testStableCountReset() {
        let fun = FUn()
        fun.stableCount = 10
        fun.lastEstimatedRSSI = -60
        // Feed a value with large fluctuation
        _ = fun.updateMonitoredPeripheral(-90)
        XCTAssertEqual(fun.stableCount, 0, "Large fluctuation should reset stableCount")
    }

    // MARK: - Version Comparison Tests

    func testVersionComparison() {
        // Test that different versions are detected
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertNotNil(currentVersion, "App should have a version string")
    }
}
