// RangeRailTests.swift
// Phase 2 TDD：交互式距离标尺的纯几何契约
// 定义域以 SignalHysteresisEngine.rssiRange（-95…-30）为唯一来源

import XCTest
@testable import FUnlock

final class RangeRailTests: XCTestCase {

    private let width: CGFloat = 325

    // MARK: - 定义域

    func testDomainMatchesSignalEngine() {
        XCTAssertEqual(RangeRailGeometry.minRSSI, -95)
        XCTAssertEqual(RangeRailGeometry.maxRSSI, -30)
        XCTAssertEqual(RangeRailGeometry.minRSSI, SignalHysteresisEngine.rssiRange.lowerBound)
        XCTAssertEqual(RangeRailGeometry.maxRSSI, SignalHysteresisEngine.rssiRange.upperBound)
    }

    func testSentinelIsOne() {
        XCTAssertEqual(SignalHysteresisEngine.unlockDisabled, 1)
        XCTAssertEqual(FUn.UNLOCK_DISABLED, 1)
    }

    // MARK: - 坐标换算

    func testPositionBoundaries() {
        XCTAssertEqual(RangeRailGeometry.position(forRSSI: -95, width: width), 0, accuracy: 0.001)
        XCTAssertEqual(RangeRailGeometry.position(forRSSI: -30, width: width), width, accuracy: 0.001)
    }

    func testPositionClampsOutOfRange() {
        XCTAssertEqual(RangeRailGeometry.position(forRSSI: -100, width: width), 0, accuracy: 0.001)
        XCTAssertEqual(RangeRailGeometry.position(forRSSI: 1, width: width), width, accuracy: 0.001)
    }

    func testRSSIRoundTrip() {
        for rssi in stride(from: -95, through: -30, by: 5) {
            let x = RangeRailGeometry.position(forRSSI: rssi, width: width)
            XCTAssertEqual(RangeRailGeometry.rssi(forX: x, width: width), rssi,
                           "往返换算必须无损：\(rssi)")
        }
    }

    func testRSSIForXClamps() {
        XCTAssertEqual(RangeRailGeometry.rssi(forX: -20, width: width), -95)
        XCTAssertEqual(RangeRailGeometry.rssi(forX: width + 20, width: width), -30)
    }

    func testZeroWidthIsSafe() {
        XCTAssertEqual(RangeRailGeometry.position(forRSSI: -60, width: 0), 0)
        XCTAssertEqual(RangeRailGeometry.rssi(forX: 10, width: 0), -95)
    }

    // MARK: - 锁定阈值约束

    func testClampLockEnforcesOrderAndRange() {
        XCTAssertEqual(RangeRailGeometry.clampLock(-70, unlock: -60), -70)
        XCTAssertEqual(RangeRailGeometry.clampLock(-55, unlock: -60), -61, "锁定必须严格小于解锁")
        XCTAssertEqual(RangeRailGeometry.clampLock(-120, unlock: -60), -95, "低于下限钳到 -95")
        XCTAssertEqual(RangeRailGeometry.clampLock(-20, unlock: -60), -61, "先钳范围再守序关系")
    }

    func testClampLockIgnoresOrderWhenUnlockDisabled() {
        XCTAssertEqual(RangeRailGeometry.clampLock(-40, unlock: FUn.UNLOCK_DISABLED), -40)
    }

    // MARK: - 迟滞联动

    func testLinkedLockShiftsWhenNotUserModified() {
        XCTAssertEqual(RangeRailGeometry.linkedLock(forUnlock: -70, currentLock: -80, userModified: false), -80)
        XCTAssertEqual(RangeRailGeometry.linkedLock(forUnlock: -60, currentLock: -80, userModified: false), -70)
    }

    func testLinkedLockClampsAtFloor() {
        XCTAssertEqual(RangeRailGeometry.linkedLock(forUnlock: -92, currentLock: -80, userModified: false), -95)
    }

    func testLinkedLockPreservesManualLock() {
        XCTAssertEqual(RangeRailGeometry.linkedLock(forUnlock: -70, currentLock: -85, userModified: true), -85)
    }

    func testLinkedLockFixesManualViolation() {
        XCTAssertEqual(RangeRailGeometry.linkedLock(forUnlock: -70, currentLock: -65, userModified: true), -71)
    }

    func testLinkedLockDoesNotShiftWhenUnlockDisabled() {
        XCTAssertEqual(RangeRailGeometry.linkedLock(forUnlock: FUn.UNLOCK_DISABLED,
                                                    currentLock: -80, userModified: false), -80)
    }

    // MARK: - 缓冲带

    func testHysteresisGap() {
        XCTAssertEqual(RangeRailGeometry.hysteresisGap(lock: -80, unlock: -70), 10)
        XCTAssertEqual(RangeRailGeometry.hysteresisGap(lock: -70, unlock: -70), 0)
        XCTAssertEqual(RangeRailGeometry.hysteresisGap(lock: -60, unlock: -70), 0, "逆序时不得为负")
    }

    func testBufferNarrowBelowTen() {
        XCTAssertTrue(RangeRailGeometry.isBufferNarrow(lock: -78, unlock: -70), "9 dB 属过窄")
        XCTAssertFalse(RangeRailGeometry.isBufferNarrow(lock: -80, unlock: -70), "10 dB 为下限，不算过窄")
        XCTAssertFalse(RangeRailGeometry.isBufferNarrow(lock: -90, unlock: -70))
    }
}
