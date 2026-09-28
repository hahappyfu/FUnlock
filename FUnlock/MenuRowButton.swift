// MenuRowButton.swift
// 通用菜单行按钮：悬停轻亮 + 按压微凹 + 可选快捷键提示（MenuBarPopover 的行组件）

import SwiftUI

// MARK: - 弹簧微动效（规格第 4 节：苹果标准物理曲线）

extension Animation {
    /// 菜单交互动效统一弹簧曲线（response 0.32 / damping 0.78）
    static let funSpring = Animation.spring(response: 0.32, dampingFraction: 0.78, blendDuration: 0)
}

/// 带鼠标交互反馈的菜单行：悬停平滑高亮、按下背景加深并轻微缩放
struct MenuRowButton: View {
    let icon: String
    let iconColor: Color
    let title: String
    let titleColor: Color
    let hoverTint: Color
    var trailing: AnyView? = nil
    var disabled = false
    /// 键位三元组（如 (",", .command, "⌘,")）；nil 表示无快捷键
    var shortcut: (key: KeyEquivalent, modifiers: EventModifiers, hint: String)? = nil
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                    .foregroundColor(iconColor)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(titleColor)
                Spacer()
                if let s = shortcut {
                    Text(s.hint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                if let trailing { trailing }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isPressed ? hoverTint.opacity(0.18)
                                    : (isHovering ? hoverTint.opacity(0.08) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isHovering ? Color.white.opacity(0.24) : .clear, lineWidth: 0.6)
            )
            .scaleEffect(isPressed ? 0.985 : 1.0)
            .animation(.funSpring, value: isHovering)
            .animation(.funSpring, value: isPressed)
        }
        .buttonStyle(.plain)
        .modifier(RowKeyEquivalent(shortcut: shortcut))
        .onHover { hovering in
            isHovering = hovering && !disabled
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1.0)
    }
}

/// 有键位时才挂 keyboardShortcut（无键位保持原响应链）
private struct RowKeyEquivalent: ViewModifier {
    let shortcut: (key: KeyEquivalent, modifiers: EventModifiers, hint: String)?

    func body(content: Content) -> some View {
        if let s = shortcut {
            content.keyboardShortcut(s.key, modifiers: s.modifiers)
        } else {
            content
        }
    }
}
