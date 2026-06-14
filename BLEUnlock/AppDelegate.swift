// AppDelegate.swift — 纯 View Controller
// 职责：UI 菜单 + 转发系统通知给 BluetoothManager

import Cocoa
import Quartz
import ServiceManagement
import UserNotifications
import SwiftUI
import Combine

func t(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

@MainActor
@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, UNUserNotificationCenterDelegate, BLEDelegate {

    // MARK: - UI 组件

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let mainMenu = NSMenu()
    let deviceMenu = NSMenu()
    let lockRSSIMenu = NSMenu()
    let unlockRSSIMenu = NSMenu()
    let timeoutMenu = NSMenu()
    let lockDelayMenu = NSMenu()
    var deviceDict: [UUID: NSMenuItem] = [:]
    var monitorMenuItem: NSMenuItem?
    var aboutBox: AboutBox? = nil
    var settingsWindow: NSWindow?

    // MARK: - 核心依赖

    let ble = BLE()
    var manager: BluetoothManager!
    let prefs = UserDefaults.standard
    var cancellables = Set<AnyCancellable>()

    // MARK: - 菜单代理

    func menuWillOpen(_ menu: NSMenu) {
        if menu == deviceMenu {
            ble.startScanning()
        } else if menu == lockRSSIMenu {
            for item in menu.items {
                item.state = (item.tag == ble.lockRSSI) ? .on : .off
            }
        } else if menu == unlockRSSIMenu {
            for item in menu.items {
                item.state = (item.tag == ble.unlockRSSI) ? .on : .off
            }
        } else if menu == timeoutMenu {
            for item in menu.items {
                item.state = (item.tag == Int(ble.signalTimeout)) ? .on : .off
            }
        } else if menu == lockDelayMenu {
            for item in menu.items {
                item.state = (item.tag == Int(ble.proximityTimeout)) ? .on : .off
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.menu == lockRSSIMenu {
            return menuItem.tag <= ble.unlockRSSI
        } else if menuItem.menu == unlockRSSIMenu {
            return menuItem.tag >= ble.lockRSSI
        }
        return true
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu == deviceMenu { ble.stopScanning() }
    }

    // MARK: - BLEDelegate（纯 UI 更新）

    func menuItemTitle(device: Device) -> String {
        var desc: String!
        if let mac = device.macAddr {
            let prettifiedMac = mac.replacingOccurrences(of: "-", with: ":").uppercased()
            desc = String(format: "%@ (%@)", device.description, prettifiedMac)
        } else {
            desc = device.description
        }
        return String(format: "%@ (%ddBm)", desc, device.rssi)
    }

    func newDevice(device: Device) {
        let menuItem = deviceMenu.addItem(withTitle: menuItemTitle(device: device), action: #selector(selectDevice), keyEquivalent: "")
        deviceDict[device.uuid] = menuItem
        if device.uuid == ble.monitoredUUID { menuItem.state = .on }
    }

    func updateDevice(device: Device) {
        deviceDict[device.uuid]?.title = menuItemTitle(device: device)
    }

    func removeDevice(device: Device) {
        deviceDict[device.uuid]?.menu?.removeItem(deviceDict[device.uuid]!)
        deviceDict.removeValue(forKey: device.uuid)
    }

    func updateRSSI(rssi: Int?, active: Bool) {
        manager.onRSSIUpdated(rssi: rssi, active: active)
        if let r = rssi {
            monitorMenuItem?.title = String(format: "%ddBm", r) + (active ? " (Active)" : "")
            if !manager.connected {
                manager.updateConnected(true)
                statusItem.button?.image = NSImage(named: "StatusBarConnected")
            }
        } else {
            monitorMenuItem?.title = t("not_detected")
            if manager.connected {
                manager.updateConnected(false)
                statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
            }
        }
    }

    func updatePresence(presence: Bool, reason: String) {
        if presence {
            manager.onDeviceApproached()
        } else {
            manager.onDeviceLeft(reason: reason)
        }
    }

    func bluetoothPowerWarn() {
        manager.errorModal(t("bluetooth_power_warn"))
    }

    // MARK: - UNUserNotificationCenter

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) -> UNNotificationPresentationOptions {
        return [.alert, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // 非锁屏通知（如更新通知）→ 打开 releases 页面
        NSWorkspace.shared.open(URL(string: "https://gitee.com/fuhahah/bleunlock/releases")!)
    }

    // MARK: - 菜单构建

    @objc func selectDevice(item: NSMenuItem) {
        for (uuid, menuItem) in deviceDict {
            if menuItem == item {
                if menuItem.state == .on {
                    menuItem.state = .off
                    ble.removeMonitoredDevice(uuid: uuid)
                } else {
                    menuItem.state = .on
                    if ble.monitoredUUID == nil {
                        connected = false
                        statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
                        monitorMenuItem?.title = t("not_detected")
                        ble.startMonitor(uuid: uuid)
                    }
                    ble.addMonitoredDevice(uuid: uuid)
                    prefs.set(uuid.uuidString, forKey: "device")
                }
            }
        }
    }

    var connected: Bool = false

    @objc func lockNow() { manager.lockNow() }
    @objc func askPassword() { manager.askPassword() }
    @objc func showAboutBox() { AboutBox.showAboutBox() }

    @objc func showSettings() {
        if #available(macOS 10.15, *) {
            if settingsWindow == nil {
                let model = SettingsModel(ble: ble)
                let view = SettingsView(settings: model)
                let vc = NSHostingController(rootView: view)
                let window = NSWindow(contentViewController: vc)
                window.title = "BLEUnlock Settings"
                window.styleMask = [.titled, .closable]
                window.setContentSize(NSSize(width: 360, height: 400))
                settingsWindow = window
            }
            settingsWindow?.center()
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func setLockRSSI(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        if value == ble.LOCK_DISABLED && ble.unlockRSSI == ble.UNLOCK_DISABLED {
            ble.unlockRSSI = -60; prefs.set(-60, forKey: "unlockRSSI")
        }
        prefs.set(value, forKey: "lockRSSI"); ble.lockRSSI = value
    }

    @objc func setUnlockRSSI(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        if value == ble.UNLOCK_DISABLED && ble.lockRSSI == ble.LOCK_DISABLED {
            ble.lockRSSI = -80; prefs.set(-80, forKey: "lockRSSI")
        }
        prefs.set(value, forKey: "unlockRSSI"); ble.unlockRSSI = value
    }

    @objc func setTimeout(_ menuItem: NSMenuItem) {
        prefs.set(menuItem.tag, forKey: "timeout"); ble.signalTimeout = Double(menuItem.tag)
    }

    @objc func setLockDelay(_ menuItem: NSMenuItem) {
        prefs.set(menuItem.tag, forKey: "lockDelay"); ble.proximityTimeout = Double(menuItem.tag)
    }

    @objc func toggleWakeOnProximity(_ item: NSMenuItem) {
        let v = !prefs.bool(forKey: "wakeOnProximity"); item.state = v ? .on : .off; prefs.set(v, forKey: "wakeOnProximity")
    }
    @objc func toggleWakeWithoutUnlocking(_ item: NSMenuItem) {
        let v = !prefs.bool(forKey: "wakeWithoutUnlocking"); item.state = v ? .on : .off; prefs.set(v, forKey: "wakeWithoutUnlocking")
    }
    @objc func togglePauseNowPlaying(_ item: NSMenuItem) {
        let v = !prefs.bool(forKey: "pauseItunes"); item.state = v ? .on : .off; prefs.set(v, forKey: "pauseItunes")
    }
    @objc func toggleUseScreensaver(_ item: NSMenuItem) {
        let v = !prefs.bool(forKey: "screensaver"); item.state = v ? .on : .off; prefs.set(v, forKey: "screensaver")
    }
    @objc func toggleSleepDisplay(_ item: NSMenuItem) {
        let v = !prefs.bool(forKey: "sleepDisplay"); item.state = v ? .on : .off; prefs.set(v, forKey: "sleepDisplay")
    }
    @objc func togglePassiveMode(_ item: NSMenuItem) {
        let v = !prefs.bool(forKey: "passiveMode"); item.state = v ? .on : .off; prefs.set(v, forKey: "passiveMode"); ble.setPassiveMode(v)
    }
    @objc func toggleLaunchAtLogin(_ item: NSMenuItem) {
        let v = !prefs.bool(forKey: "launchAtLogin"); item.state = v ? .on : .off; prefs.set(v, forKey: "launchAtLogin")
        SMLoginItemSetEnabled(Bundle.main.bundleIdentifier! + ".Launcher" as CFString, v)
    }
    @objc func toggleEnabled(_ item: NSMenuItem) {
        let v = !prefs.bool(forKey: "enabled"); item.state = v ? .on : .off; prefs.set(v, forKey: "enabled")
        if !v { ble.stopScanning() }
    }

    @objc func setRSSIThreshold() {
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("enter_rssi_threshold")
        msg.informativeText = t("enter_rssi_threshold_info")
        msg.window.title = "BLEUnlock"
        let txt = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        txt.placeholderString = String(ble.thresholdRSSI)
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        let response = msg.runModal()
        if response == .alertFirstButtonReturn {
            ble.thresholdRSSI = Int(txt.intValue)
            prefs.set(txt.intValue, forKey: "thresholdRSSI")
        }
    }

    func constructRSSIMenu(_ menu: NSMenu, _ action: Selector) {
        menu.addItem(withTitle: t("closer"), action: nil, keyEquivalent: "")
        for proximity in stride(from: -30, to: -100, by: -5) {
            let item = menu.addItem(withTitle: String(format: "%ddBm", proximity), action: action, keyEquivalent: "")
            item.tag = proximity
        }
        menu.addItem(withTitle: t("farther"), action: nil, keyEquivalent: "")
        menu.delegate = self
    }

    func constructMenu() {
        var item: NSMenuItem
        item = mainMenu.addItem(withTitle: t("enabled"), action: #selector(toggleEnabled), keyEquivalent: "")
        item.state = prefs.bool(forKey: "enabled") ? .on : .off
        mainMenu.addItem(NSMenuItem.separator())

        monitorMenuItem = mainMenu.addItem(withTitle: t("device_not_set"), action: nil, keyEquivalent: "")
        mainMenu.addItem(withTitle: t("lock_now"), action: #selector(lockNow), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())

        item = mainMenu.addItem(withTitle: t("device"), action: nil, keyEquivalent: "")
        item.submenu = deviceMenu; deviceMenu.delegate = self
        deviceMenu.addItem(withTitle: t("scanning"), action: nil, keyEquivalent: "")

        let unlockRSSIItem = mainMenu.addItem(withTitle: t("unlock_rssi"), action: nil, keyEquivalent: "")
        unlockRSSIItem.submenu = unlockRSSIMenu
        item = unlockRSSIMenu.addItem(withTitle: t("disabled"), action: #selector(setUnlockRSSI), keyEquivalent: ""); item.tag = ble.UNLOCK_DISABLED
        constructRSSIMenu(unlockRSSIMenu, #selector(setUnlockRSSI))

        let lockRSSIItem = mainMenu.addItem(withTitle: t("lock_rssi"), action: nil, keyEquivalent: "")
        lockRSSIItem.submenu = lockRSSIMenu
        constructRSSIMenu(lockRSSIMenu, #selector(setLockRSSI))
        item = lockRSSIMenu.addItem(withTitle: t("disabled"), action: #selector(setLockRSSI), keyEquivalent: ""); item.tag = ble.LOCK_DISABLED

        let lockDelayItem = mainMenu.addItem(withTitle: t("lock_delay"), action: nil, keyEquivalent: "")
        lockDelayItem.submenu = lockDelayMenu
        lockDelayMenu.addItem(withTitle: "2 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 2
        lockDelayMenu.addItem(withTitle: "5 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 5
        lockDelayMenu.addItem(withTitle: "15 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 15
        lockDelayMenu.addItem(withTitle: "30 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 30
        lockDelayMenu.addItem(withTitle: "1 " + t("minute"), action: #selector(setLockDelay), keyEquivalent: "").tag = 60
        lockDelayMenu.addItem(withTitle: "2 " + t("minutes"), action: #selector(setLockDelay), keyEquivalent: "").tag = 120
        lockDelayMenu.addItem(withTitle: "5 " + t("minutes"), action: #selector(setLockDelay), keyEquivalent: "").tag = 300
        lockDelayMenu.delegate = self

        let timeoutItem = mainMenu.addItem(withTitle: t("timeout"), action: nil, keyEquivalent: "")
        timeoutItem.submenu = timeoutMenu
        timeoutMenu.addItem(withTitle: "30 " + t("seconds"), action: #selector(setTimeout), keyEquivalent: "").tag = 30
        timeoutMenu.addItem(withTitle: "1 " + t("minute"), action: #selector(setTimeout), keyEquivalent: "").tag = 60
        timeoutMenu.addItem(withTitle: "2 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 120
        timeoutMenu.addItem(withTitle: "5 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 300
        timeoutMenu.addItem(withTitle: "10 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 600
        timeoutMenu.delegate = self

        item = mainMenu.addItem(withTitle: t("wake_on_proximity"), action: #selector(toggleWakeOnProximity), keyEquivalent: "")
        item.state = prefs.bool(forKey: "wakeOnProximity") ? .on : .off

        item = mainMenu.addItem(withTitle: t("wake_without_unlocking"), action: #selector(toggleWakeWithoutUnlocking), keyEquivalent: "")
        item.state = prefs.bool(forKey: "wakeWithoutUnlocking") ? .on : .off

        item = mainMenu.addItem(withTitle: t("pause_now_playing"), action: #selector(togglePauseNowPlaying), keyEquivalent: "")
        item.state = prefs.bool(forKey: "pauseItunes") ? .on : .off

        item = mainMenu.addItem(withTitle: t("use_screensaver_to_lock"), action: #selector(toggleUseScreensaver), keyEquivalent: "")
        item.state = prefs.bool(forKey: "screensaver") ? .on : .off

        item = mainMenu.addItem(withTitle: t("sleep_display"), action: #selector(toggleSleepDisplay), keyEquivalent: "")
        item.state = prefs.bool(forKey: "sleepDisplay") ? .on : .off

        mainMenu.addItem(withTitle: t("set_password"), action: #selector(askPassword), keyEquivalent: "")

        item = mainMenu.addItem(withTitle: t("passive_mode"), action: #selector(togglePassiveMode), keyEquivalent: "")
        item.state = prefs.bool(forKey: "passiveMode") ? .on : .off

        item = mainMenu.addItem(withTitle: t("launch_at_login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.state = prefs.bool(forKey: "launchAtLogin") ? .on : .off

        mainMenu.addItem(withTitle: t("set_rssi_threshold"), action: #selector(setRSSIThreshold), keyEquivalent: "")

        mainMenu.addItem(NSMenuItem.separator())
        if #available(macOS 10.15, *) {
            mainMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        }
        mainMenu.addItem(withTitle: t("about"), action: #selector(showAboutBox), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = mainMenu
    }

    // MARK: - Accessibility

    func checkAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        if !AXIsProcessTrustedWithOptions([key: true] as CFDictionary) {
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 63, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        manager = BluetoothManager(ble: ble)
        if let button = statusItem.button {
            button.image = NSImage(named: "StatusBarDisconnected")
            constructMenu()
        }

        ble.delegate = self

        if let str = prefs.string(forKey: "device"), let uuid = UUID(uuidString: str) {
            connected = false
            statusItem.button?.image = NSImage(named: "StatusBarDisconnected")
            monitorMenuItem?.title = t("not_detected")
            ble.startMonitor(uuid: uuid)
        }

        let lockRSSI = prefs.integer(forKey: "lockRSSI"); if lockRSSI != 0 { ble.lockRSSI = lockRSSI }
        let unlockRSSI = prefs.integer(forKey: "unlockRSSI"); if unlockRSSI != 0 { ble.unlockRSSI = unlockRSSI }
        let timeout = prefs.integer(forKey: "timeout"); if timeout != 0 { ble.signalTimeout = Double(timeout) }
        ble.setPassiveMode(prefs.bool(forKey: "passiveMode"))
        let thresholdRSSI = prefs.integer(forKey: "thresholdRSSI"); if thresholdRSSI != 0 { ble.thresholdRSSI = thresholdRSSI }
        let lockDelay = prefs.integer(forKey: "lockDelay"); if lockDelay != 0 { ble.proximityTimeout = Double(lockDelay) }

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // 转发系统通知 → BluetoothManager
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.manager.onDisplaySleep() }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.manager.onDisplayWake() }
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.manager.onSystemSleep() }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.manager.onSystemWake() }

        let dnc = DistributedNotificationCenter.default
        dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.manager.onUnlock() }
        dnc.addObserver(forName: NSNotification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in self?.manager.onScreensaverStart() }
        dnc.addObserver(forName: NSNotification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in self?.manager.onScreensaverStop() }

        if !prefs.bool(forKey: "hasShownGuide") {
            prefs.set(true, forKey: "enabled")
            showFirstLaunchGuide()
        }

        if ble.unlockRSSI != ble.UNLOCK_DISABLED && !prefs.bool(forKey: "wakeWithoutUnlocking") && manager.fetchPassword() == nil {
            manager.askPassword()
        }

        checkAccessibility()
        BLEUnlock.checkUpdate()

        NSApp.setActivationPolicy(.accessory)
    }

    func showFirstLaunchGuide() {
        let alert = NSAlert()
        alert.messageText = "Welcome to BLEUnlock"
        alert.informativeText = "BLEUnlock locks/unlocks your Mac based on your phone's proximity.\n\nRequired permissions:\n• Bluetooth — detect your device\n• Accessibility — auto-unlock screen\n• Keychain — store login password securely\n• Notifications — alert when locked\n\nPlease grant these when prompted."
        alert.addButton(withTitle: t("ok"))
        alert.window.title = "BLEUnlock"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)
    }
}

// MARK: - SwiftUI Settings

@available(macOS 10.15, *)
class SettingsModel: ObservableObject {
    private let prefs = UserDefaults.standard
    private let ble: BLE
    init(ble: BLE) { self.ble = ble }
    @Published var enabled: Bool = false { didSet { prefs.set(enabled, forKey: "enabled") } }
    @Published var wakeOnProximity: Bool = false { didSet { prefs.set(wakeOnProximity, forKey: "wakeOnProximity") } }
    @Published var wakeWithoutUnlocking: Bool = false { didSet { prefs.set(wakeWithoutUnlocking, forKey: "wakeWithoutUnlocking") } }
    @Published var pauseNowPlaying: Bool = false { didSet { prefs.set(pauseNowPlaying, forKey: "pauseItunes") } }
    @Published var useScreensaver: Bool = false { didSet { prefs.set(useScreensaver, forKey: "screensaver") } }
    @Published var sleepDisplay: Bool = false { didSet { prefs.set(sleepDisplay, forKey: "sleepDisplay") } }
    @Published var passiveMode: Bool = false { didSet { prefs.set(passiveMode, forKey: "passiveMode"); ble.setPassiveMode(passiveMode) } }
    @Published var launchAtLogin: Bool = false { didSet { prefs.set(launchAtLogin, forKey: "launchAtLogin") } }
}

@available(macOS 10.15, *)
struct SettingsView: View {
    @ObservedObject var settings: SettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BLEUnlock Settings").font(.headline)
            Toggle("Enabled", isOn: $settings.enabled)
            Toggle("Wake on Proximity", isOn: $settings.wakeOnProximity)
            Toggle("Wake without Unlocking", isOn: $settings.wakeWithoutUnlocking)
            Toggle("Pause Now Playing", isOn: $settings.pauseNowPlaying)
            Toggle("Use Screensaver to Lock", isOn: $settings.useScreensaver)
            Toggle("Turn Off Screen on Lock", isOn: $settings.sleepDisplay)
            Toggle("Passive Mode", isOn: $settings.passiveMode)
            Toggle("Launch at Login", isOn: $settings.launchAtLogin)
        }
        .padding(20).frame(width: 340)
        .onAppear {
            let p = UserDefaults.standard
            settings.enabled = p.bool(forKey: "enabled")
            settings.wakeOnProximity = p.bool(forKey: "wakeOnProximity")
            settings.wakeWithoutUnlocking = p.bool(forKey: "wakeWithoutUnlocking")
            settings.pauseNowPlaying = p.bool(forKey: "pauseItunes")
            settings.useScreensaver = p.bool(forKey: "screensaver")
            settings.sleepDisplay = p.bool(forKey: "sleepDisplay")
            settings.passiveMode = p.bool(forKey: "passiveMode")
            settings.launchAtLogin = p.bool(forKey: "launchAtLogin")
        }
    }
}
