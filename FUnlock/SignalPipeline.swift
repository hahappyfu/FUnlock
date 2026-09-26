import Foundation

// MARK: - 线程安全锁

final class UnfairLock: @unchecked Sendable {
    private var _lock = os_unfair_lock()
    func lock() { os_unfair_lock_lock(&_lock) }
    func unlock() { os_unfair_lock_unlock(&_lock) }
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        let result = body()
        unlock()
        return result
    }
}

// MARK: - 信号处理管道类型

struct SignalDecision: Equatable {
    let kalmanEstimate: Double
    let effectiveRSSI: Double
    let slope: Double
    let isAnomalous: Bool
    let sourceWeight: Double
}

enum SignalSource { case scanning, connected }

// MARK: - 管道状态容器

struct SignalPipeline {
    var kalmanEstimate: Double = -60.0
    var kalmanP: Double = 1.0
    var kalmanSampleCount: Int = 0
    var smoothedSlope: Double = 0.0
    var latestRSSIs: [Double] = []
    var rssiTimestamps: [Date] = []
    /// 输入活跃时重置衰减基准，防止用户操作期间 effectiveRSSI 因时间衰减跌破阈值
    var decayBaseline: Date = .distantPast
    let windowDuration: TimeInterval = 1.5

    // Kalman 参数
    private let kalmanQ: Double = 0.008
    private let kalmanR: Double = 0.5
    private let kalmanAlpha: Double = 0.02
    private let kalmanQMax: Double = 0.5
    private let kalmanDeadZone: Double = 2.0
    private let betaSlope: Double = 0.1
    private let gammaAnomaly: Double = 1.5

    // 衰减参数
    private let decayRate: Double = 0.5
    private let effectiveRSSIFloor: Double = -100.0
    private let slopeFactor: Double = 0.3
    private let inactivityFactor: Double = 0.05
    private let slopeSwitchThreshold: Double = 2.0

    // IQR 参数
    private let iqrMultiplier: Double = 2.0
    /// IQR 异常检测的固定样本数 N（调用方时间窗裁剪须保底保留该数量）
    let iqrSampleCount: Int = 8

    // EWLR 参数
    private let ewlrLambda: Double = 0.4
    private let slopeEmaAlpha: Double = 0.3

    /// 信号中断判定阈值（秒）：距上一采样超过该值视为中断恢复，重置 Kalman 状态
    private let interruptionResetThreshold: TimeInterval = 30.0

    /// 斜率/裁剪时间窗：max(1.5s, 2×最近两样本间隔)。
    /// 固定 1.5s 窗口在 2s/8s 慢采样档只剩 1 个样本导致斜率恒 0，窗口须随采样间隔自适应
    /// （调用方在摄入当前样本后调用，rssiTimestamps 倒数两个即最近样本间隔）
    func effectiveWindowDuration() -> TimeInterval {
        guard rssiTimestamps.count >= 2 else { return windowDuration }
        let lastInterval = rssiTimestamps[rssiTimestamps.count - 1]
            .timeIntervalSince(rssiTimestamps[rssiTimestamps.count - 2])
        return max(windowDuration, 2 * max(lastInterval, 0))
    }

    mutating func process(rssi: Int, source: SignalSource, now: Date) -> SignalDecision {
        // S-1: 信号中断恢复（距上一采样 >30s）先重置 Kalman 状态再摄入当前样本，
        // 避免恢复后首样本被当「紧邻采样」（陈旧估计 + 稳态小增益缓慢爬向真实值）。
        // 生产路径当前点已由调用方先追加（last 即当前），故取倒数第二个为上一采样；
        // 直接调用时 last 即上一采样
        let lastSampleTime: Date? = rssiTimestamps.count >= 2
            ? rssiTimestamps[rssiTimestamps.count - 2]
            : rssiTimestamps.last
        if let lastSampleTime = lastSampleTime,
           now.timeIntervalSince(lastSampleTime) > interruptionResetThreshold {
            kalmanP = 1.0
            kalmanSampleCount = 0
        }

        // S0: 源标记
        let sourceWeight: Double = source == .connected ? 1.0 : 0.7

        // S1: IQR 异常检测（按最近固定 N 个样本计算，不受时间窗裁剪影响）
        let isAnomalous = applyIQR(window: latestRSSIs, rssi: Double(rssi))

        // S2: EWLR 斜率
        let rawSlope = computeSlopeEWLR(rssis: latestRSSIs, timestamps: rssiTimestamps, now: now)
        let slope = slopeEmaAlpha * rawSlope + (1 - slopeEmaAlpha) * smoothedSlope
        smoothedSlope = slope

        // S3: Kalman（dt 取上一样本间隔：rssiTimestamps 已含当前点，倒数两个即其间隔；无历史则 1s）
        let dt: TimeInterval = rssiTimestamps.count >= 2
            ? rssiTimestamps[rssiTimestamps.count - 1].timeIntervalSince(rssiTimestamps[rssiTimestamps.count - 2])
            : 1.0
        let estimate = computeKalman(rssi: rssi, slope: slope, isAnomalous: isAnomalous, dt: dt)

        // S4: 自适应衰减
        // 用倒数第二个时间戳计算 elapsed（当前点已追加，last 即 now，elapsed 会是 0）
        let sampleTime: Date = {
            if rssiTimestamps.count >= 2 {
                return rssiTimestamps[rssiTimestamps.count - 2]
            }
            return now
        }()
        let effectiveBaseline = max(sampleTime, decayBaseline)
        let elapsed = now.timeIntervalSince(effectiveBaseline)
        // 衰减计算对 elapsed 封顶 2s：惩罚与采样间隔解耦（8s 档不再比 0.5s 档静态多扣 ~2.6dB）
        let decayElapsed = min(elapsed, 2.0)
        let adaptiveRate: Double
        if slope < -slopeSwitchThreshold {
            // 仅快速离场方向放大惩罚；走近/平稳一律走缓速档
            adaptiveRate = decayRate * (1 + slopeFactor * abs(slope))
        } else {
            adaptiveRate = decayRate / (1 + inactivityFactor * max(decayElapsed, 0))
        }
        let penalty = adaptiveRate * decayElapsed
        let effective = max(estimate - penalty, effectiveRSSIFloor)

        return SignalDecision(
            kalmanEstimate: estimate,
            effectiveRSSI: effective,
            slope: slope,
            isAnomalous: isAnomalous,
            sourceWeight: sourceWeight
        )
    }

    private func applyIQR(window rawWindow: [Double], rssi: Double) -> Bool {
        // 按最近固定 N=8 个样本计算（suffix），不受调用方时间窗裁剪影响——
        // 0.5s 采样档的 1.5s 时间窗内最多 4 个样本，≥5 门限原本永不满足
        let window = Array(rawWindow.suffix(iqrSampleCount))
        guard window.count >= 5 else { return false }
        let sorted = window.sorted()
        let n = sorted.count
        let q1 = sorted[n / 4]
        let q3 = sorted[3 * n / 4]
        let iqr = q3 - q1
        return abs(rssi - (q1 + q3) / 2.0) > iqrMultiplier * iqr
    }

    private func computeSlopeEWLR(rssis: [Double], timestamps: [Date], now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-effectiveWindowDuration())
        var sumW: Double = 0
        var sumWT: Double = 0
        var sumWR: Double = 0
        var sumWTR: Double = 0
        var sumWT2: Double = 0
        for i in rssis.indices {
            let t = timestamps[i]
            guard t >= cutoff else { continue }
            let dt = now.timeIntervalSince(t)
            let w = exp(-ewlrLambda * dt)
            let r = rssis[i]
            sumW += w
            sumWT += w * dt
            sumWR += w * r
            sumWTR += w * dt * r
            sumWT2 += w * dt * dt
        }
        guard sumW > 1 else { return 0 }
        let denom = sumW * sumWT2 - sumWT * sumWT
        guard abs(denom) > 1e-6 else { return 0 }
        let slope = -(sumW * sumWTR - sumWT * sumWR) / denom
        return max(min(slope, 30), -30)
    }

    private mutating func computeKalman(rssi: Int, slope: Double, isAnomalous: Bool, dt: TimeInterval) -> Double {
        let measurement = Double(rssi)
        let delta = measurement - kalmanEstimate
        // Q 按采样间隔缩放：0.5/2/8s 三档等效过程噪声一致，8s 档对真实移动不再「失聪」
        let dtScale = min(max(dt, 0.5), 5.0)
        var q = kalmanQ * dtScale
        kalmanSampleCount += 1
        if kalmanSampleCount > 5 && abs(delta) > kalmanDeadZone {
            let baseTerm = 1.0 + kalmanAlpha * pow(abs(delta), 1.5)
            // 正负向对称：只有斜率与 delta 同向（真实移动而非噪声尖峰）才加速 Q，
            // 离场方向（delta<0 且 slope<0）同样加速，避免走远时估计严重滞后
            let slopeTerm: Double
            if delta > 0 && slope > 0 {
                slopeTerm = betaSlope * slope
            } else if delta < 0 && slope < 0 {
                slopeTerm = betaSlope * abs(slope)
            } else {
                slopeTerm = 0.0
            }
            let anomTerm = isAnomalous ? gammaAnomaly : 0
            q = kalmanQ * dtScale * (baseTerm + slopeTerm + anomTerm)
            q = min(q, kalmanQMax)
        }
        let predictedP = kalmanP + q
        var kalmanGain = predictedP / (predictedP + kalmanR)
        if isAnomalous {
            // 异常样本降权：增益减半仅轻微牵引估计（isAnomalous 仍照常标记供遥测）
            kalmanGain *= 0.5
        }
        kalmanEstimate = kalmanEstimate + kalmanGain * (measurement - kalmanEstimate)
        kalmanP = (1 - kalmanGain) * predictedP
        return kalmanEstimate
    }

    mutating func reset() {
        kalmanEstimate = -60.0
        kalmanP = 1.0
        kalmanSampleCount = 0
        smoothedSlope = 0.0
        latestRSSIs.removeAll()
        rssiTimestamps.removeAll()
        decayBaseline = .distantPast
    }
}

