// AppDelegate.swift — 纯 View Controller (NSPopover 版)
// 职责：NSPopover UI + 转发系统通知给 BluetoothManager

import Cocoa
import ServiceManagement
import UserNotifications
import SwiftUI
import Combine

func t(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

@MainActor
@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, BLEDelegate {

    // MARK: - UI 组件

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var popover: NSPopover!
    var aboutBox: AboutBox? = nil
    var eventMonitor: Any?

    // MARK: - 核心依赖

    let ble = BLE()
    var manager: BluetoothManager!
    let prefs = UserDefaults.standard
    var cancellables = Set<AnyCancellable>()

    // MARK: - BLEDelegate（UI 更新 + 转发设备事件）

    func newDevice(device: Device) {
        manager.onDeviceDiscovered(device)
    }
    func updateDevice(device: Device) {
        manager.onDeviceUpdated(device)
    }
    func removeDevice(device: Device) {
        manager.onDeviceRemoved(device)
    }

    func updateRSSI(rssi: Int?, active: Bool) {
        manager.onRSSIUpdated(rssi: rssi, active: active)
        if let _ = rssi {
            if !manager.connected {
                manager.updateConnected(true)
                statusItem.button?.image = NSImage(named: "StatusBarConnected")
            }
        } else {
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

    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool { true }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) -> UNNotificationPresentationOptions {
        return [.alert, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        NSWorkspace.shared.open(URL(string: "https://gitee.com/fuhahah/bleunlock/releases")!)
    }

    // MARK: - Popover

    @objc func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
            ble.stopScanning()
        } else {
            if let button = statusItem.button {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                ble.startScanning()
            }
        }
    }

    // MARK: - Accessibility

    /// 纯净检查（不弹窗），用于 UI 显示权限状态
    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// 仅在确认未授权时请求弹窗，避免每次启动都弹
    func requestAccessibilityIfNeeded() {
        guard !isAccessibilityGranted else { return }
        // 带 prompt 参数触发系统弹窗
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    /// 保留向后兼容的启动检查（仅首次运行时弹窗）
    func checkAccessibility() {
        if !isAccessibilityGranted {
            // 首次运行才弹窗，后续启动只静默检查
            let isFirstRun = !prefs.bool(forKey: "hasCheckedAccessibility")
            if isFirstRun {
                prefs.set(true, forKey: "hasCheckedAccessibility")
                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                AXIsProcessTrustedWithOptions(opts)
            }
        }
    }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        manager = BluetoothManager(ble: ble)
        ble.delegate = self

        // 恢复已保存的设备
        if let str = prefs.string(forKey: "device"), let uuid = UUID(uuidString: str) {
            manager.updateConnected(false)
            manager.monitoredDeviceName = prefs.string(forKey: "deviceName") ?? "已配对设备"
            ble.startMonitor(uuid: uuid)
        }

        // 恢复设置
        let lockRSSI = prefs.integer(forKey: "lockRSSI"); if lockRSSI != 0 { ble.lockRSSI = lockRSSI }
        let unlockRSSI = prefs.integer(forKey: "unlockRSSI"); if unlockRSSI != 0 { ble.unlockRSSI = unlockRSSI }
        let timeout = prefs.integer(forKey: "timeout"); if timeout != 0 { ble.signalTimeout = Double(timeout) }
        ble.setPassiveMode(prefs.bool(forKey: "passiveMode"))
        let thresholdRSSI = prefs.integer(forKey: "thresholdRSSI"); if thresholdRSSI != 0 { ble.thresholdRSSI = thresholdRSSI }
        let lockDelay = prefs.integer(forKey: "lockDelay"); if lockDelay != 0 { ble.proximityTimeout = Double(lockDelay) }

        // 初始化 Popover UI
        let dashboard = MenuDashboardView(manager: manager, ble: ble)
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 450)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: dashboard)

        // 绑定状态栏按钮
        if let button = statusItem.button {
            button.image = NSImage(named: "StatusBarDisconnected")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // 点击外部关闭 popover
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.popover.isShown == true {
                self?.popover.performClose(nil)
            }
        }

        // 通知权限
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
        dnc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.manager.onSystemScreenLocked() }
        dnc.addObserver(forName: NSNotification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in self?.manager.onScreensaverStart() }
        dnc.addObserver(forName: NSNotification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in self?.manager.onScreensaverStop() }

        // 首次引导
        if !prefs.bool(forKey: "hasShownGuide") {
            prefs.set(true, forKey: "enabled")
            showFirstLaunchGuide()
        }

        // 密码检查
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
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
