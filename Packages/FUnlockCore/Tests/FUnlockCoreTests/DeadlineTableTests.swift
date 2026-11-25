import XCTest
import FUnlockCore

final class DeadlineTableTests: XCTestCase {
    func testEarliestReturnsMinimumDeadlineAcrossKinds() {
        var table = DeadlineTable()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        table.set(.heartbeat, at: t0.addingTimeInterval(8))
        table.set(.lockConfirm, at: t0.addingTimeInterval(2.5))
        table.set(.deviceExpiry(UUID()), at: t0.addingTimeInterval(60))

        let earliest = table.earliest()
        XCTAssertEqual(earliest?.id, .lockConfirm)
        XCTAssertEqual(earliest?.date, t0.addingTimeInterval(2.5))
    }

    func testMatchesRejectsReplacedOrClearedDeadline() {
        var table = DeadlineTable()
        let t1 = Date(timeIntervalSince1970: 1_700_000_010)
        let t2 = t1.addingTimeInterval(5)
        table.set(.lockConfirm, at: t1)
        XCTAssertTrue(table.matches(.lockConfirm, scheduledAt: t1))

        table.set(.lockConfirm, at: t2)
        XCTAssertFalse(table.matches(.lockConfirm, scheduledAt: t1))
        XCTAssertTrue(table.matches(.lockConfirm, scheduledAt: t2))

        table.cancel(.lockConfirm)
        XCTAssertFalse(table.matches(.lockConfirm, scheduledAt: t2))
        XCTAssertNil(table.earliest())
    }
}