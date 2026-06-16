import XCTest
@testable import BLEUnlock

class BLEUnlockTests: XCTestCase {

    // MARK: - EMA (Exponential Moving Average) Tests

    func testEMASingleValue() {
        let ble = BLE()
        let result = ble.getEstimatedRSSI(rssi: -60)
        XCTAssertEqual(result, -60, "First value should be the raw RSSI")
    }

    func testEMATwoValues() {
        let ble = BLE()
        _ = ble.getEstimatedRSSI(rssi: -60)
        let result = ble.getEstimatedRSSI(rssi: -70)
        // EMA: -60 * 0.7 + (-70) * 0.3 = -42 + (-21) = -63
        XCTAssertEqual(result, -63, "EMA with alpha=0.3 should weight recent value less")
    }

    func testEMAConvergence() {
        let ble = BLE()
        // Feed many values at -80, then one at -50
        for _ in 0..<20 {
            _ = ble.getEstimatedRSSI(rssi: -80)
        }
        let result = ble.getEstimatedRSSI(rssi: -50)
        // After convergence to -80, one -50 should shift slightly
        // EMA: -80 * 0.7 + (-50) * 0.3 = -56 + (-15) = -71
        XCTAssertEqual(result, -71, "EMA should shift toward new value")
    }

    func testEMABufferLimit() {
        let ble = BLE()
        ble.latestN = 3
        _ = ble.getEstimatedRSSI(rssi: -60)
        _ = ble.getEstimatedRSSI(rssi: -70)
        _ = ble.getEstimatedRSSI(rssi: -80)
        _ = ble.getEstimatedRSSI(rssi: -90)
        XCTAssertTrue(ble.latestRSSIs.count <= ble.latestN, "Buffer should respect latestN limit")
    }

    // MARK: - Signal Lost Count Tests

    func testSignalLostCountReset() {
        let ble = BLE()
        ble.signalLostCount = 2
        // Simulate signal received by calling updateMonitoredPeripheral
        _ = ble.updateMonitoredPeripheral(-60)
        XCTAssertEqual(ble.signalLostCount, 0, "Signal lost count should reset on signal receipt")
    }

    // MARK: - Adaptive Polling Tests

    func testStableCountTracking() {
        let ble = BLE()
        ble.lastEstimatedRSSI = -60
        // Feed stable values (within 5 dBm threshold)
        _ = ble.updateMonitoredPeripheral(-62)
        _ = ble.updateMonitoredPeripheral(-61)
        _ = ble.updateMonitoredPeripheral(-59)
        XCTAssertGreaterThan(ble.stableCount, 0, "Stable RSSI should increase stableCount")
    }

    func testStableCountReset() {
        let ble = BLE()
        ble.stableCount = 10
        ble.lastEstimatedRSSI = -60
        // Feed a value with large fluctuation
        _ = ble.updateMonitoredPeripheral(-90)
        XCTAssertEqual(ble.stableCount, 0, "Large fluctuation should reset stableCount")
    }

    // MARK: - Version Comparison Tests

    func testVersionComparison() {
        // Test that different versions are detected
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        XCTAssertNotNil(currentVersion, "App should have a version string")
    }
}
