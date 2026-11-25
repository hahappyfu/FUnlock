// SignalDataStore.swift
// 信号采样数据仓库：线程安全环形缓冲（零后台 Timer；按需 snapshot() 供可见视图的 TimelineView 拉取）

import Foundation

/// 全局信号数据仓库（CQRS 写侧缓冲：后台只追加 RingBuffer，不派发 UI 定时器）
/// @unchecked Sendable 依据：ring 仅在 NSLock 保护下读写
final class SignalDataStore: @unchecked Sendable {
    static let shared = SignalDataStore()

    /// 底层环形缓冲（高频写入，不触发 UI）；600 在 0.5s 快轮询档覆盖 5 分钟
    private var ring = RingBuffer<SignalSample>(capacity: 600)

    /// 互斥锁：保护 ring 的跨线程访问（BLE 回调线程写、主线程按需读）
    private let lock = NSLock()

    /// 图表阈值参考线：实时读用户当前设置，与「设置」页调整后保持同步。
    /// 命中禁用哨兵（解锁关闭 / 不单独设锁定阈值）时回退到展示默认值。
    var unlockThreshold: Double {
        let value = ConfigStore.shared.get("unlockRSSI", fallback: -60)
        return value == FUn.UNLOCK_DISABLED ? -60 : Double(value)
    }
    var lockThreshold: Double {
        let value = ConfigStore.shared.get("lockRSSI", fallback: -80)
        return value == SignalHysteresisEngine.lockDisabled ? -80 : Double(value)
    }

    private init() {}

    /// 按需读取当前样本快照（供可见视图 TimelineView 或测试调用）
    func snapshot() -> [SignalSample] {
        lock.lock()
        defer { lock.unlock() }
        return ring.toArray()
    }

    /// 兼容既有调用点的只读快照属性
    var samples: [SignalSample] {
        snapshot()
    }

    // MARK: - 写入接口（BLE 线程安全）

    /// 记录信号采样（在 BLE 回调中调用，线程安全）
    func record(rawRSSI: Double, kalmanEstimate: Double,
                effectiveRSSI: Double, slope: Double,
                isAnomalous: Bool, event: SignalSampleEvent? = nil) {
        let sample = SignalSample(
            timestamp: Date(),
            rawRSSI: rawRSSI,
            kalmanEstimate: kalmanEstimate,
            effectiveRSSI: effectiveRSSI,
            slope: slope,
            isAnomalous: isAnomalous,
            event: event
        )
        lock.lock()
        ring.append(sample)
        lock.unlock()
    }

    /// 清空所有数据
    func clear() {
        lock.lock()
        ring.clear()
        lock.unlock()
    }
}
