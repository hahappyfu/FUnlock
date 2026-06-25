// OnboardingView.swift
// 首次使用引导页

import SwiftUI
import Combine

struct OnboardingView: View {
    @Binding var step: Int
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 20) {
            // 步骤指示器
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(i <= step ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.top, 16)

            // 内容
            VStack(spacing: 12) {
                Image(systemName: stepIcon)
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)
                    .padding(.top, 8)

                Text(stepTitle)
                    .font(.title3.bold())

                Text(stepDescription)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()

            // 按钮
            VStack(spacing: 8) {
                if step < 2 {
                    Button(action: { withAnimation { step += 1 } }) {
                        Text(t("onboarding_next"))
                            .font(.callout.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: finishOnboarding) {
                        Text(t("onboarding_skip"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: {
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                        isPresented = false
                    }) {
                        Text(t("onboarding_start"))
                            .font(.callout.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(width: 300, height: 320)
        .background(.regularMaterial)
    }

    private func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        isPresented = false
    }

    private var stepIcon: String {
        switch step {
        case 0: return "lock.open.fill"
        case 1: return "antenna.radiowaves.left.and.right"
        default: return "wand.and.stars"
        }
    }

    private var stepTitle: String {
        switch step {
        case 0: return t("onboarding_title_0")
        case 1: return t("onboarding_title_1")
        default: return t("onboarding_title_2")
        }
    }

    private var stepDescription: String {
        switch step {
        case 0: return t("onboarding_desc_0")
        case 1: return t("onboarding_desc_1")
        default: return t("onboarding_desc_2")
        }
    }
}
