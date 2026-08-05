import Foundation

func t(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

/// 按设备名推断设备图标（Apple Watch / AirPods / iPad / Mac / iPhone 等）
func deviceIconName(for deviceName: String) -> String {
    if deviceName.contains("Watch") { return "applewatch" }
    if deviceName.contains("AirPods") { return "airpods" }
    if deviceName.contains("iPad") { return "ipad" }
    if deviceName.contains("MacBook") || deviceName.contains("Mac") { return "laptopcomputer" }
    if deviceName.contains("iPhone") { return "iphone" }
    return "iphone"
}
