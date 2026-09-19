// FUnlock/WiFiMonitor.swift
import Foundation
import CoreWLAN
import CoreLocation

class WiFiMonitor: NSObject, CLLocationManagerDelegate {
    static let shared = WiFiMonitor()

    /// 触发系统定位授权弹窗的持有实例（macOS 14+ 读 SSID 依赖定位权限，不持有会被释放）
    private let locationManager = CLLocationManager()

    override private init() {
        super.init()
        locationManager.delegate = self
    }

    var currentSSID: String? {
        guard let interface = CWWiFiClient.shared().interface(),
              let ssid = interface.ssid() else {
            return nil
        }
        return ssid
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

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let granted = manager.authorizationStatus == .authorizedAlways
        let callbacks = pendingCompletions
        pendingCompletions = []
        Task { @MainActor in callbacks.forEach { $0(granted) } }
    }
}
