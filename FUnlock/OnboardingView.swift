// OnboardingView.swift
// 首次使用引导：3 步，可回退，Esc / 关闭即跳过，末步可直达校准向导

import SwiftUI

struct OnboardingView: View {
    @Binding var step: Int
    @Binding var isPresented: Bool
    /// 末步「打开校准向导」回调（由 MainWindowView 在关闭引导后执行）
    var onOpenCalibration: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SheetScaffold(title: "FUnlock", onClose: finishOnboarding) {
            VStack(spacing: FUnlockTheme.Space.md) {
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Circle()
                            .fill(i <= step ? FUnlockTheme.Accent.base.color
                                            : FUnlockTheme.Surface.borderStrong.color.opacity(0.4))
                            .frame(width: 6, height: 6)
                    }
                }

                VStack(spacing: FUnlockTheme.Space.xs) {
                    Image(systemName: stepIcon)
                        .font(.system(size: 40))
                        .foregroundStyle(FUnlockTheme.Accent.base.color)
                    Text(stepTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(FUnlockTheme.Text.primary.color)
                    Text(stepDescription)
                        .font(.callout)
                        .foregroundStyle(FUnlockTheme.Text.secondary.color)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, FUnlockTheme.Space.md)

                SheetFooter {
                    if step > 0 {
                        InstrumentButton(title: t("onboarding_back"), kind: .ghost) {
                            withAnimation(reduceMotion ? nil : FUnlockTheme.Motion.standard) { step -= 1 }
                        }
                    }
                    if step < 2 {
                        InstrumentButton(title: t("onboarding_skip"), kind: .ghost,
                                         action: finishOnboarding)
                        InstrumentButton(title: t("onboarding_next"), kind: .primary) {
                            withAnimation(reduceMotion ? nil : FUnlockTheme.Motion.standard) { step += 1 }
                        }
                    } else {
                        InstrumentButton(title: t("onboarding_open_calibration"), kind: .secondary) {
                            isPresented = false
                            onOpenCalibration?()
                        }
                        InstrumentButton(title: t("onboarding_start"), kind: .primary,
                                         action: finishOnboarding)
                    }
                }
            }
        }
        .frame(width: 380, height: 420)
    }

    private func finishOnboarding() {
        ConfigStore.shared.defaults.set(true, forKey: "hasCompletedOnboarding")
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
