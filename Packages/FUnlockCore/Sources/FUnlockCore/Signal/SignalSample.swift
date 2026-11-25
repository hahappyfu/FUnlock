// SignalSample.swift
// 信号采样点领域模型（自 SignalDataStore.swift 迁入纯逻辑包）

import Foundation

/// 采样点附带的状态跳变事件（强类型，替代裸字符串比较）
public enum SignalSampleEvent: String, Codable, Sendable, Equatable {
    case unlocked
    case locked
    /// 设备信号丢失导致的锁定
    case lockedLost = "locked: lost"
}

/// 单个采样点
public struct SignalSample: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let rawRSSI: Double
    public let kalmanEstimate: Double
    public let effectiveRSSI: Double
    public let slope: Double
    public let isAnomalous: Bool
    public let event: SignalSampleEvent?

    public init(timestamp: Date, rawRSSI: Double, kalmanEstimate: Double,
                effectiveRSSI: Double, slope: Double, isAnomalous: Bool,
                event: SignalSampleEvent? = nil) {
        self.timestamp = timestamp
        self.rawRSSI = rawRSSI
        self.kalmanEstimate = kalmanEstimate
        self.effectiveRSSI = effectiveRSSI
        self.slope = slope
        self.isAnomalous = isAnomalous
        self.event = event
    }

    /// 是否为「解锁」侧事件（供 UI 选择图标/配色，避免视图层再比字符串）
    public var isUnlockEvent: Bool { event == .unlocked }
}