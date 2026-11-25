// DeadlineTable.swift
// 纯值截止时间表：替代散装 Timer，由运行时单一 LiveDeadlineScheduler 消费。
// 所有时间点由 EngineReducer 写入；调度器只读 earliest()，到期回送 .deadlineFired(id, scheduledAt)，
// Reducer 用 matches(_:scheduledAt:) 拒绝已被替换或取消的过期投递。

import Foundation

/// 截止时间标识：单实例监控级计时器 + 按设备维度展开的过期计时。
public enum DeadlineID: Hashable, Sendable {
    case activePoll
    case peripheralConnectTimeout
    case heartbeat
    case signalTimeout
    case lockConfirm
    case deferredLockRecheck
    case lockVerify
    case screenLockConfirm
    case screenUnlockConfirm
    case systemWakeReady
    case wakeRetry
    case unlockDelay
    case l1NativeCheck
    case intrudeCheck
    case keepAliveRenew
    case uiDiscoveryFlush
    case deviceExpiry(UUID)

    /// 单实例（监控级）截止时间，不含按设备维度展开的 .deviceExpiry。
    /// 固定顺序用于同刻到期的确定性仲裁。
    static let monitorCases: [DeadlineID] = [
        .activePoll,
        .peripheralConnectTimeout,
        .heartbeat,
        .signalTimeout,
        .lockConfirm,
        .deferredLockRecheck,
        .lockVerify,
        .screenLockConfirm,
        .screenUnlockConfirm,
        .systemWakeReady,
        .wakeRetry,
        .unlockDelay,
        .l1NativeCheck,
        .intrudeCheck,
        .keepAliveRenew,
        .uiDiscoveryFlush,
    ]

    var isDeviceExpiry: Bool {
        if case .deviceExpiry = self { return true }
        return false
    }

    var deviceSortKey: String {
        if case .deviceExpiry(let uuid) = self { return uuid.uuidString }
        return ""
    }
}

/// 截止时间表：值语义，可整体存入 EngineState。
public struct DeadlineTable: Equatable, Sendable {
    private var storage: [DeadlineID: Date] = [:]

    public init() {}

    public subscript(_ id: DeadlineID) -> Date? { storage[id] }

    public mutating func set(_ id: DeadlineID, at date: Date) {
        storage[id] = date
    }

    public mutating func cancel(_ id: DeadlineID) {
        storage.removeValue(forKey: id)
    }

    /// 取消全部监控级截止时间（解绑 / 停扫 / 重建监控等整机复位路径），保留按设备过期计时。
    public mutating func cancelMonitorDeadlines() {
        for id in DeadlineID.monitorCases {
            storage.removeValue(forKey: id)
        }
    }

    /// 取消全部设备过期计时（解绑 / 切换监控设备路径），保留监控级截止时间。
    public mutating func cancelAllDeviceExpiries() {
        storage = storage.filter { !$0.key.isDeviceExpiry }
    }

    /// 最早到期的截止时间；同刻到期按固定顺序取第一个，保证确定性。
    public func earliest() -> (id: DeadlineID, date: Date)? {
        var best: (id: DeadlineID, date: Date)?
        for id in DeadlineID.monitorCases {
            guard let date = storage[id] else { continue }
            if let current = best, current.date <= date { continue }
            best = (id, date)
        }
        // 设备过期按 (到期时间, UUID) 排序，取最早一个；比 best 更早才替换
        let deviceEntries = storage
            .filter { $0.key.isDeviceExpiry }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key.deviceSortKey < rhs.key.deviceSortKey
            }
        for entry in deviceEntries {
            if let current = best, current.date <= entry.value { continue }
            best = (entry.key, entry.value)
            break
        }
        return best
    }

    /// 到期投递有效性校验：存储值仍是调度时的时间戳才允许执行。
    public func matches(_ id: DeadlineID, scheduledAt: Date) -> Bool {
        storage[id] == scheduledAt
    }
}