import Foundation
import Observation

/// CQRS 投影 A（状态栏与菜单超轻投影）：始终维护，只同步离散关键状态，不跟踪高频 RSSI 采样流。
@Observable
@MainActor
final class StatusProjection {
    static let shared = StatusProjection()

    private(set) var monitoredDeviceName: String? = nil
    private(set) var connected: Bool = false
    private(set) var screenState: ScreenState = .unlocked
    private(set) var isEnabled: Bool = true
    private(set) var keepAliveActive: Bool = false

    func sync(from manager: FUnManager) {
        if monitoredDeviceName != manager.monitoredDeviceName {
            monitoredDeviceName = manager.monitoredDeviceName
        }
        if connected != manager.connected {
            connected = manager.connected
        }
        if screenState != manager.state.screen {
            screenState = manager.state.screen
        }
        let enabled = ConfigStore.shared.bool(forKey: "enabled", default: true)
        if isEnabled != enabled {
            isEnabled = enabled
        }
        let ka = manager.l0EngineSnapshot.keepAliveActive
        if keepAliveActive != ka {
            keepAliveActive = ka
        }
    }
}
