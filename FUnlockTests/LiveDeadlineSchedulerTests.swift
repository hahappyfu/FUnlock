import XCTest
@testable import FUnlock

private final class LockedRecorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ initial: T) {
        self.storage = initial
    }

    func withValue<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }

    var value: T {
        withValue { $0 }
    }
}

final class LiveDeadlineSchedulerTests: XCTestCase {
    func testFiresInChronologicalOrderAndIgnoresCancelledDeadline() {
        let exp = expectation(description: "ordered deadlines")
        exp.expectedFulfillmentCount = 2
        let fired = LockedRecorder<[DeadlineID]>([])

        let scheduler = LiveDeadlineScheduler { id, _ in
            fired.withValue { $0.append(id) }
            exp.fulfill()
        }
        let now = Date()
        scheduler.schedule(.heartbeat, at: now.addingTimeInterval(0.12))
        scheduler.schedule(.lockConfirm, at: now.addingTimeInterval(0.04))
        scheduler.schedule(.signalTimeout, at: now.addingTimeInterval(0.08))
        scheduler.cancel(.signalTimeout)

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(fired.value, [.lockConfirm, .heartbeat])
        scheduler.cancelAll()
    }

    func testReschedulingSameDeadlineReplacesEarlierFireTime() {
        let exp = expectation(description: "rescheduled deadline")
        let firedTimes = LockedRecorder<[Date]>([])
        let t0 = Date()

        let scheduler = LiveDeadlineScheduler { id, scheduledAt in
            guard id == .lockConfirm else { return }
            firedTimes.withValue { $0.append(scheduledAt) }
            exp.fulfill()
        }
        scheduler.schedule(.lockConfirm, at: t0.addingTimeInterval(0.03))
        let replacement = t0.addingTimeInterval(0.12)
        scheduler.schedule(.lockConfirm, at: replacement)

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(firedTimes.value, [replacement])
        scheduler.cancelAll()
    }

    func testCancelAllPreventsAnyPendingDeadlinesFromFiring() {
        let count = LockedRecorder(0)
        let scheduler = LiveDeadlineScheduler { _, _ in
            count.withValue { $0 += 1 }
        }
        scheduler.scheduleAfter(.heartbeat, interval: 0.05)
        scheduler.scheduleAfter(.signalTimeout, interval: 0.08)
        scheduler.cancelAll()

        let settle = expectation(description: "wait past cancelled intervals")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { settle.fulfill() }
        wait(for: [settle], timeout: 1.0)
        XCTAssertEqual(count.value, 0)
    }
}
