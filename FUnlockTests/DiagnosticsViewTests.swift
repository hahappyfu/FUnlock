// FUnlockTests/DiagnosticsViewTests.swift
import XCTest
@testable import FUnlock

final class DiagnosticsViewTests: XCTestCase {
    func testScreenLabelMapsKnownStates() {
        XCTAssertEqual(DecisionEvent.screenLabel("locked(away)"), "screen_locked_away")
        XCTAssertEqual(DecisionEvent.screenLabel("locked(manual)"), "screen_locked_manual")
        XCTAssertEqual(DecisionEvent.screenLabel("unlocked"), "screen_unlocked")
        XCTAssertEqual(DecisionEvent.screenLabel("displaySleeping"), "screen_display_sleeping")
    }

    func testScreenLabelFallsBackToRaw() {
        XCTAssertEqual(DecisionEvent.screenLabel("unknown"), "unknown")
        XCTAssertNil(DecisionEvent.screenLabel(nil))
    }

    // MARK: - 时间线分块（滚动帧率修复）

    /// 单张卡片行数上限：超过 pageSize 必须切成多块，否则滚动每帧重建巨型渲染单元
    func testChunkedSplitsIntoBoundedPages() {
        let events = (0 ..< 467).map { i in
            DecisionEvent(timestamp: Date(), category: .unlock, outcome: .skipped,
                          reason: .wifiPaused, rssi: nil, device: nil, screen: nil)
        }
        let chunks = events.chunked(pageSize: DiagnosticsView.timelinePageSize)
        XCTAssertEqual(chunks.count, 12)  // 467 / 40 = 11 满块 + 1 余块
        XCTAssertTrue(chunks.allSatisfy { $0.count <= DiagnosticsView.timelinePageSize })
        XCTAssertEqual(chunks.last?.count, 467 - 11 * DiagnosticsView.timelinePageSize)
    }

    /// 分块不得丢行或改序
    func testChunkedPreservesOrderAndCount() {
        let events = (0 ..< 97).map { i in
            DecisionEvent(timestamp: Date(), category: .lock, outcome: .success,
                          reason: .lockedAway, rssi: nil, device: nil, screen: nil)
        }
        let flat = events.chunked(pageSize: 40).flatMap { $0 }
        XCTAssertEqual(flat.map(\.id), events.map(\.id))
    }

    func testChunkedEdgeCases() {
        XCTAssertTrue([Int]().chunked(pageSize: 40).isEmpty)
        XCTAssertEqual([1].chunked(pageSize: 40), [[1]])
        XCTAssertEqual(Array(1 ... 40).chunked(pageSize: 40).count, 1)
        XCTAssertEqual(Array(1 ... 41).chunked(pageSize: 40).count, 2)
    }
}
