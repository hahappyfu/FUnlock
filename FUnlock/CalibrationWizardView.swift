// CalibrationWizardView.swift
// 空间校准向导：SheetScaffold + FUnlockCard 换装，5 步流程与阈值计算保持不变

import SwiftUI

struct CalibrationWizardView: View {
    var manager: FUnManager
    @Binding var isPresented: Bool

    @State private var step = 0          // 0=欢迎, 1=解锁倒计时, 2=解锁采样, 3=锁定倒计时, 4=锁定采样, 5=结果
    @State private var countdown = 0
    @State private var samplingProgress: Double = 0
    @State private var samples: [Int] = []
    @State private var avgUnlock: Int = 0
    @State private var avgLock: Int = 0
    @State private var samplingTask: Task<Void, Never>?
    @State private var countdownTask: Task<Void, Never>?
    @State private var currentRSSI: Int? = nil
    @State private var errorMessage = ""          // 采样失败提示（如"未检测到信号"）

    var body: some View {
        SheetScaffold(title: t("calibration_header"), onClose: cancelAndClose) {
            VStack(alignment: .leading, spacing: FUnlockTheme.Space.sm) {
                switch step {
                case 0: welcomeCard
                case 1: unlockCountdownCard
                case 2: unlockSamplingCard
                case 3: lockCountdownCard
                case 4: lockSamplingCard
                case 5: resultCard
                default: EmptyView()
                }
            }
        }
        .frame(width: 420, height: 500)
        .onDisappear {
            samplingTask?.cancel()
            countdownTask?.cancel()
            if manager.isCalibrating {
                manager.isCalibrating = false
                manager.fun.refreshProximityGrace()
            }
        }
    }

    // MARK: - Step 0: 欢迎

    private var welcomeCard: some View {
        FUnlockCard {
            VStack(spacing: FUnlockTheme.Space.sm) {
                Image(systemName: "location.viewfinder")
                    .font(.system(size: 40))
                    .foregroundStyle(FUnlockTheme.Accent.base.color)
                Text(t("calibration_welcome_title"))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(FUnlockTheme.Text.primary.color)
                Text(t("calibration_welcome_desc"))
                    .font(.callout)
                    .foregroundStyle(FUnlockTheme.Text.secondary.color)
                    .multilineTextAlignment(.center)
                if !errorMessage.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(FUnlockTheme.State.amberText.color)
                        .multilineTextAlignment(.center)
                }
                HStack {
                    Spacer()
                    InstrumentButton(title: t("calibration_start"), kind: .primary) {
                        startUnlockCalibration()
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Step 1: 解锁倒计时

    private var unlockCountdownCard: some View {
        FUnlockCard {
            VStack(spacing: FUnlockTheme.Space.sm) {
                Text(t("calibration_unlock_step_title"))
                    .font(.headline)
                    .foregroundStyle(FUnlockTheme.Text.primary.color)
                Text(t("calibration_unlock_step_desc"))
                    .font(.callout)
                    .foregroundStyle(FUnlockTheme.Text.secondary.color)
                    .multilineTextAlignment(.center)

                CalibrationRing(progress: Double(countdown) / 5.0,
                                color: FUnlockTheme.Accent.base.color, size: 100) {
                    Text("\(countdown)")
                        .font(.title.monospacedDigit().weight(.bold))
                }

                Text(t("calibration_countdown_sampling"))
                    .font(.caption)
                    .foregroundStyle(FUnlockTheme.Text.secondary.color)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Step 2: 解锁采样

    private var unlockSamplingCard: some View {
        FUnlockCard {
            VStack(spacing: FUnlockTheme.Space.sm) {
                Text(t("calibration_sampling_unlock"))
                    .font(.headline)
                    .foregroundStyle(FUnlockTheme.Text.primary.color)
                Text(t("calibration_stay_still"))
                    .font(.callout)
                    .foregroundStyle(FUnlockTheme.Text.secondary.color)

                CalibrationRing(progress: samplingProgress,
                                color: FUnlockTheme.State.safeFill.color, size: 100) {
                    rssiReadout
                }

                Text(t("calibration_samples_collected") + "\(samples.count) " + t("calibration_samples_unit"))
                    .font(.caption)
                    .foregroundStyle(FUnlockTheme.Text.secondary.color)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Step 3: 锁定倒计时

    private var lockCountdownCard: some View {
        FUnlockCard {
            VStack(spacing: FUnlockTheme.Space.sm) {
                Text(t("calibration_lock_step_title"))
                    .font(.headline)
                    .foregroundStyle(FUnlockTheme.Text.primary.color)
                Text(t("calibration_lock_step_desc"))
                    .font(.callout)
                    .foregroundStyle(FUnlockTheme.Text.secondary.color)
                    .multilineTextAlignment(.center)

                CalibrationRing(progress: Double(countdown) / 15.0,
                                color: FUnlockTheme.State.amberFill.color, size: 110) {
                    VStack(spacing: 2) {
                        Text("\(countdown)")
                            .font(.title.monospacedDigit().weight(.bold))
                        Text(t("calibration_seconds_unit"))
                            .font(.caption2)
                            .foregroundStyle(FUnlockTheme.Text.secondary.color)
                    }
                }

                if countdown > 0 {
                    Text(t("calibration_hurry_to_target"))
                        .font(.caption)
                        .foregroundStyle(FUnlockTheme.State.amberText.color)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Step 4: 锁定采样

    private var lockSamplingCard: some View {
        FUnlockCard {
            VStack(spacing: FUnlockTheme.Space.sm) {
                Text(t("calibration_sampling_lock"))
                    .font(.headline)
                    .foregroundStyle(FUnlockTheme.Text.primary.color)
                Text(t("calibration_hold_target"))
                    .font(.callout)
                    .foregroundStyle(FUnlockTheme.Text.secondary.color)

                CalibrationRing(progress: samplingProgress,
                                color: FUnlockTheme.State.dangerFill.color, size: 100) {
                    rssiReadout
                }

                Text(t("calibration_samples_collected") + "\(samples.count) " + t("calibration_samples_unit"))
                    .font(.caption)
                    .foregroundStyle(FUnlockTheme.Text.secondary.color)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var rssiReadout: some View {
        VStack(spacing: 2) {
            Text(currentRSSI.map { "\($0)" } ?? "—")
                .font(.title.monospacedDigit().weight(.bold))
            Text("dBm")
                .font(.caption2)
                .foregroundStyle(FUnlockTheme.Text.secondary.color)
        }
    }

    // MARK: - Step 5: 结果

    private var resultCard: some View {
        FUnlockCard {
            VStack(spacing: FUnlockTheme.Space.sm) {
                VStack(spacing: FUnlockTheme.Space.xs) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title)
                        .foregroundStyle(FUnlockTheme.State.safeFill.color)
                    Text(t("calibration_complete"))
                        .font(.headline)
                        .foregroundStyle(FUnlockTheme.Text.primary.color)
                }
                .frame(maxWidth: .infinity)

                resultRow(icon: "lock.open.fill", label: t("calibration_avg_unlock"),
                          value: "\(avgUnlock) dBm", tone: .safe)
                resultRow(icon: "lock.fill", label: t("calibration_avg_lock"),
                          value: "\(avgLock) dBm", tone: .amber)
                resultRow(icon: "slider.horizontal.3", label: t("calibration_suggested_unlock"),
                          value: "\(Self.computeFinalThresholds(avgUnlock: avgUnlock, avgLock: avgLock).unlock) dBm",
                          tone: .neutral)
                resultRow(icon: "slider.horizontal.3", label: t("calibration_suggested_lock"),
                          value: "\(Self.computeFinalThresholds(avgUnlock: avgUnlock, avgLock: avgLock).lock) dBm",
                          tone: .neutral)

                HStack(spacing: FUnlockTheme.Space.xs) {
                    Spacer()
                    InstrumentButton(title: t("cancel"), kind: .ghost, action: cancelAndClose)
                    InstrumentButton(title: t("calibration_apply_recommended"), kind: .primary,
                                     action: applyValues)
                }
            }
        }
    }

    private func resultRow(icon: String, label: String, value: String, tone: StatusTone) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(tone.fillColor)
                .frame(width: 20)
            Text(label)
                .font(.callout)
                .foregroundStyle(FUnlockTheme.Text.primary.color)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(FUnlockTheme.Text.primary.color)
        }
    }

    // MARK: - 计算

    private var suggestedUnlock: Int {
        let v = avgUnlock - 2
        return SignalHysteresisEngine.clampRSSI(v)
    }

    private var suggestedLock: Int {
        let v = avgLock - 2
        return SignalHysteresisEngine.clampRSSI(v)
    }

    /// 实际应用的最终阈值（静态纯函数，供测试与 Step 5 预览共用）：
    /// 均先钳制到 rssiRange；迟滞不足 gap 时上移 unlock（再钳上限），并保证 lock < unlock。
    static func computeFinalThresholds(avgUnlock: Int, avgLock: Int) -> (unlock: Int, lock: Int) {
        let suggestedUnlock = SignalHysteresisEngine.clampRSSI(avgUnlock - 2)
        let suggestedLock = SignalHysteresisEngine.clampRSSI(avgLock - 2)
        var finalUnlock = max(suggestedUnlock, suggestedLock + lockUnlockDelayGap)
        finalUnlock = min(max(finalUnlock, SignalHysteresisEngine.rssiRange.lowerBound),
                          SignalHysteresisEngine.rssiRange.upperBound)
        let finalLock = min(suggestedLock, finalUnlock - 1)
        return (finalUnlock, finalLock)
    }

    /// 退出校准：复位标记并给用户走回电脑的缓冲（防止采样期积累的离场判定立即锁屏）
    private func endCalibration() {
        samplingTask?.cancel()
        countdownTask?.cancel()
        if manager.isCalibrating {
            manager.isCalibrating = false
            manager.fun.refreshProximityGrace()
        }
    }

    // MARK: - 流程控制

    private func startUnlockCalibration() {
        step = 1
        countdown = 5
        samples = []
        errorMessage = ""
        manager.isCalibrating = true
        countdownTask = Task {
            for i in (1...5).reversed() {
                guard !Task.isCancelled else { return }
                countdown = i
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled else { return }
            startSampling(duration: 10, completion: {
                guard let avg = self.averageSamples() else {
                    self.abortCalibration()
                    return
                }
                self.avgUnlock = avg
                self.startLockCountdown()
            })
        }
    }

    private func startLockCountdown() {
        step = 3
        countdown = 15
        samples = []
        countdownTask = Task {
            for i in (1...15).reversed() {
                guard !Task.isCancelled else { return }
                countdown = i
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled else { return }
            startSampling(duration: 10, completion: {
                guard let avg = self.averageSamples() else {
                    self.abortCalibration()
                    return
                }
                self.avgLock = avg
                NSSound(named: "Glass")?.play()
                self.step = 5
            })
        }
    }

    private func startSampling(duration: Int, completion: @escaping () -> Void) {
        step = (step == 1) ? 2 : 4
        samples = []
        samplingProgress = 0
        samplingTask = Task {
            let totalMs = duration * 10
            for i in 0..<totalMs {
                guard !Task.isCancelled else { return }
                // 采样一律使用与实际靠近/离开判定同源的 effectiveRSSI；
                // 只要仍有信号（presence 或 displayRSSI 非空）就不再退回慢收敛值。
                let snap = manager.fun.signalSnapshot()
                if snap.presence || manager.rssi != nil {
                    let eff = Int(snap.effectiveRSSI.rounded())
                    samples.append(eff)
                    currentRSSI = eff
                }
                samplingProgress = Double(i) / Double(totalMs)
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            samplingProgress = 1.0
            try? await Task.sleep(nanoseconds: 300_000_000)
            completion()
        }
    }

    private func averageSamples() -> Int? {
        guard !samples.isEmpty else { return nil }
        return samples.reduce(0, +) / samples.count
    }

    // 采样失败（未检测到信号）时中断校准：回到欢迎页并显示提示
    private func abortCalibration() {
        samplingTask?.cancel()
        countdownTask?.cancel()
        endCalibration()
        samples = []
        currentRSSI = nil
        errorMessage = t("calibration_no_signal_retry")
        step = 0
    }

    private func applyValues() {
        let final = Self.computeFinalThresholds(avgUnlock: avgUnlock, avgLock: avgLock)
        manager.setUnlockRSSI(final.unlock)
        manager.setLockRSSI(final.lock)
        endCalibration()
        isPresented = false
    }

    /// Esc / 关闭：结束校准并关闭（避免采样期离场判定立即锁屏）
    private func cancelAndClose() {
        endCalibration()
        isPresented = false
    }
}

// MARK: - 环形进度

private struct CalibrationRing<Content: View>: View {
    let progress: Double
    let color: Color
    let size: CGFloat
    @ViewBuilder var center: () -> Content

    var body: some View {
        ZStack {
            Circle()
                .stroke(FUnlockTheme.Surface.well.color, lineWidth: 8)
                .frame(width: size, height: size)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90))
            center()
        }
    }
}
