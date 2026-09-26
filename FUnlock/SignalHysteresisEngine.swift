// FUnlock/SignalHysteresisEngine.swift
import Foundation

/// 靠近 / 离开判定结果（双阈值迟滞窗口）。
struct ProximityDecision: Equatable {
    /// 解析后的解锁阈值（unlockRSSI 为禁用哨兵时回退 lockRSSI）
    let unlockThreshold: Int
    /// 解析后的锁定阈值（lockRSSI 为禁用哨兵时回退 unlockRSSI）
    let lockThreshold: Int
    /// 靠近：有效信号 ≥ 解锁阈值（进入在场态）
    let isClose: Bool
    /// 离开：有效信号 < 锁定阈值（低于锁定迟滞下沿）
    let isAway: Bool
}

/// 迟滞与阶梯唤醒纯逻辑引擎：阶梯唤醒偏移、动态锁屏超时、锁冷静期与靠近/离开判定。
/// 全部为无状态判定（仅 `offsetSetting` 读取 ConfigStore 配置），不依赖 CoreBluetooth，
/// 边界可直接以纯单测验证。
enum SignalHysteresisEngine {
    // MARK: - 哨兵常量（单一来源；FUn 以同名别名暴露保持向下兼容）

    /// 解锁禁用哨兵值：unlockRSSI 等于此值时解锁功能关闭
    static let unlockDisabled = 1
    /// 锁定禁用哨兵值：lockRSSI 等于此值时不单独设锁定阈值，回退使用解锁阈值
    static let lockDisabled = -100

    // MARK: - 阈值范围与钳制（全项目唯一定义）

    /// RSSI 阈值允许范围（dBm）
    static let rssiRange: ClosedRange<Int> = -95...(-30)

    /// 钳制 RSSI 阈值到允许范围
    static func clampRSSI(_ value: Int) -> Int {
        min(max(value, rssiRange.lowerBound), rssiRange.upperBound)
    }

    /// 步进调节解锁阈值（供诊断页等调用）：
    /// current 为 UNLOCK_DISABLED 时返回 -95，否则按 delta 步进并钳制在 [lowerBound, upperBound]
    static func stepUnlockThreshold(current: Int, delta: Int) -> Int {
        if current == unlockDisabled {
            return rssiRange.lowerBound
        }
        return clampRSSI(current + delta)
    }

    // MARK: - 阶梯唤醒偏移

    /// 默认唤醒提前量（dB）
    static let defaultWakeAdvance = 20
    /// 默认预解锁触发量（dB）
    static let defaultPreUnlockTrigger = 10
    /// 偏移量允许范围（dB）
    static let offsetRange = 0...20

    /// 将偏移量钳制到允许范围（UI 可能输入越界值）
    static func clampOffset(_ value: Int) -> Int {
        min(max(value, offsetRange.lowerBound), offsetRange.upperBound)
    }

    /// 读取偏移设置，越界/缺失时回退默认值
    static func offsetSetting(_ key: String, default dft: Int) -> Int {
        let value = ConfigStore.shared.object(forKey: key) as? Int ?? dft
        return clampOffset(value)
    }

    // MARK: - 动态锁屏超时

    /// 方案 C：按下降斜率计算锁屏超时 —— 陡降（slope ≤ -fastSlopeThreshold）→ fastLockTimeout；
    /// 缓降/平稳（slope ≥ -mildSlopeThreshold）→ base；中间线性插值。
    /// 插值 t 以快速档边界为 0（slope=-8）、缓降边界为 1（slope=-1）：
    /// t = (slope + fastSlopeThreshold) / (fastSlopeThreshold - mildSlopeThreshold)，
    /// 陡降拿短超时、缓降拿长超时，且两边界处连续无跳变
    static func lockTimeout(slope: Double, base: TimeInterval = 5.0) -> TimeInterval {
        if slope <= -fastSlopeThreshold {
            return fastLockTimeout
        } else if slope >= -mildSlopeThreshold {
            return base
        } else {
            let t = (slope + fastSlopeThreshold) / (fastSlopeThreshold - mildSlopeThreshold)
            return fastLockTimeout + (base - fastLockTimeout) * t
        }
    }

    /// 方案 A：信号是否处于接近窗口（有效信号进入 [threshold-window, threshold)）
    static func isNearThreshold(_ effectiveRSSI: Double, threshold: Double) -> Bool {
        effectiveRSSI >= threshold - proximityPollWindow && effectiveRSSI < threshold
    }

    // MARK: - 锁冷静期

    /// 是否处于锁冷静期（距最近解锁/靠近 < gracePeriod）
    static func isWithinLockGracePeriod(lastUnlockTime: Date, gracePeriod: TimeInterval, now: Date) -> Bool {
        now.timeIntervalSince(lastUnlockTime) < gracePeriod
    }

    // MARK: - 靠近 / 离开判定

    /// 解析实际生效的锁定阈值（当 lockRSSI 处于禁用哨兵时回退到 unlockRSSI）
    static func resolvedLockThreshold(unlockRSSI: Int, lockRSSI: Int) -> Int {
        lockRSSI == lockDisabled ? unlockRSSI : lockRSSI
    }

    /// 双阈值迟滞判定：靠近（有效信号 ≥ 解锁阈值）与离开（有效信号 < 锁定阈值）之间为保持区。
    /// 判定统一基于 effectiveRSSI（与锁计时器同源），避免原始 RSSI 尖峰导致振荡。
    static func checkProximity(effectiveRSSI: Double, unlockRSSI: Int, lockRSSI: Int) -> ProximityDecision {
        let unlockThreshold = unlockRSSI == unlockDisabled ? lockRSSI : unlockRSSI
        let lockThreshold = resolvedLockThreshold(unlockRSSI: unlockRSSI, lockRSSI: lockRSSI)
        return ProximityDecision(
            unlockThreshold: unlockThreshold,
            lockThreshold: lockThreshold,
            isClose: effectiveRSSI >= Double(unlockThreshold),
            isAway: effectiveRSSI < Double(lockThreshold)
        )
    }

    @discardableResult
    static func checkProximity(rssi: Double, effectiveRSSI: Double, unlockRSSI: Int, lockRSSI: Int) -> ProximityDecision {
        checkProximity(effectiveRSSI: effectiveRSSI, unlockRSSI: unlockRSSI, lockRSSI: lockRSSI)
    }
}
