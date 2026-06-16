// CalibrationWizardView.swift
// 空间校准向导 — 替代干瘪的阈值滑块

import SwiftUI

@available(macOS 12.0, *)
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

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题
            headerBar

            switch step {
            case 0: welcomeStep
            case 1: unlockCountdownStep
            case 2: unlockSamplingStep
            case 3: lockCountdownStep
            case 4: lockSamplingStep
            case 5: resultStep
            default: EmptyView()
            }
        }
        .frame(width: 380, height: 420)
        .background(.regularMaterial)
        .onDisappear {
            samplingTask?.cancel()
            countdownTask?.cancel()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerBar: some View {
        HStack {
            Text("空间校准向导")
                .font(.headline)
            Spacer()
            if step > 0 && step < 5 {
                Text("步骤 \(min(step, 2))/2")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Button(action: { cancelAndClose() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        Divider()
    }

    // MARK: - Step 0: 欢迎

    @ViewBuilder private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "location.viewfinder")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            Text("校准你的锁定距离")
                .font(.title3).fontWeight(.semibold)
            Text("向导会帮你自动测量「坐在一起」和「走到门口」时的蓝牙信号强度，生成最佳阈值。")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
            Button("开始校准") { startUnlockCalibration() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(20)
    }

    // MARK: - Step 1: 解锁倒计时

    @ViewBuilder private var unlockCountdownStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("步骤 1/2：设置解锁距离")
                .font(.headline)
            Text("请带着设备坐在 Mac 前。")
                .font(.callout)
                .foregroundColor(.secondary)
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 8)
                    .frame(width: 100, height: 100)
                Circle()
                    .trim(from: 0, to: CGFloat(countdown) / 5.0)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(-90))
                Text("\(countdown)")
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
            }
            Text("秒后开始采样")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(20)
    }

    // MARK: - Step 2: 解锁采样

    @ViewBuilder private var unlockSamplingStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("正在采集解锁信号…")
                .font(.headline)
            Text("请保持在当前位置不动")
                .font(.callout)
                .foregroundColor(.secondary)

            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 8)
                    .frame(width: 100, height: 100)
                Circle()
                    .trim(from: 0, to: samplingProgress)
                    .stroke(.green, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(currentRSSI.map { "\($0)" } ?? "—")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                    Text("dBm")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Text("已采集 \(samples.count) 个样本")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(20)
    }

    // MARK: - Step 3: 锁定倒计时

    @ViewBuilder private var lockCountdownStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("步骤 2/2：设置锁定距离")
                .font(.headline)
            Text("点击开始后，请在 15 秒内走到你希望\nMac 自动锁屏的位置（如门口）。")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 8)
                    .frame(width: 110, height: 110)
                Circle()
                    .trim(from: 0, to: CGFloat(countdown) / 15.0)
                    .stroke(.orange, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 110, height: 110)
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text("\(countdown)")
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                    Text("秒")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if countdown > 0 {
                Text("请尽快走到目标位置…")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            Spacer()
        }
        .padding(20)
    }

    // MARK: - Step 4: 锁定采样

    @ViewBuilder private var lockSamplingStep: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("正在采集锁定信号…")
                .font(.headline)
            Text("请保持在目标位置不动")
                .font(.callout)
                .foregroundColor(.secondary)

            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 8)
                    .frame(width: 100, height: 100)
                Circle()
                    .trim(from: 0, to: samplingProgress)
                    .stroke(.red, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 100, height: 100)
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(currentRSSI.map { "\($0)" } ?? "—")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                    Text("dBm")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Text("已采集 \(samples.count) 个样本")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(20)
    }

    // MARK: - Step 5: 结果

    @ViewBuilder private var resultStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundColor(.green)
            Text("校准完成")
                .font(.title3).fontWeight(.semibold)

            VStack(spacing: 8) {
                resultRow(icon: "lock.open.fill", label: "解锁信号平均值", value: "\(avgUnlock) dBm", color: .green)
                resultRow(icon: "lock.fill", label: "锁定信号平均值", value: "\(avgLock) dBm", color: .orange)

                Divider().padding(.horizontal, 20)

                resultRow(icon: "slider.horizontal.3", label: "建议解锁阈值", value: "\(suggestedUnlock) dBm", color: .blue)
                resultRow(icon: "slider.horizontal.3", label: "建议锁定阈值", value: "\(suggestedLock) dBm", color: .purple)
            }
            .padding(14)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
            .padding(.horizontal, 20)

            HStack(spacing: 12) {
                Button("取消") { cancelAndClose() }
                    .buttonStyle(.bordered)
                Button("应用推荐值") { applyValues() }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
            }
            Spacer()
        }
        .padding(20)
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
        .padding(.horizontal, 14)
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
        countdownTask = Task {
            for i in (1...5).reversed() {
                guard !Task.isCancelled else { return }
                countdown = i
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled else { return }
            startSampling(duration: 10, completion: {
                self.avgUnlock = self.averageSamples()
                startLockCountdown()
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
                self.avgLock = self.averageSamples()
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

    private func averageSamples() -> Int {
        guard !samples.isEmpty else { return -70 }
        return samples.reduce(0, +) / samples.count
    }

    private func applyValues() {
        let lock = max(min(suggestedLock, -30), -95)
        let unlock = max(min(suggestedUnlock, -30), -95)
        let finalUnlock = max(unlock, lock + 5)
        manager.setLockRSSI(lock)
        manager.setUnlockRSSI(finalUnlock)
        isPresented = false
    }

    private func cancelAndClose() {
        samplingTask?.cancel()
        countdownTask?.cancel()
        isPresented = false
    }
}
