// FUnlock/WiFiMonitor.swift
import Foundation
import CoreWLAN
import CoreLocation

/// Wi-Fi SSID 读取与定位授权管理。
/// 标注 @MainActor：locationManager 在主线程创建（CoreLocation 期望的线程），
/// `pendingCompletions` 与代理回调状态统一受主线程隔离保护，避免 CoreLocation 回调线程与主线程竞态。
@MainActor
class WiFiMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = WiFiMonitor()

    /// 触发系统定位授权弹窗的持有实例（macOS 14+ 读 SSID 依赖定位权限，不持有会被释放）
    private let locationManager = CLLocationManager()

    override private init() {
        super.init()
        locationManager.delegate = self
    }

    var currentSSID: String? {
        guard let interface = CWWiFiClient.shared().interface() else {
            throttledLog("CWWiFiClient has no interface (Wi-Fi off or not associated)")
            return nil
        }
        guard let ssid = interface.ssid() else {
            throttledLog("interface.ssid() returned nil (check location permission or association)")
            return nil
        }
        return ssid
    }

    /// SSID 读取失败诊断：60 秒限频，避免每秒轮询刷屏（区分 Wi-Fi 未关联与定位权限缺失）
    private var lastLogTime: TimeInterval = 0

    private func throttledLog(_ msg: String) {
        let now = Date().timeIntervalSince1970
        if now - lastLogTime >= 60 {
            lastLogTime = now
            Log.sm.debug("[WiFiMonitor] \(msg, privacy: .public)")
        }
    }

    /// 当前定位授权状态（denied / notDetermined 时 UI 给出提示）
    var authorizationStatus: CLAuthorizationStatus { locationManager.authorizationStatus }

    /// 请求定位权限：已授权直接回调；未决弹系统窗；被拒回调 false（由 UI 引导去系统设置）。
    /// completion 在主线程回调，参数为是否已授权。
    @MainActor func requestLocationIfNeeded(completion: @escaping (Bool) -> Void) {
        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            completion(true)
        case .notDetermined:
            pendingCompletions.append(completion)
            locationManager.requestWhenInUseAuthorization()
        default:
            completion(false)
        }
    }

    private var pendingCompletions: [(Bool) -> Void] = []

    /// CLLocationManagerDelegate 回调不保证在主线程到达（协议为 nonisolated，回调线程由 CoreLocation 决定）：
    /// 读取授权状态后统一收敛到主线程修改 `pendingCompletions` 并派发回调，
    /// 与 `requestLocationIfNeeded` 对同一数组的读写在 @MainActor 上串行。
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let granted = manager.authorizationStatus == .authorizedAlways
        Task { @MainActor in
            let callbacks = self.pendingCompletions
            self.pendingCompletions = []
            callbacks.forEach { $0(granted) }
        }
    }
}
