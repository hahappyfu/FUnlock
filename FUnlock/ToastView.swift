// ToastView.swift
// 顶部浮动 Toast 通知

import SwiftUI

struct ToastView: View {
    let message: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(message)
                .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}
