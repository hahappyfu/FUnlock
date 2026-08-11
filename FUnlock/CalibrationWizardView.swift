// CalibrationWizardView.swift
// 空间校准向导 — 替代干瘪的阈值滑块

import SwiftUI

struct CalibrationWizardView: View {
    @ObservedObject var manager: FUnManager
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
        VStack(spacing: 0) {
            // 顶部标题
            headerBar

            Form {
                switch step {
                case 0: welcomeSection
                case 1: unlockCountdownSection
                case 2: unlockSamplingSection
                case 3: lockCountdownSection
                case 4: lockSamplingSection
                case 5: resultSection
                default: EmptyView()
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 380, height: 420)
        .onDisappear {
            samplingTask?.cancel()
            countdownTask?.cancel()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerBar: some View {
        HStack {
            Text(t("calibration_header"))
                .font(.headline)
            Spacer()
            Button(action: { cancelAndClose() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: - Step 0: 欢迎

    @ViewBuilder private var welcomeSection: some View {
        Section {
            VStack(spacing: 16) {
                Image(systemName: "location.viewfinder")
                    .font(.system(size: 40))
                    .foregroundColor(.accentColor)
                    .padding(.top, 8)
                Text(t("calibration_welcome_title"))
                    .font(.title3).fontWeight(.semibold)
                Text(t("calibration_welcome_desc"))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                if !errorMessage.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundColor(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

            Button(t("calibration_start")) { startUnlockCalibration() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Step 1: 解锁倒计时

    @ViewBuilder private var unlockCountdownSection: some View {
        Section(t("calibration_unlock_step_title")) {
            VStack(spacing: 16) {
                Text(t("calibration_unlock_step_desc"))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                CalibrationRing(progress: Double(countdown) / 5.0,
                                color: .accentColor, size: 100) {
                    Text("\(countdown)")
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                }

                Text(t("calibration_countdown_sampling"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Step 2: 解锁采样

    @ViewBuilder private var unlockSamplingSection: some View {
        Section {
            VStack(spacing: 16) {
                Text(t("calibration_sampling_unlock"))
                    .font(.headline)
                Text(t("calibration_stay_still"))
                    .font(.callout)
                    .foregroundColor(.secondary)

                CalibrationRing(progress: samplingProgress, color: .green, size: 100) {
                    VStack(spacing: 2) {
                        Text(currentRSSI.map { "\($0)" } ?? "—")
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                        Text("dBm")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Text(t("calibration_samples_collected") + "\(samples.count) " + t("calibration_samples_unit"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Step 3: 锁定倒计时

    @ViewBuilder private var lockCountdownSection: some View {
        Section(t("calibration_lock_step_title")) {
            VStack(spacing: 16) {
                Text(t("calibration_lock_step_desc"))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                CalibrationRing(progress: Double(countdown) / 15.0,
                                color: .orange, size: 110) {
                    VStack(spacing: 2) {
                        Text("\(countdown)")
                            .font(.system(size: 40, weight: .bold, design: .monospaced))
                        Text(t("calibration_seconds_unit"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                if countdown > 0 {
                    Text(t("calibration_hurry_to_target"))
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Step 4: 锁定采样

    @ViewBuilder private var lockSamplingSection: some View {
        Section {
            VStack(spacing: 16) {
                Text(t("calibration_sampling_lock"))
                    .font(.headline)
                Text(t("calibration_hold_target"))
                    .font(.callout)
                    .foregroundColor(.secondary)

                CalibrationRing(progress: samplingProgress, color: .red, size: 100) {
                    VStack(spacing: 2) {
                        Text(currentRSSI.map { "\($0)" } ?? "—")
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                        Text("dBm")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Text(t("calibration_samples_collected") + "\(samples.count) " + t("calibration_samples_unit"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Step 5: 结果

    @ViewBuilder private var resultSection: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.green)
                Text(t("calibration_complete"))
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)

            resultRow(icon: "lock.open.fill", label: t("calibration_avg_unlock"), value: "\(avgUnlock) dBm", color: .green)
            resultRow(icon: "lock.fill", label: t("calibration_avg_lock"), value: "\(avgLock) dBm", color: .orange)
            resultRow(icon: "slider.horizontal.3", label: t("calibration_suggested_unlock"), value: "\(suggestedUnlock) dBm", color: .blue)
            resultRow(icon: "slider.horizontal.3", label: t("calibration_suggested_lock"), value: "\(suggestedLock) dBm", color: .purple)

            HStack(spacing: 12) {
                Button(t("cancel")) { cancelAndClose() }
                    .buttonStyle(.bordered)
                Button(t("calibration_apply_recommended")) { applyValues() }
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
    }

    private func resultRow(icon: String, label: String, value: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)
            Text(label)
                .font(.callout)
            Spacer()
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.medium)
        }
    }

    // MARK: - 计算

    private var suggestedUnlock: Int {
        let v = avgUnlock - 2
        return min(max(v, -95), -30)
    }

    private var suggestedLock: Int {
        let v = avgLock - 2
        return min(max(v, -95), -30)
    }

    // MARK: - 流程控制

    private func startUnlockCalibration() {
        step = 1
        countdown = 5
        samples = []
        errorMessage = ""
        countdownTask = Task {
            for i in (1...5).reversed() {
                guard !Task.isCancelled else { return }
                countdown = i
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled else { return }
            startSampling(duration: 10, completion: {
                guard let avg = self.averageSamples() else {
                    // 未采到任何样本（设备不在信号范围），中断校准并提示用户重试
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
                    // 未采到任何样本（设备不在信号范围），中断校准并提示用户重试
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
                if let rssi = manager.rssi {
                    samples.append(rssi)
                    currentRSSI = rssi
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
        samples = []
        currentRSSI = nil
        errorMessage = "未检测到信号，请靠近设备后重试"
        step = 0
    }

    private func applyValues() {
        let lock = max(min(suggestedLock, -30), -95)
        let unlock = max(min(suggestedUnlock, -30), -95)
        let finalUnlock = max(unlock, lock + 5)
        manager.setUnlockRSSI(finalUnlock)
        manager.setLockRSSI(lock)
        isPresented = false
    }

    private func cancelAndClose() {
        samplingTask?.cancel()
        countdownTask?.cancel()
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
                .stroke(Color.secondary.opacity(0.2), lineWidth: 8)
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
