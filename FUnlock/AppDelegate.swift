// AppDelegate.swift — 纯 View Controller (NSPopover 版)
// 职责：NSPopover UI + 转发系统通知给 BluetoothManager

import Cocoa
import Carbon
import ServiceManagement
import UserNotifications
import SwiftUI
import Combine
import CoreBluetooth
import IOKit.hid
import os.lock

// MARK: - 输入活动监听

extension Notification.Name {
    static let menuShowStats = Notification.Name("menuShowStats")
    static let globalHotKeyPressed = Notification.Name("globalHotKeyPressed")
}

class InputActivityMonitor {
    private var hidManager: IOHIDManager?
    private var _lastInputTime: Date = Date.distantPast
    private var lock = os_unfair_lock()
    var activityWindow: TimeInterval = 30

    var lastInputTime: Date {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _lastInputTime
    }

    var isActive: Bool {
        Date().timeIntervalSince(lastInputTime) < activityWindow
    }

    func start() {
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(0))
        guard let hidManager = hidManager else { return }
        let keyboard: [String: Any] = [
            kIOHIDDeviceUsagePageKey: 0x01,
            kIOHIDDeviceUsageKey: 0x06
        ]
        let trackpad: [String: Any] = [
            kIOHIDDeviceUsagePageKey: 0x0D,
            kIOHIDDeviceUsageKey: 0x04
        ]
        IOHIDManagerSetDeviceMatchingMultiple(hidManager, [keyboard, trackpad] as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(hidManager, inputCallback, ctx)
        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(hidManager, IOOptionBits(0))
    }

    func stop() {
        if let mgr = hidManager {
            IOHIDManagerClose(mgr, IOOptionBits(0))
            hidManager = nil
        }
    }

    fileprivate func didReceiveInput() {
        os_unfair_lock_lock(&lock)
        _lastInputTime = Date()
        os_unfair_lock_unlock(&lock)
    }
}

private func inputCallback(_ ctx: UnsafeMutableRawPointer?,
                            _ result: IOReturn,
                            _ sender: UnsafeMutableRawPointer?,
                            _ value: IOHIDValue) {
    guard let ctx = ctx else { return }
    Unmanaged<InputActivityMonitor>.fromOpaque(ctx).takeUnretainedValue().didReceiveInput()
}

// MARK: - Carbon 全局快捷键回调

private func hotKeyCallback(_ nextHandler: EventHandlerCallRef?,
                            _ event: EventRef?,
                            _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    NotificationCenter.default.post(name: .globalHotKeyPressed, object: nil)
    return noErr
}

// MARK: - 权限检查视图

struct PermissionCheckView: View {
    @State private var accessibilityGranted = false
    @State private var bluetoothGranted = false
    @Environment(\.dismiss) private var dismiss

    var allGranted: Bool { accessibilityGranted && bluetoothGranted }

    var body: some View {
        VStack(spacing: 20) {
            Text(t("permission_check_title")).font(.title2.bold())
            Text(t("permission_check_desc")).foregroundColor(.secondary)

            VStack(spacing: 12) {
                row(t("permission_ax_name"), t("permission_ax_desc"), accessibilityGranted) { requestAX() }
                row(t("permission_bt_name"), t("permission_bt_desc"), bluetoothGranted) { requestBT() }
            }.padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button(t("permission_skip_all")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(allGranted ? t("permission_done") : t("permission_refresh")) {
                    refresh()
                    if allGranted { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 420).onAppear { refresh() }
    }

    private func row(_ name: String, _ desc: String, _ granted: Bool, _ action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundColor(granted ? .green : .orange).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.bold())
                Text(desc).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !granted { Button(t("permission_grant")) { action() }.buttonStyle(.bordered) }
        }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        bluetoothGranted = (CBManager.authorization == .allowedAlways)
    }

    private func requestAX() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
        openSettings("com.apple.preference.security?Privacy_Accessibility")
    }

    private func requestBT() {
        openSettings("com.apple.preference.security?Privacy_Bluetooth")
    }

    private func openSettings(_ pane: String) {
        let script = "tell application \"System Settings\"\nactivate\nreveal pane id \"\(pane)\"\nend tell"
        if let s = NSAppleScript(source: script) { var e: NSDictionary?; s.executeAndReturnError(&e) }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, FUnDelegate {

    override init() {
        super.init()
    }

    // MARK: - UI 组件

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var settingsWindow: NSWindow!

    // MARK: - 核心依赖

    lazy var fun = FUn()
    var manager: FUnManager!
    let inputMonitor = InputActivityMonitor()
    let prefs = UserDefaults.standard
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 全局快捷键

    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyEventHandler: EventHandlerRef?

    // MARK: - FUnDelegate（UI 更新 + 转发设备事件）

    @MainActor func newDevice(device: Device) {
        manager.onDeviceDiscovered(device)
    }
    @MainActor func updateDevice(device: Device) {
        manager.onDeviceUpdated(device)
    }
    @MainActor func removeDevice(device: Device) {
        manager.onDeviceRemoved(device)
    }

    @MainActor func updateRSSI(rssi: Int?, active: Bool) {
        manager.onRSSIUpdated(rssi: rssi, active: active)
        if let _ = rssi {
            if !manager.connected {
                manager.updateConnected(true)
            }
        } else {
            if manager.connected {
                manager.updateConnected(false)
            }
        }
        updateStatusBarIcon()
    }

    @MainActor func updatePresence(presence: Bool, reason: String) {
        if presence {
            manager.onDeviceApproached()
        } else {
            manager.onDeviceLeft(reason: reason)
        }
        updateStatusBarIcon()
    }

    /// 根据连接状态和屏幕状态更新菜单栏图标
    @MainActor private func updateStatusBarIcon() {
        guard let button = statusItem.button else { return }
        if manager.state.screen == .unlocked {
            // 已解锁：用绿色渲染连接图标
            let img = NSImage(named: "StatusBarConnected")?.copy() as? NSImage
            img?.isTemplate = false
            img?.lockFocus()
            NSColor.controlAccentColor.set()
            NSRect(origin: .zero, size: img?.size ?? .zero).fill(using: .sourceAtop)
            img?.unlockFocus()
            button.image = img
            button.toolTip = "FUnlock — Unlocked"
        } else if manager.connected {
            // 已连接但锁屏：默认模板图标
            button.image = NSImage(named: "StatusBarConnected")
            button.toolTip = "FUnlock — Connected"
        } else {
            // 未连接
            button.image = NSImage(named: "StatusBarDisconnected")
            button.toolTip = "FUnlock — Disconnected"
        }
    }

    @MainActor func bluetoothPowerWarn() {
        UIHelper.errorModal(t("bluetooth_power_warn"))
    }

    @MainActor func onDeviceApproached() {
        manager.onDeviceApproached()
    }

    // MARK: - UNUserNotificationCenter

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) -> UNNotificationPresentationOptions {
        return [.alert, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        if id == "funlock-update" {
            // 点击更新通知 → 触发下载安装
            DispatchQueue.main.async { [weak self] in
                self?.checkForUpdates()
            }
        } else if id == FUnlockStateMachine.degradedNotificationID {
            // 点击降级通知 → 重置失败计数，恢复自动解锁
            DispatchQueue.main.async { [weak self] in
                self?.manager?.stateMachine.resetToActive()
            }
        } else {
            NSWorkspace.shared.open(URL(string: "https://github.com/hahappyfu/FUnlock/releases")!)
        }
    }

    // MARK: - Popover

    @MainActor @objc func toggleSettingsWindow(_ sender: AnyObject?) {
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

    @MainActor @objc func lockNow() {
        manager.lockNow()
    }

    @MainActor @objc func showStats() {
        toggleSettingsWindow(nil)
        // 通知 MenuDashboardView 打开统计页
        NotificationCenter.default.post(name: .menuShowStats, object: nil)
    }

    @MainActor @objc func changePassword() {
        SecurityService.shared.askPassword()
    }

    @MainActor @objc func checkForUpdates() {
        // 更新菜单项状态
        guard let menu = statusItem.menu else { return }
        for item in menu.items where item.action == #selector(checkForUpdates) {
            item.title = t("menu_checking")
            item.isEnabled = false
        }
        manager.forceCheckUpdate { [weak self] version in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let menu = self.statusItem.menu else { return }
                if version != nil {
                    // 有新版本，downloader 会自动开始下载
                    self.observeDownloadProgress()
                } else {
                    // 已是最新
                    for item in menu.items where item.action == #selector(self.checkForUpdates) {
                        item.title = t("menu_check_update")
                        item.isEnabled = true
                    }
                    self.showSimpleAlert(title: t("already_latest"))
                }
            }
        }
    }

    private func observeDownloadProgress() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            guard let menu = self.statusItem.menu else { timer.invalidate(); return }
            switch self.manager.updateState {
            case .downloading(let progress):
                for item in menu.items where item.action == #selector(self.checkForUpdates) {
                    item.title = String(format: t("menu_download_progress"), Int(progress * 100))
                }
            case .completed:
                timer.invalidate()
                for item in menu.items where item.action == #selector(self.checkForUpdates) {
                    item.title = t("menu_check_update")
                    item.isEnabled = true
                }
            case .failed:
                timer.invalidate()
                for item in menu.items where item.action == #selector(self.checkForUpdates) {
                    item.title = t("menu_check_update")
                    item.isEnabled = true
                }
            case .idle:
                break
            }
        }
    }

    private func showSimpleAlert(title: String) {
        let alert = NSAlert()
        alert.messageText = "FUnlock"
        alert.informativeText = title
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 全局快捷键注册

    func setupGlobalHotKey() {
        // ⌘⇧L — Carbon RegisterEventHotKey
        let hotKeyID = EventHotKeyID(signature: OSType(0x4655_4C4B), id: 1) // 'FULK'

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let status1 = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyCallback,
            1, &eventType, nil,
            &hotKeyEventHandler
        )
        guard status1 == noErr else { return }

        let status2 = RegisterEventHotKey(
            UInt32(kVK_ANSI_L),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status2 == noErr else { return }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGlobalHotKey),
            name: .globalHotKeyPressed,
            object: nil
        )
    }

    func teardownGlobalHotKey() {
        NotificationCenter.default.removeObserver(self, name: .globalHotKeyPressed, object: nil)
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = hotKeyEventHandler {
            RemoveEventHandler(handler)
            hotKeyEventHandler = nil
        }
    }

    // MARK: - 用户主动干预监听

    /// 监听屏幕唤醒通知，用户主动干预时强制状态机回到 active
    func setupUserInterventionObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.manager.onUserIntervention()
        }
    }

    @objc private func handleGlobalHotKey() {
        DispatchQueue.main.async { [weak self] in
            self?.lockNow()
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
        restoreSettingsToFUn()
        setupManager()
        restoreSavedDevice()
        setupStatusBarAndMenu()
        setupNotificationSubscriptions()
        setupPermissionsAndPrivileges()
    }

    /// 从 UserDefaults 恢复 BLE 设置到 fun（manager init 会再同步一次）
    @MainActor private func restoreSettingsToFUn() {
        let lockRSSI = prefs.integer(forKey: "lockRSSI"); if lockRSSI != 0 { fun.lockRSSI = lockRSSI }
        let unlockRSSI = prefs.integer(forKey: "unlockRSSI"); if unlockRSSI != 0 { fun.unlockRSSI = unlockRSSI }
        let timeout = prefs.integer(forKey: "timeout"); if timeout != 0 { fun.signalTimeout = Double(timeout) }
        fun.setPassiveMode(prefs.bool(forKey: "passiveMode"))
        let thresholdRSSI = prefs.integer(forKey: "thresholdRSSI"); if thresholdRSSI != 0 { fun.thresholdRSSI = thresholdRSSI }
        let lockDelay = prefs.integer(forKey: "lockDelay"); if lockDelay != 0 { fun.proximityTimeout = Double(lockDelay) }
    }

    /// 初始化 manager 并接线 delegate / inputMonitor
    @MainActor private func setupManager() {
        manager = FUnManager(fun: fun)
        fun.delegate = self
        manager.inputMonitor = inputMonitor
        fun.inputMonitor = inputMonitor
        // InputActivityMonitor 延迟到首次需要时再启动（macOS Sequoia TCC 兼容）
        // 原代码在此处直接 start() 会导致 TCC 崩溃
    }

    /// 恢复已保存的绑定设备
    @MainActor private func restoreSavedDevice() {
        if let str = prefs.string(forKey: "device"), let uuid = UUID(uuidString: str) {
            manager.updateConnected(false)
            manager.monitoredDeviceName = prefs.string(forKey: "deviceName") ?? t("default_paired_device")
            fun.startMonitor(uuid: uuid)
        }
    }

    /// 状态栏图标 + 右键快捷菜单 + 设置窗口延迟初始化
    @MainActor private func setupStatusBarAndMenu() {
        // 延迟初始化设置窗口（避免 macOS Sequoia TCC 框架崩溃）
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.setupSettingsWindow()
        }
        if let button = statusItem.button {
            button.image = NSImage(named: "StatusBarDisconnected")
            button.target = self
            button.toolTip = "FUnlock"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: t("menu_open_settings"), action: #selector(toggleSettingsWindow(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: t("menu_change_password"), action: #selector(changePassword), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: t("menu_check_update"), action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: t("menu_lock_now"), action: #selector(lockNow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: t("menu_stats"), action: #selector(showStats), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: t("menu_quit"), action: #selector(quitApp), keyEquivalent: ""))
        statusItem.menu = menu
    }

    /// 注册系统通知订阅（屏幕/系统睡眠唤醒、锁屏、屏保、密码变更）
    @MainActor private func setupNotificationSubscriptions() {
        // 通知权限
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // 转发系统通知 → FUnManager
        let nc = NSWorkspace.shared.notificationCenter
        nc.publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { [weak self] _ in self?.manager.onDisplaySleep(); self?.updateStatusBarIcon() }
            .store(in: &cancellables)
        nc.publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in self?.manager.onDisplayWake(); self?.updateStatusBarIcon() }
            .store(in: &cancellables)
        nc.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.manager.onSystemSleep(); self?.updateStatusBarIcon() }
            .store(in: &cancellables)
        nc.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.manager.onSystemWake(); self?.updateStatusBarIcon() }
            .store(in: &cancellables)

        let dnc = DistributedNotificationCenter.default
        dnc.publisher(for: NSNotification.Name("com.apple.screenIsUnlocked"))
            .sink { [weak self] _ in self?.manager.onUnlock(); self?.updateStatusBarIcon() }
            .store(in: &cancellables)
        dnc.publisher(for: NSNotification.Name("com.apple.screenIsLocked"))
            .sink { [weak self] _ in self?.manager.onSystemScreenLocked(); self?.updateStatusBarIcon() }
            .store(in: &cancellables)
        dnc.publisher(for: NSNotification.Name("com.apple.screensaver.didstart"))
            .sink { [weak self] _ in self?.manager.onScreensaverStart(); self?.updateStatusBarIcon() }
            .store(in: &cancellables)
        dnc.publisher(for: NSNotification.Name("com.apple.screensaver.didstop"))
            .sink { [weak self] _ in self?.manager.onScreensaverStop(); self?.updateStatusBarIcon() }
            .store(in: &cancellables)
        dnc.publisher(for: NSNotification.Name("com.apple.security.loginwindow.passwordChanged"))
            .sink { [weak self] _ in SecurityService.shared.handlePasswordChanged() }
            .store(in: &cancellables)
    }

    /// 密码检查 + 辅助功能权限 + 开机自启动同步 + 权限面板 + 快捷键 + 用户干预监听
    @MainActor private func setupPermissionsAndPrivileges() {
        // 密码检查
        if fun.unlockRSSI != fun.UNLOCK_DISABLED && !prefs.bool(forKey: "wakeWithoutUnlocking") {
            let fetchResult = SecurityService.shared.fetchPassword()
            if case .success(nil) = fetchResult {
                SecurityService.shared.askPassword()
            }
        }

        // Accessibility — 解锁功能需要，每次启动都检查
        if fun.unlockRSSI != fun.UNLOCK_DISABLED && !prefs.bool(forKey: "wakeWithoutUnlocking") {
            if !isAccessibilityGranted {
                requestAccessibilityIfNeeded()
            }
            // InputActivityMonitor 延迟到权限确认后启动（macOS Sequoia TCC 兼容）
            if isAccessibilityGranted {
                inputMonitor.start()
            }
        }
        checkAccessibility()
        // UpdateChecker 已注入到 FUnManager，由 manager.onUnlock() 触发

        // 启动时同步开机自启动状态
        if #available(macOS 13.0, *) {
            let registered = SMAppService.mainApp.status == .enabled
            prefs.set(registered, forKey: "launchAtLogin")
        }

        // 启动时检查权限
        showPermissionCheck()

        NSApp.setActivationPolicy(.accessory)

        // 注册全局快捷键 ⌘⇧L（lock screen）
        setupGlobalHotKey()

        // 监听用户主动干预（手动唤醒屏幕）→ 强制状态机恢复 active
        setupUserInterventionObserver()
    }

    func setupSettingsWindow() {
        let dashboard = MainWindowView(manager: manager, fun: fun)
        let hostingVC = NSHostingController(rootView: dashboard)
        settingsWindow = NSWindow(contentViewController: hostingVC)
        settingsWindow.title = "FUnlock"
        settingsWindow.styleMask = [.titled, .closable, .resizable]
        settingsWindow.contentMinSize = NSSize(width: 560, height: 420)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.center()
    }

    // MARK: - 权限检查

    private var permissionWindow: NSWindow?

    func showPermissionCheck() {
        let ax = AXIsProcessTrusted()
        let bt = (CBManager.authorization == .allowedAlways)
        guard !ax || !bt else {
            // 权限已全部授予，暂不启动输入监控（macOS Sequoia TCC 兼容）
            return
        }

        let view = PermissionCheckView()
        let hosting = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: hosting)
        win.title = t("permission_check_window_title")
        win.styleMask = [.titled, .closable]
        win.contentMinSize = NSSize(width: 420, height: 320)
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        permissionWindow = win
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        teardownGlobalHotKey()
        cancellables.removeAll()
        manager?.cleanup()
    }
}
