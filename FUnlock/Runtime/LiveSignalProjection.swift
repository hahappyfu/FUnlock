import Foundation
import Observation

/// CQRS 投影 B（实时信号按需投影）：仅在设置窗口或状态栏弹窗可见时更新可观察信号属性，
/// 窗口不可见时抑制高频 RSSI 触发 SwiftUI Observation 重绘，实现后台零渲染开销。
@Observable
@MainActor
final class LiveSignalProjection {
    static let shared = LiveSignalProjection()

    private(set) var isVisible: Bool = false
    private(set) var rssi: Int? = nil
    private(set) var smoothedRSSI: Double? = nil
    private(set) var samples: [SignalSample] = []

    func setVisible(
        _ visible: Bool,
        store: SignalDataStore = .shared,
        currentRSSI: Int? = nil,
        smoothedRSSI: Double? = nil
    ) {
        isVisible = visible
        if visible {
            if let currentRSSI { self.rssi = currentRSSI }
            if let smoothedRSSI { self.smoothedRSSI = smoothedRSSI }
            self.samples = store.snapshot()
        } else {
            self.samples = []
        }
    }

    func ingestRSSI(_ raw: Int?, smoothed: Double?, store: SignalDataStore? = nil) {
        guard isVisible else { return }
        if self.rssi != raw { self.rssi = raw }
        if self.smoothedRSSI != smoothed { self.smoothedRSSI = smoothed }
        if let store {
            self.samples = store.snapshot()
        }
    }
}
