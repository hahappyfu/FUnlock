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
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, FUnDelegate {

    // MARK: - UI 组件

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var settingsWindow: NSWindow!
    var aboutBox: AboutBox? = nil

    // MARK: - 核心依赖

    let fun = FUn()
    var manager: FUnManager!
    let prefs = UserDefaults.standard
    var cancellables = Set<AnyCancellable>()

    // MARK: - FUnDelegate（UI 更新 + 转发设备事件）

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

    @objc func toggleSettingsWindow(_ sender: AnyObject?) {
        if settingsWindow.isVisible {
            settingsWindow.orderOut(nil)
            fun.stopScanning()
        } else {
            // 居中显示
            settingsWindow.center()
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            fun.startScanning()
        }
    }

    // MARK: - Accessibility

    /// 纯净检查（不弹窗），用于 UI 显示权限状态
    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// 带弹窗请求（用户可在系统设置中手动批准）
    func requestAccessibilityIfNeeded() {
        guard !isAccessibilityGranted else { return }
        // agent 应用（无 Dock 图标）可能无法弹出系统授权弹窗
        // 直接打开系统设置的辅助功能页面，让用户手动添加
        let script = """
        tell application "System Settings"
            activate
            reveal pane id "com.apple.preference.security?Privacy_Accessibility"
        end tell
        """
        if let AppleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            AppleScript.executeAndReturnError(&error)
        }
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
        // 先恢复设置到 ble（manager init 会同步 ble 的值）
        let lockRSSI = prefs.integer(forKey: "lockRSSI"); if lockRSSI != 0 { fun.lockRSSI = lockRSSI }
        let unlockRSSI = prefs.integer(forKey: "unlockRSSI"); if unlockRSSI != 0 { fun.unlockRSSI = unlockRSSI }
        let timeout = prefs.integer(forKey: "timeout"); if timeout != 0 { fun.signalTimeout = Double(timeout) }
        fun.setPassiveMode(prefs.bool(forKey: "passiveMode"))
        let thresholdRSSI = prefs.integer(forKey: "thresholdRSSI"); if thresholdRSSI != 0 { fun.thresholdRSSI = thresholdRSSI }
        let lockDelay = prefs.integer(forKey: "lockDelay"); if lockDelay != 0 { fun.proximityTimeout = Double(lockDelay) }

        // 初始化 manager（此时 ble 已有正确的 UserDefaults 值）
        manager = FUnManager(fun: fun)
        fun.delegate = self

        // 恢复已保存的设备
        if let str = prefs.string(forKey: "device"), let uuid = UUID(uuidString: str) {
            manager.updateConnected(false)
            manager.monitoredDeviceName = prefs.string(forKey: "deviceName") ?? "已配对设备"
            fun.startMonitor(uuid: uuid)
        }

        // 初始化设置窗口
        let dashboard = MenuDashboardView(manager: manager, fun: fun)
        let hostingVC = NSHostingController(rootView: dashboard)
        settingsWindow = NSWindow(contentViewController: hostingVC)
        settingsWindow.title = "FUnlock"
        settingsWindow.styleMask = [.titled, .closable, .resizable]
        settingsWindow.contentMinSize = NSSize(width: 320, height: 480)
        settingsWindow.contentMaxSize = NSSize(width: 320, height: 800)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.center()

        // 绑定状态栏按钮
        if let button = statusItem.button {
            button.image = NSImage(named: "StatusBarDisconnected")
            button.action = #selector(toggleSettingsWindow(_:))
            button.target = self
            button.toolTip = "FUnlock"
        }

        // 点击外部关闭窗口 —— 已不需要（独立窗口自带关闭按钮）

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
            prefs.set(true, forKey: "hasShownGuide")
        }

        // 密码检查
        if fun.unlockRSSI != fun.UNLOCK_DISABLED && !prefs.bool(forKey: "wakeWithoutUnlocking") && manager.fetchPassword() == nil {
            manager.askPassword()
        }

        // Accessibility — 解锁功能需要，每次启动都检查
        if fun.unlockRSSI != fun.UNLOCK_DISABLED && !prefs.bool(forKey: "wakeWithoutUnlocking") {
            if !isAccessibilityGranted {
                requestAccessibilityIfNeeded()
            }
        }
        checkAccessibility()
        FUnlock.checkUpdate()

        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)
        manager?.cleanup()
    }
}
