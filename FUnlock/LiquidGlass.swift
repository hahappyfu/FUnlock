// LiquidGlass.swift
// 全局 Liquid Glass 设计 Token：极光流光底座 / 晶体卡片 / 折射分割线 / 琥珀警告条 / 胶囊按钮
// 视觉数值源自 MenuBarPopover 原型验证（docs/superpowers/specs/2026-09-28-liquid-glass-ui-redesign-spec.md）

import SwiftUI

// MARK: - 极光流光底座

/// 晶体液态极光背景层（自发光多点径向渐变网格 + 顶部散射天光，WindowServer 硬件加速离屏渲染）
struct LiquidAuroraMesh: View {
    var opacity: Double = 0.55

    var body: some View {
        ZStack {
            // 左上紫罗兰 #9D91EB
            RadialGradient(
                colors: [Color(red: 157/255, green: 145/255, blue: 235/255).opacity(0.85 * opacity), .clear],
                center: UnitPoint(x: 0.15, y: 0.15),
                startRadius: 10,
                endRadius: 200
            )
            // 右上冰蓝 #9DBEDB
            RadialGradient(
                colors: [Color(red: 157/255, green: 190/255, blue: 219/255).opacity(0.90 * opacity), .clear],
                center: UnitPoint(x: 0.85, y: 0.18),
                startRadius: 10,
                endRadius: 180
            )
            // 左下薄荷 #BCE3DB
            RadialGradient(
                colors: [Color(red: 188/255, green: 227/255, blue: 219/255).opacity(0.75 * opacity), .clear],
                center: UnitPoint(x: 0.20, y: 0.85),
                startRadius: 10,
                endRadius: 170
            )
            // 右下柔粉 #E8BFD8
            RadialGradient(
                colors: [Color(red: 232/255, green: 191/255, blue: 216/255).opacity(0.80 * opacity), .clear],
                center: UnitPoint(x: 0.82, y: 0.82),
                startRadius: 10,
                endRadius: 170
            )
            // 中心高光核 #F4F0FA
            RadialGradient(
                colors: [Color(red: 244/255, green: 240/255, blue: 250/255).opacity(0.90 * opacity), .clear],
                center: UnitPoint(x: 0.5, y: 0.45),
                startRadius: 5,
                endRadius: 140
            )
            // 顶部天光反射散射层
            LinearGradient(
                colors: [Color.white.opacity(0.55 * opacity), Color.white.opacity(0.0)],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 0.6)
            )
        }
        .blur(radius: 20)
    }
}

// MARK: - 晶体玻璃卡片

/// 晶体玻璃卡片：微透凹槽底 + 棱镜微色散内环 + 顺光源 3D 弧面高光环 + 双层彩色微散射投影
struct LiquidCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 14
    var padding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                // 微透凹槽质感（深色 0.05 / 浅色 0.16），透出底层极光与桌面壁纸
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.16))
                    .shadow(
                        // 双层彩色微散射环境投影：挂在背景卡片形状上，保护内部文字边缘高对比
                        color: Color(red: 98/255, green: 86/255, blue: 160/255).opacity(colorScheme == .dark ? 0.25 : 0.15),
                        radius: 12,
                        x: 0,
                        y: 4
                    )
            )
            .overlay(
                // 第一层：棱镜微色散描边
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.55, blue: 0.75).opacity(0.35),
                                Color(red: 0.50, green: 0.80, blue: 1.0).opacity(0.35),
                                Color(red: 0.50, green: 1.0, blue: 0.85).opacity(0.20),
                                Color(red: 1.0, green: 0.60, blue: 0.80).opacity(0.30)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )
            )
            .overlay(
                // 第二层：顺光源 3D 弧面反射高光环（左上强光 → 右下转暗）
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.45 : 0.90),
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.03),
                                Color.white.opacity(colorScheme == .dark ? 0.20 : 0.45)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )
            )
    }
}

extension View {
    /// 换装为 Liquid Glass 晶体卡片（内含 padding，外部再自行安排卡片间距）
    func liquidGlassCard(cornerRadius: CGFloat = 14, padding: CGFloat = 12) -> some View {
        modifier(LiquidCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

// MARK: - 晶体折射分割线

/// 水平晶体折射光线：两端消隐、中间高光
struct LiquidDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.0),
                        // 深色底霜更暗，白光需要压到 0.14 才不与卡片高光环抢视觉
                        Color.white.opacity(colorScheme == .dark ? 0.14 : 0.30),
                        Color.white.opacity(0.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .accessibilityHidden(true)
    }
}

// MARK: - 琥珀晶体警告条

/// 权限/告警提示条：暖琥珀微透晶体底 + 细琥珀晶体边框 + 高对比文案与动作按钮
struct LiquidAmberBanner: View {
    let message: String
    var hint: String? = nil
    let actionLabel: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.callout)
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Button(actionLabel, action: action)
                .controlSize(.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.12))
                .shadow(
                    color: Color.orange.opacity(colorScheme == .dark ? 0.18 : 0.10),
                    radius: 8,
                    x: 0,
                    y: 2
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.orange.opacity(colorScheme == .dark ? 0.42 : 0.34),
                            Color.orange.opacity(0.16),
                            Color.white.opacity(colorScheme == .dark ? 0.24 : 0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
    }
}

// MARK: - 晶体图标徽标

/// 圆角方晶体徽标：色渐变底 + 白色 SF Symbol + 同色微投影
/// 用于设置项 Toggle 左侧统一取代裸彩色图标，与整体 Liquid Glass 语言对齐
struct LiquidIconBadge: View {
    let icon: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(color.gradient)
            Image(systemName: icon)
                .font(.system(size: size * 0.52, weight: .medium))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(0.3), radius: 3, y: 1.5)
    }
}

// MARK: - 晶体输入槽

/// 微透白底（dark 0.06 / light 0.20）+ 0.8px 晶体边框 + 8px 圆角 + 内衬 padding 6/8
/// 自持聚焦态：聚焦时描边提亮，字体（含等宽）由调用方设定
struct LiquidInputField: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.20))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isFocused ? 0.95 : (colorScheme == .dark ? 0.45 : 0.85)),
                                Color.white.opacity(isFocused ? 0.45 : 0.15)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
            )
            .focused($isFocused)
            .animation(.funSpring, value: isFocused)
    }
}

extension View {
    /// 换装为 Liquid Glass 晶体输入槽
    func liquidInputField() -> some View {
        modifier(LiquidInputField())
    }
}

// MARK: - 晶体液态胶囊按钮

/// 悬浮高光 + 按下弹性缩放的玻璃胶囊按键（底部操作栏、卡片内动作按钮通用）
struct LiquidPillButton: View {
    let title: String
    let systemImage: String
    var action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @State private var isPressed = false

    private var baseFrost: Double { colorScheme == .dark ? 0.06 : 0.18 }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(baseFrost + (isHovering ? 0.10 : 0)))
                        .shadow(
                            color: Color(red: 98/255, green: 86/255, blue: 160/255).opacity(colorScheme == .dark ? 0.22 : 0.12),
                            radius: 6,
                            x: 0,
                            y: 2
                        )
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.40 : 0.85),
                                    Color.white.opacity(0.12),
                                    Color.white.opacity(colorScheme == .dark ? 0.18 : 0.35)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                )
                .scaleEffect(isPressed ? 0.985 : 1.0)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.funSpring, value: isHovering)
        .animation(.funSpring, value: isPressed)
        .onHover { isHovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}
