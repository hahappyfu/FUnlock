// SignalDataStore.swift
// 信号采样数据仓库：环形缓冲 + Combine 节流喂给 @Observable 快照属性，驱动 UI

import Foundation
import Combine
import Observation

/// 采样点附带的状态跳变事件（强类型，替代裸字符串比较）
enum SignalSampleEvent: String, Codable, Sendable, Equatable {
    case unlocked
    case locked
    /// 设备信号丢失导致的锁定
    case lockedLost = "locked: lost"
}

/// 单个采样点
struct SignalSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let rawRSSI: Double
    let kalmanEstimate: Double
    let effectiveRSSI: Double
    let slope: Double
    let isAnomalous: Bool
    let event: SignalSampleEvent?

    /// 是否为「解锁」侧事件（供 UI 选择图标/配色，避免视图层再比字符串）
    var isUnlockEvent: Bool { event == .unlocked }
}

/// 全局信号数据仓库
/// @unchecked Sendable 依据：ring 由 NSLock 保护，@Observable 跟踪属性仅主线程读写
@Observable
final class SignalDataStore: @unchecked Sendable {
    static let shared = SignalDataStore()

    /// 底层环形缓冲（高频写入，不触发 UI）；600 在 0.5s 快轮询档覆盖 5 分钟
    @ObservationIgnored
    private var ring = RingBuffer<SignalSample>(capacity: 600)

    /// 互斥锁：保护 ring 的跨线程访问（BLE 回调线程写、主线程 Timer 读）
    @ObservationIgnored
    private let lock = NSLock()

    /// 节流后暴露给 UI 的快照（~1 秒刷新一次）
    private(set) var samples: [SignalSample] = []

    @ObservationIgnored
    private var cancellable: AnyCancellable?
    @ObservationIgnored
    private let uiThrottle: TimeInterval = 1.0

    /// 环形缓冲写入计数（record/clear 各自增），供 UI Timer 判定「本 tick 是否有新数据」：
    /// 值未变则跳过对最多 600 个 SignalSample（每个含 UUID）的全量 ring.toArray() 拷贝，
    /// 设备离场/无采样的空闲期每秒 tick 近乎零开销。由 lock 保护，与 ring 同生命周期。
    @ObservationIgnored
    private var mutationCount: Int = 0
    @ObservationIgnored
    private var lastAppliedMutation: Int = 0

    /// 图表阈值参考线：实时读用户当前设置，与「设置」页调整后保持同步。
    /// 命中禁用哨兵（解锁关闭 / 不单独设锁定阈值）时回退到展示默认值，
    /// 避免参考线画到 1 dBm 或 -100 dBm 这类图表外的位置。
    /// 计算属性不进入 Observation 追踪，随 samples 的秒级刷新自然更新。
    var unlockThreshold: Double {
        let value = ConfigStore.shared.get("unlockRSSI", fallback: -60)
        return value == FUn.UNLOCK_DISABLED ? -60 : Double(value)
    }
    var lockThreshold: Double {
        let value = ConfigStore.shared.get("lockRSSI", fallback: -80)
        return value == SignalHysteresisEngine.lockDisabled ? -80 : Double(value)
    }

    private init() {
        // 底层 ring 变化 → 节流 → 批量更新 samples
        // 用 Timer 驱动而非 subject，因为 ring 是被动写入的
        cancellable = Timer.publish(every: uiThrottle, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.lock.lock()
                // 空闲跳帧：本 tick 无 record/clear 写入则直接返回，省掉全量 ring.toArray() 拷贝
                guard self.mutationCount != self.lastAppliedMutation else {
                    self.lock.unlock()
                    return
                }
                self.lastAppliedMutation = self.mutationCount
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
        mutationCount += 1
        lock.unlock()
    }

    /// 清空所有数据（UI 快照更新在主线程执行）
    @MainActor
    func clear() {
        lock.lock()
        ring.clear()
        mutationCount += 1
        lock.unlock()
        samples = []
    }
}
