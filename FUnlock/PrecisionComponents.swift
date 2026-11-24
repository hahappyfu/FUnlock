// PrecisionComponents.swift
// 精密仪器风基础组件族：卡片 / 分隔线 / 提示条 / 图标块 / 输入槽 / 按钮 / 行 / 状态徽标 / Sheet 骨架
// 规格：docs/superpowers/specs/2026-11-24-precision-instrument-ui-redesign-spec.md §2.7、§7

import SwiftUI

// MARK: - 卡片

/// 实体卡片：card 表面 + 1px 装饰描边 + radius-lg。无阴影、无渐变。
struct FUnlockCard<Content: View>: View {
    var padding: CGFloat = FUnlockTheme.Space.md
    var cornerRadius: CGFloat = FUnlockTheme.Radius.lg
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(FUnlockTheme.Surface.card.color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(FUnlockTheme.Surface.border.color, lineWidth: 1)
            )
    }
}

// MARK: - 分隔线

/// 1pt 实体分隔线（替代旧版渐隐光带）
struct Hairline: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(FUnlockTheme.Surface.border.color)
            .frame(height: 1)
            .padding(.horizontal, inset)
            .accessibilityHidden(true)
    }
}

// MARK: - 提示条

/// 行内提示：well 表面 + 4pt 左侧语义条 + 标题/说明/动作
struct InlineNotice: View {
    enum Tone {
        case info, warning, danger

        var color: Color {
            switch self {
            case .info: FUnlockTheme.Accent.base.color
            case .warning: FUnlockTheme.State.amberFill.color
            case .danger: FUnlockTheme.State.dangerFill.color
            }
        }

        var icon: String {
            switch self {
            case .info: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .danger: "exclamationmark.octagon.fill"
            }
        }
    }

    var tone: Tone = .warning
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: FUnlockTheme.Space.sm) {
            Image(systemName: tone.icon)
                .font(.callout)
                .foregroundStyle(tone.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(FUnlockTheme.Text.primary.color)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(FUnlockTheme.Text.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: FUnlockTheme.Space.xs)
            if let actionTitle, let action {
                InstrumentButton(title: actionTitle, kind: .secondary, action: action)
            }
        }
        .padding(.vertical, FUnlockTheme.Space.sm)
        .padding(.horizontal, FUnlockTheme.Space.md)
        .background(
            RoundedRectangle(cornerRadius: FUnlockTheme.Radius.md)
                .fill(FUnlockTheme.Surface.well.color)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tone.color)
                .frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: FUnlockTheme.Radius.md))
    }
}

// MARK: - 图标块

/// 语义色图标块：radius-sm + 低透明度语义底。Reduce Transparency 时提高底色并补描边。
struct IconTile: View {
    let systemImage: String
    var tone: StatusTone = .neutral
    var size: CGFloat = 28

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        RoundedRectangle(cornerRadius: FUnlockTheme.Radius.sm)
            .fill(tone.fillColor.opacity(reduceTransparency ? 0.22 : 0.12))
            .overlay(
                RoundedRectangle(cornerRadius: FUnlockTheme.Radius.sm)
                    .strokeBorder(tone.fillColor.opacity(reduceTransparency ? 0.45 : 0), lineWidth: 1)
            )
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(tone.textColor)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: - 输入槽

struct PrecisionFieldModifier: ViewModifier {
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.vertical, 5)
            .padding(.horizontal, FUnlockTheme.Space.xs)
            .background(
                RoundedRectangle(cornerRadius: FUnlockTheme.Radius.sm)
                    .fill(FUnlockTheme.Surface.well.color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FUnlockTheme.Radius.sm)
                    .strokeBorder(isFocused ? FUnlockTheme.Accent.base.color
                                            : FUnlockTheme.Surface.borderStrong.color,
                                  lineWidth: isFocused ? 2 : 1)
            )
            .animation(reduceMotion ? nil : FUnlockTheme.Motion.fast, value: isFocused)
            .focused($isFocused)
    }
}

extension View {
    /// 精密输入槽：well 底 + borderStrong 边界 + 聚焦环
    func precisionField() -> some View {
        modifier(PrecisionFieldModifier())
    }
}

// MARK: - 按钮

struct InstrumentButton: View {
    enum Kind {
        case primary, secondary, ghost, destructive
    }

    let title: String
    var systemImage: String? = nil
    var kind: Kind = .secondary
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.callout)
                }
                Text(title)
                    .font(.callout.weight(.medium))
            }
            .padding(.horizontal, FUnlockTheme.Space.sm)
            .padding(.vertical, 5)
            .frame(minHeight: 28)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: FUnlockTheme.Radius.sm)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FUnlockTheme.Radius.sm)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: FUnlockTheme.Radius.sm))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : FUnlockTheme.Motion.fast, value: hovering)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private var background: Color {
        switch kind {
        case .primary:
            return (hovering ? FUnlockTheme.Accent.hover : FUnlockTheme.Accent.base).color
        case .secondary, .ghost:
            return hovering ? FUnlockTheme.Surface.well.color : .clear
        case .destructive:
            return hovering ? FUnlockTheme.State.dangerFill.color.opacity(0.10) : .clear
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: FUnlockTheme.Accent.onAccent.color
        case .secondary, .ghost: FUnlockTheme.Text.primary.color
        case .destructive: FUnlockTheme.State.dangerText.color
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary: .clear
        case .secondary: FUnlockTheme.Surface.borderStrong.color
        case .ghost: .clear
        case .destructive: FUnlockTheme.State.dangerFill.color.opacity(0.45)
        }
    }
}

// MARK: - 行

/// 通用控制行：图标 + 标题/副标题 + 快捷键 + 尾部视图；hover 用 well 底，无位移
struct ControlRow: View {
    let icon: String
    var tone: StatusTone = .neutral
    let title: String
    var subtitle: String? = nil
    var shortcut: String? = nil
    /// 真实键盘快捷键（key + modifiers）；nil 表示不注册
    var keyShortcut: (key: KeyEquivalent, modifiers: EventModifiers)? = nil
    var trailing: AnyView? = nil
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: FUnlockTheme.Space.xs) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(tone.textColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(FUnlockTheme.Text.primary.color)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(FUnlockTheme.Text.secondary.color)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: FUnlockTheme.Space.xs)
                if let shortcut {
                    Text(shortcut)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(FUnlockTheme.Text.tertiary.color)
                }
                if let trailing { trailing }
            }
            .padding(.horizontal, FUnlockTheme.Space.xs)
            .padding(.vertical, 6)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: FUnlockTheme.Radius.md)
                    .fill(hovering ? FUnlockTheme.Surface.well.color : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(ControlRowKeyShortcut(shortcut: keyShortcut))
        .onHover { hovering = $0 && isEnabled }
        .animation(reduceMotion ? nil : FUnlockTheme.Motion.fast, value: hovering)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// 有键位时才挂 keyboardShortcut（无键位保持原响应链）
private struct ControlRowKeyShortcut: ViewModifier {
    let shortcut: (key: KeyEquivalent, modifiers: EventModifiers)?

    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
        } else {
            content
        }
    }
}

// MARK: - 开关行

/// 设置开关行：图标块 + 标题/说明 + 系统开关。保留原生 Toggle 语义供 VoiceOver 读取。
struct PrecisionToggleRow: View {
    let icon: String
    var tone: StatusTone = .neutral
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var onChange: ((Bool) -> Void)? = nil

    var body: some View {
        HStack(spacing: FUnlockTheme.Space.sm) {
            IconTile(systemImage: icon, tone: tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(FUnlockTheme.Text.primary.color)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(FUnlockTheme.Text.secondary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: FUnlockTheme.Space.xs)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text(title))
                .onChange(of: isOn) { _, value in onChange?(value) }
        }
    }
}

// MARK: - 状态徽标

/// 状态徽标：图标 + 文案 + 语义色（颜色之外必须有形与字）
struct StatusBadge: View {
    let presentation: StatusPresentation
    /// 放在 sidebar / well 等抬升表面时置 true，浅色下改用更深一档的文字色（≥ 4.5:1）
    var onElevatedSurface: Bool = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: presentation.icon)
                .font(.caption2.weight(.semibold))
            Text(t(presentation.titleKey))
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(onElevatedSurface ? presentation.tone.altTextColor : presentation.tone.textColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(presentation.tone.fillColor.opacity(reduceTransparency ? 0.20 : 0.12))
        )
        .overlay(
            Capsule().strokeBorder(presentation.tone.fillColor.opacity(0.30), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var accessibilityText: String {
        guard let detailKey = presentation.detailKey else { return t(presentation.titleKey) }
        return t(presentation.titleKey) + ", " + t(detailKey)
    }
}

// MARK: - Sheet 骨架

/// 统一 Sheet 外壳：标题 + 关闭（Esc）+ 可滚动内容
struct SheetScaffold<Content: View>: View {
    let title: String
    var onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: FUnlockTheme.Space.xs) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(FUnlockTheme.Text.primary.color)
                Spacer(minLength: FUnlockTheme.Space.sm)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.medium))
                        .foregroundStyle(FUnlockTheme.Text.secondary.color)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(t("sheet_close")))
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, FUnlockTheme.Space.xl)
            .padding(.vertical, FUnlockTheme.Space.md)

            Hairline()

            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(FUnlockTheme.Space.xl)
            }
        }
        .background(FUnlockTheme.Surface.canvas.color)
    }
}

/// Sheet 底部动作区：右对齐
struct SheetFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: FUnlockTheme.Space.xs) {
            Spacer(minLength: 0)
            content
        }
        .padding(.horizontal, FUnlockTheme.Space.xl)
        .padding(.vertical, FUnlockTheme.Space.md)
    }
}
