// BehaviorSettingsView.swift
// Tab 2：行为与通知 —— 合并原有 基础 / 解锁 / 锁定 三个 Tab 与两张通知卡
// 规格：docs/superpowers/specs/2026-11-24-precision-instrument-ui-redesign-spec.md §4.3

import SwiftUI
import ServiceManagement

struct BehaviorSettingsView: View {
    @AppStorage("enabled", store: ConfigStore.shared.defaults) private var enabled = true
    @AppStorage("launchAtLogin", store: ConfigStore.shared.defaults) private var launchAtLogin = false
    @AppStorage("wakeOnProximity", store: ConfigStore.shared.defaults) private var wakeOnProximity = false
    @AppStorage("wakeWithoutUnlocking", store: ConfigStore.shared.defaults) private var wakeWithoutUnlocking = false
    @AppStorage("screensaver", store: ConfigStore.shared.defaults) private var useScreensaver = false
    @AppStorage("pauseItunes", store: ConfigStore.shared.defaults) private var pauseItunes = false
    @AppStorage("sleepDisplay", store: ConfigStore.shared.defaults) private var sleepDisplay = false
    @AppStorage("lockOnIdle", store: ConfigStore.shared.defaults) private var lockOnIdle = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
                runtimeCard
                unlockCard
                lockCard
                notificationCard
            }
            .padding(.horizontal, FUnlockTheme.Space.md)
            .padding(.top, FUnlockTheme.Space.sm)
            .padding(.bottom, FUnlockTheme.Space.lg)
        }
    }

    // MARK: - 运行

    private var runtimeCard: some View {
        FUnlockCard {
            VStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
                PrecisionToggleRow(icon: "power", tone: .safe,
                                   title: t("enable"), subtitle: t("enable_desc"),
                                   isOn: $enabled)
                Hairline()
                PrecisionToggleRow(icon: "arrow.up.circle", tone: .neutral,
                                   title: t("launch_at_login"), subtitle: t("launch_at_login_desc"),
                                   isOn: $launchAtLogin, onChange: syncLaunchAtLogin)
            }
        }
    }

    // MARK: - 解锁

    private var unlockCard: some View {
        FUnlockCard {
            VStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
                PrecisionToggleRow(icon: "display", tone: .neutral,
                                   title: t("wake_on_proximity"), subtitle: t("wake_on_proximity_desc"),
                                   isOn: $wakeOnProximity)
                Hairline()
                PrecisionToggleRow(icon: "lock.open", tone: .neutral,
                                   title: t("wake_without_unlock"), subtitle: t("wake_without_unlock_desc"),
                                   isOn: $wakeWithoutUnlocking)
                Hairline()
                PrecisionToggleRow(icon: "sparkles.tv", tone: .neutral,
                                   title: t("use_screensaver"), subtitle: t("use_screensaver_desc"),
                                   isOn: $useScreensaver)
            }
        }
    }

    // MARK: - 锁定

    private var lockCard: some View {
        FUnlockCard {
            VStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
                PrecisionToggleRow(icon: "pause.circle", tone: .neutral,
                                   title: t("pause_on_lock"), subtitle: t("pause_on_lock_desc"),
                                   isOn: $pauseItunes)
                Hairline()
                PrecisionToggleRow(icon: "moon.fill", tone: .neutral,
                                   title: t("sleep_display_on_lock"), subtitle: t("sleep_display_on_lock_desc"),
                                   isOn: $sleepDisplay)
                Hairline()
                PrecisionToggleRow(icon: "keyboard", tone: .neutral,
                                   title: t("defer_lock_on_input"), subtitle: t("defer_lock_on_input_desc"),
                                   isOn: $lockOnIdle)
            }
        }
    }

    // MARK: - 通知

    private var notificationCard: some View {
        FUnlockCard {
            VStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
                IMSettingsCard()
                Hairline()
                BarkSettingsCard()
            }
        }
    }

    // MARK: - 开机自启

    private func syncLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            AppLog.error(.app, "smAppServiceFailed", [("error", "\(error)")])
        }
    }
}
