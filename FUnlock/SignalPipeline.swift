import Foundation

// MARK: - 线程安全锁

final class UnfairLock {
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

    // EWLR 参数
    private let ewlrLambda: Double = 0.4
    private let slopeEmaAlpha: Double = 0.3

    mutating func process(rssi: Int, source: SignalSource, now: Date) -> SignalDecision {
        // S0: 源标记
        let sourceWeight: Double = source == .connected ? 1.0 : 0.7

        // S1: IQR 异常检测
        let isAnomalous = applyIQR(window: latestRSSIs, rssi: Double(rssi))

        // S2: EWLR 斜率
        let rawSlope = computeSlopeEWLR(rssis: latestRSSIs, timestamps: rssiTimestamps, now: now)
        let slope = slopeEmaAlpha * rawSlope + (1 - slopeEmaAlpha) * smoothedSlope
        smoothedSlope = slope

        // S3: Kalman
        let estimate = computeKalman(rssi: rssi, slope: slope, isAnomalous: isAnomalous)

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
        let adaptiveRate: Double
        if abs(slope) > slopeSwitchThreshold {
            adaptiveRate = decayRate * (1 + slopeFactor * abs(slope))
        } else {
            adaptiveRate = decayRate / (1 + inactivityFactor * max(elapsed, 0))
        }
        let penalty = adaptiveRate * elapsed
        let effective = max(estimate - penalty, effectiveRSSIFloor)

        return SignalDecision(
            kalmanEstimate: estimate,
            effectiveRSSI: effective,
            slope: slope,
            isAnomalous: isAnomalous,
            sourceWeight: sourceWeight
        )
    }

    private func applyIQR(window: [Double], rssi: Double) -> Bool {
        guard window.count >= 5 else { return false }
        let sorted = window.sorted()
        let n = sorted.count
        let q1 = sorted[n / 4]
        let q3 = sorted[3 * n / 4]
        let iqr = q3 - q1
        return abs(rssi - (q1 + q3) / 2.0) > iqrMultiplier * iqr
    }

    private func computeSlopeEWLR(rssis: [Double], timestamps: [Date], now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-windowDuration)
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

    private mutating func computeKalman(rssi: Int, slope: Double, isAnomalous: Bool) -> Double {
        let measurement = Double(rssi)
        let delta = measurement - kalmanEstimate
        var q = kalmanQ
        kalmanSampleCount += 1
        if kalmanSampleCount > 5 && abs(delta) > kalmanDeadZone {
            if delta > 0 {
                let baseTerm = 1.0 + kalmanAlpha * pow(abs(delta), 1.5)
                let slopeTerm = slope > 0 ? betaSlope * slope : 0.0
                let anomTerm = isAnomalous ? gammaAnomaly : 0
                q = kalmanQ * (baseTerm + slopeTerm + anomTerm)
            } else {
                let anomTerm = isAnomalous ? gammaAnomaly : 0
                q = kalmanQ * (1.0 + anomTerm)
            }
            q = min(q, kalmanQMax)
        }
        let predictedP = kalmanP + q
        let kalmanGain = predictedP / (predictedP + kalmanR)
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

