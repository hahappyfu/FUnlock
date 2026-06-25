import Foundation
import CoreWLAN

class WiFiMonitor {
    static let shared = WiFiMonitor()

    var currentSSID: String? {
        guard let interface = CWWiFiClient.shared().interface(),
              let ssid = interface.ssid() else {
            return nil
        }
        return ssid
    }
}
