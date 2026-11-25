import Foundation
import CoreGraphics

/// L0 有界在场保活适配器：将 `EngineReducer.evaluateKeepAlive` 的纯函数决策落地到
/// `lowlevel.c` 的 `PreventUserIdleDisplaySleep` IOPMAssertion，保证空闲 >= 15 分钟
/// 或锁屏/休眠时必然释放，避免永久阻止显示睡眠。
@MainActor
final class PowerKeepAliveAdapter {
    private let renewHandler: () -> Void
    private let releaseHandler: () -> Void
    private(set) var isAssertionHeld = false

    init(
        renewHandler: @escaping () -> Void = { funlock_renewPresenceKeepAlive() },
        releaseHandler: @escaping () -> Void = { funlock_releasePresenceKeepAlive() }
    ) {
        self.renewHandler = renewHandler
        self.releaseHandler = releaseHandler
    }

    /// 读取全系统最近一次键鼠输入距今的空闲秒数（异常或测试进程退回 0）。
    static func currentUserIdleSeconds() -> TimeInterval {
        if NSClassFromString("XCTestCase") != nil {
            return 0
        }
        guard let anyEvent = CGEventType(rawValue: UInt32.max) else { return 0 }
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
        return seconds.isFinite && seconds >= 0 ? seconds : 0
    }

    /// 基于纯函数 `EngineReducer.evaluateKeepAlive` 评估并执行保活/释放副作用。
    @discardableResult
    func evaluate(
        state: inout EngineState,
        idleSeconds: TimeInterval,
        config: EngineConfig,
        now: Date = Date(),
        forceRenew: Bool = false
    ) -> Bool {
        var effects: [EngineEffect] = []
        EngineReducer.evaluateKeepAlive(
            state: &state,
            idleSeconds: idleSeconds,
            config: config,
            now: now,
            effects: &effects,
            forceRenew: forceRenew
        )
        for effect in effects {
            if case .setKeepAlive(let active) = effect {
                if active {
                    isAssertionHeld = true
                    renewHandler()
                } else {
                    isAssertionHeld = false
                    releaseHandler()
                }
            }
        }
        return state.keepAliveActive
    }

    func releaseAll(state: inout EngineState) {
        state.keepAliveActive = false
        state.deadlines.cancel(.keepAliveRenew)
        if isAssertionHeld {
            isAssertionHeld = false
            releaseHandler()
        }
    }

    func releaseAll() {
        if isAssertionHeld {
            isAssertionHeld = false
            releaseHandler()
        }
    }
}
