// ToastView.swift
// 顶部浮动 Toast 通知

import SwiftUI

struct ToastView: View {
    let message: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: FUnlockTheme.Space.xs) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(color)
            Text(message)
                .font(.callout)
                .foregroundStyle(FUnlockTheme.Text.primary.color)
        }
        .padding(.horizontal, FUnlockTheme.Space.md)
        .padding(.vertical, FUnlockTheme.Space.xs)
        .background(
            RoundedRectangle(cornerRadius: FUnlockTheme.Radius.md)
                .fill(FUnlockTheme.Surface.card.color)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FUnlockTheme.Radius.md)
                .strokeBorder(FUnlockTheme.Surface.border.color, lineWidth: 1)
        )
    }
}
