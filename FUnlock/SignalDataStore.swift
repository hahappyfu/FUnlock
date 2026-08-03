// SignalDataStore.swift
// 信号采样数据仓库：环形缓冲 + Combine 节流驱动 UI

import Foundation
import Combine

/// 单个采样点
struct SignalSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let rawRSSI: Double
    let kalmanEstimate: Double
    let effectiveRSSI: Double
    let slope: Double
    let isAnomalous: Bool
    let event: String?   // "unlocked" / "locked" / nil
}

/// 全局信号数据仓库
final class SignalDataStore: ObservableObject {
    static let shared = SignalDataStore()

    /// 底层环形缓冲（高频写入，不触发 UI）
    private var ring = RingBuffer<SignalSample>(capacity: 300)

    /// 互斥锁：保护 ring 的跨线程访问（BLE 回调线程写、主线程 Timer 读）
    private let lock = NSLock()

    /// 节流后暴露给 UI 的快照（~1 秒刷新一次）
    @Published private(set) var samples: [SignalSample] = []

    private var cancellable: AnyCancellable?
    private let uiThrottle: TimeInterval = 1.0

    /// 阈值参考线数据（由 FUn 设置后保持不变）
    @Published var unlockThreshold: Double = -60
    @Published var lockThreshold: Double = -80

    private init() {
        // 底层 ring 变化 → 节流 → 批量更新 samples
        // 用 Timer 驱动而非 subject，因为 ring 是被动写入的
        cancellable = Timer.publish(every: uiThrottle, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.lock.lock()
                let snapshot = self.ring.toArray()
                self.lock.unlock()
                if snapshot.count != self.samples.count ||
                    snapshot.last?.id != self.samples.last?.id {
                    self.samples = snapshot
                }
            }
    }

    // MARK: - 写入接口（BLE 线程安全）

    /// 记录信号采样（在 BLE 回调中调用，线程安全）
    func record(rawRSSI: Double, kalmanEstimate: Double,
                effectiveRSSI: Double, slope: Double,
                isAnomalous: Bool, event: String? = nil) {
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
        samples = []
    }
}
