import SwiftUI

@available(macOS 10.15, *)
struct SettingsView: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("BLEUnlock Settings")
                .font(.headline)

            Toggle("Enabled", isOn: $settings.enabled)
            Toggle("Wake on Proximity", isOn: $settings.wakeOnProximity)
            Toggle("Wake without Unlocking", isOn: $settings.wakeWithoutUnlocking)
            Toggle("Pause Now Playing", isOn: $settings.pauseNowPlaying)
            Toggle("Use Screensaver to Lock", isOn: $settings.useScreensaver)
            Toggle("Turn Off Screen on Lock", isOn: $settings.sleepDisplay)
            Toggle("Passive Mode", isOn: $settings.passiveMode)
            Toggle("Launch at Login", isOn: $settings.launchAtLogin)

            Divider()

            HStack {
                Text("Lock RSSI:")
                Picker("", selection: $settings.lockRSSI) {
                    Text("Disabled").tag(-100)
                    ForEach(Array(stride(from: -30, through: -95, by: -5)), id: \.self) { val in
                        Text("\(val) dBm").tag(val)
                    }
                }
            }

            HStack {
                Text("Unlock RSSI:")
                Picker("", selection: $settings.unlockRSSI) {
                    Text("Disabled").tag(1)
                    ForEach(Array(stride(from: -30, through: -95, by: -5)), id: \.self) { val in
                        Text("\(val) dBm").tag(val)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

@available(macOS 10.15, *)
class SettingsModel: ObservableObject {
    private let prefs = UserDefaults.standard
    private let ble: BLE

    init(ble: BLE) {
        self.ble = ble
        _enabled = Published(initialValue: prefs.bool(forKey: "enabled"))
        _wakeOnProximity = Published(initialValue: prefs.bool(forKey: "wakeOnProximity"))
        _wakeWithoutUnlocking = Published(initialValue: prefs.bool(forKey: "wakeWithoutUnlocking"))
        _pauseNowPlaying = Published(initialValue: prefs.bool(forKey: "pauseItunes"))
        _useScreensaver = Published(initialValue: prefs.bool(forKey: "screensaver"))
        _sleepDisplay = Published(initialValue: prefs.bool(forKey: "sleepDisplay"))
        _passiveMode = Published(initialValue: prefs.bool(forKey: "passiveMode"))
        _launchAtLogin = Published(initialValue: prefs.bool(forKey: "launchAtLogin"))
        _lockRSSI = Published(initialValue: ble.lockRSSI)
        _unlockRSSI = Published(initialValue: ble.unlockRSSI)
    }

    @Published var enabled: Bool { didSet { prefs.set(enabled, forKey: "enabled") } }
    @Published var wakeOnProximity: Bool { didSet { prefs.set(wakeOnProximity, forKey: "wakeOnProximity") } }
    @Published var wakeWithoutUnlocking: Bool { didSet { prefs.set(wakeWithoutUnlocking, forKey: "wakeWithoutUnlocking") } }
    @Published var pauseNowPlaying: Bool { didSet { prefs.set(pauseNowPlaying, forKey: "pauseItunes") } }
    @Published var useScreensaver: Bool { didSet { prefs.set(useScreensaver, forKey: "screensaver") } }
    @Published var sleepDisplay: Bool { didSet { prefs.set(sleepDisplay, forKey: "sleepDisplay") } }
    @Published var passiveMode: Bool { didSet { prefs.set(passiveMode, forKey: "passiveMode"); ble.setPassiveMode(passiveMode) } }
    @Published var launchAtLogin: Bool { didSet { prefs.set(launchAtLogin, forKey: "launchAtLogin") } }
    @Published var lockRSSI: Int { didSet { prefs.set(lockRSSI, forKey: "lockRSSI"); ble.lockRSSI = lockRSSI } }
    @Published var unlockRSSI: Int { didSet { prefs.set(unlockRSSI, forKey: "unlockRSSI"); ble.unlockRSSI = unlockRSSI } }
}
