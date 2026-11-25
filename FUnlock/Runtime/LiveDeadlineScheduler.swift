// LiveDeadlineScheduler.swift
// 单一底层调度器：用唯一一个 DispatchSourceTimer 跟踪 DeadlineTable 中最早到期的截止时间，
// 替代分散在 FUn / BLEScanner / BLEPeripheralHandler / Device 中的 6 处 RunLoop Timer。

import Foundation
import FUnlockCore

final class LiveDeadlineScheduler: @unchecked Sendable {
    private let lock = UnfairLock()
    private var table = DeadlineTable()
    private var timer: DispatchSourceTimer?
    private let queue: DispatchQueue
    private let nowProvider: @Sendable () -> Date
    private let onFire: @Sendable (DeadlineID, Date) -> Void

    init(
        queue: DispatchQueue = DispatchQueue(label: "com.funlock.scheduler", qos: .userInitiated),
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        onFire: @escaping @Sendable (DeadlineID, Date) -> Void
    ) {
        self.queue = queue
        self.nowProvider = nowProvider
        self.onFire = onFire
    }

    deinit {
        cancelAll()
    }

    func schedule(_ id: DeadlineID, at date: Date) {
        lock.withLock {
            table.set(id, at: date)
            rearmLocked()
        }
    }

    func scheduleAfter(_ id: DeadlineID, interval: TimeInterval) {
        let target = nowProvider().addingTimeInterval(max(0, interval))
        schedule(id, at: target)
    }

    func cancel(_ id: DeadlineID) {
        lock.withLock {
            guard table[id] != nil else { return }
            table.cancel(id)
            rearmLocked()
        }
    }

    func cancelWhere(_ predicate: (DeadlineID) -> Bool) {
        lock.withLock {
            var changed = false
            // 通过重置并重放保留项保持 DeadlineTable 封装边界
            var kept: [(DeadlineID, Date)] = []
            while let earliest = table.earliest() {
                table.cancel(earliest.id)
                if predicate(earliest.id) {
                    changed = true
                } else {
                    kept.append(earliest)
                }
            }
            for (id, date) in kept {
                table.set(id, at: date)
            }
            if changed {
                rearmLocked()
            }
        }
    }

    func cancelAll() {
        lock.withLock {
            table = DeadlineTable()
            timer?.cancel()
            timer = nil
        }
    }

    func isScheduled(_ id: DeadlineID) -> Bool {
        lock.withLock { table[id] != nil }
    }

    func scheduledDate(for id: DeadlineID) -> Date? {
        lock.withLock { table[id] }
    }

    // MARK: - 内部重装与派发

    private func rearmLocked() {
        timer?.cancel()
        timer = nil
        guard let earliest = table.earliest() else { return }

        let delay = max(0, earliest.date.timeIntervalSince(nowProvider()))
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + delay, leeway: .milliseconds(5))
        source.setEventHandler { [weak self] in
            self?.handleFire()
        }
        timer = source
        source.resume()
    }

    private func handleFire() {
        while true {
            let fired: (id: DeadlineID, date: Date)? = lock.withLock {
                let cutoff = nowProvider().addingTimeInterval(0.001)
                guard let earliest = table.earliest(), earliest.date <= cutoff else {
                    rearmLocked()
                    return nil
                }
                table.cancel(earliest.id)
                return earliest
            }
            guard let fired else { return }
            // 在锁外派发回调，允许回调重入 schedule/cancel 或获取 FUn.lock 而不会死锁
            onFire(fired.id, fired.date)
        }
    }
}
