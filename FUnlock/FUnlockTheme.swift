// FUnlockTheme.swift
// 精密仪器风（Direction A）设计 Token 单一来源 + 状态语义契约
// 规格：docs/superpowers/specs/2026-11-24-precision-instrument-ui-redesign-spec.md §2–§3

import SwiftUI
import AppKit

// MARK: - 动态色 Token

extension FUnlockTheme {
    /// 明暗双值 token：只在定义处出现一次明暗分支，调用点不再读 colorScheme。
    struct DynamicToken: Sendable, Equatable {
        let light: UInt32
        let dark: UInt32

        init(light: UInt32, dark: UInt32) {
            self.light = light
            self.dark = dark
        }

        /// AppKit 动态色：随系统外观自动切换
        var nsColor: NSColor {
            NSColor(name: nil) { appearance in
                NSColor(srgbHex: resolvedHex(for: appearance))
            }
        }

        /// SwiftUI 入口
        var color: Color { Color(nsColor: nsColor) }

        /// 指定外观下的解析色（供测试与快照使用）
        func resolved(_ appearance: NSAppearance) -> NSColor {
            NSColor(srgbHex: resolvedHex(for: appearance))
        }

        private func resolvedHex(for appearance: NSAppearance) -> UInt32 {
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

private extension NSColor {
    convenience init(srgbHex hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Token

enum FUnlockTheme {

    /// 表面三级 + 描边。border 仅装饰；可交互控件边界用 borderStrong（≥ 3:1）
    enum Surface {
        static let canvas = DynamicToken(light: 0xF4F6F8, dark: 0x0D1117)
        static let sidebar = DynamicToken(light: 0xECEFF3, dark: 0x121720)
        static let card = DynamicToken(light: 0xFFFFFF, dark: 0x161C26)
        static let well = DynamicToken(light: 0xEEF2F6, dark: 0x1E2633)
        static let border = DynamicToken(light: 0xD8E0E8, dark: 0x2A3444)
        static let borderStrong = DynamicToken(light: 0x64748B, dark: 0x64748B)
    }

    enum Text {
        static let primary = DynamicToken(light: 0x0F172A, dark: 0xF1F5F9)
        static let secondary = DynamicToken(light: 0x475569, dark: 0x94A3B8)
        static let tertiary = DynamicToken(light: 0x64748B, dark: 0x64748B)
    }

    /// 语义色：*Text 用于文字，*Fill 用于图形/填充；*TextAlt 用于 sidebar/well 表面
    enum State {
        static let safeText = DynamicToken(light: 0x15803D, dark: 0x22C55E)
        static let safeTextAlt = DynamicToken(light: 0x166534, dark: 0x22C55E)
        static let safeFill = DynamicToken(light: 0x16A34A, dark: 0x22C55E)
        static let amberText = DynamicToken(light: 0xB45309, dark: 0xF59E0B)
        static let amberTextAlt = DynamicToken(light: 0x92400E, dark: 0xF59E0B)
        static let amberFill = DynamicToken(light: 0xD97706, dark: 0xF59E0B)
        static let dangerText = DynamicToken(light: 0xDC2626, dark: 0xF87171)
        static let dangerTextAlt = DynamicToken(light: 0xB91C1C, dark: 0xF87171)
        static let dangerFill = DynamicToken(light: 0xDC2626, dark: 0xF87171)
    }

    enum Accent {
        static let base = DynamicToken(light: 0x0369A1, dark: 0x38BDF8)
        static let hover = DynamicToken(light: 0x075985, dark: 0x38BDF8)
        static let onAccent = DynamicToken(light: 0xFFFFFF, dark: 0x082F49)
    }

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 12
        static let pill: CGFloat = 9999
    }

    /// 4/8pt 网格
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
    }

    enum Motion {
        static var fast: Animation { .easeOut(duration: 0.12) }
        static var standard: Animation { .easeOut(duration: 0.15) }
        static var settle: Animation { .easeOut(duration: 0.20) }
    }
}

// MARK: - 状态语义契约（单一来源）

enum StatusTone: Equatable, Sendable {
    case safe, amber, danger, neutral

    /// 文字色：neutral 使用次要文字色
    var textColor: Color {
        switch self {
        case .safe: FUnlockTheme.State.safeText.color
        case .amber: FUnlockTheme.State.amberText.color
        case .danger: FUnlockTheme.State.dangerText.color
        case .neutral: FUnlockTheme.Text.secondary.color
        }
    }

    /// 图形/填充色（点、条、图标底）
    var fillColor: Color {
        switch self {
        case .safe: FUnlockTheme.State.safeFill.color
        case .amber: FUnlockTheme.State.amberFill.color
        case .danger: FUnlockTheme.State.dangerFill.color
        case .neutral: FUnlockTheme.Text.secondary.color
        }
    }

    /// sidebar / well 表面上的文字色（浅色下需要更深一档才达 4.5:1）
    var altTextColor: Color {
        switch self {
        case .safe: FUnlockTheme.State.safeTextAlt.color
        case .amber: FUnlockTheme.State.amberTextAlt.color
        case .danger: FUnlockTheme.State.dangerTextAlt.color
        case .neutral: FUnlockTheme.Text.secondary.color
        }
    }
}

/// 四种主状态的单源映射：Sidebar / Popover / Overview / 诊断页全部消费它
struct StatusPresentation: Equatable, Sendable {
    let tone: StatusTone
    let icon: String
    let titleKey: String
    let detailKey: String?

    static func resolve(screen: ScreenState, connected: Bool, hasDevice: Bool) -> StatusPresentation {
        guard hasDevice else {
            return StatusPresentation(tone: .neutral,
                                      icon: "antenna.radiowaves.left.and.right",
                                      titleKey: "no_device",
                                      detailKey: nil)
        }
        switch screen {
        case .unlocked:
            return StatusPresentation(tone: .safe, icon: "lock.open.fill",
                                      titleKey: "mb_unlocked", detailKey: nil)
        case .locked:
            if connected {
                return StatusPresentation(tone: .amber, icon: "lock.fill",
                                          titleKey: "mb_locked", detailKey: nil)
            }
            return StatusPresentation(tone: .danger, icon: "wifi.slash",
                                      titleKey: "mb_disconnected", detailKey: nil)
        case .screensaver:
            return StatusPresentation(tone: .neutral, icon: "moon.zzz.fill",
                                      titleKey: "status_standby", detailKey: "status_screensaver")
        case .displaySleeping:
            return StatusPresentation(tone: .neutral, icon: "moon.zzz.fill",
                                      titleKey: "status_standby", detailKey: "status_display_sleeping")
        }
    }
}
