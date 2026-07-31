// FUnlock/FUnlockStateMachine.swift
import Foundation

actor FUnlockStateMachine {

    // MARK: - 状态定义

    enum State: Equatable, Hashable {
        case active              // 正常使用中
        case displayAsleep       // 屏幕息屏，但系统未休眠
        case preWaking           // 触发预备唤醒
        case readyToUnlock       // 屏幕已亮，等待信号达到阈值
        case unlocking           // 正在注入密码
        case cooldown            // 冷却防抖中
        case degraded            // 连续失败降级中
    }

    // MARK: - 核心属性

    private(set) var currentState: State = .active
    private var lastUnlockAttempt: Date = .distantPast
    private var consecutiveFailures: Int = 0
    private var failureCooldownDeadline: Date = .distantPast
    private var activeTask: Task<Void, Never>?

    // MARK: - 防抖配置

    private let unlockCooldown: TimeInterval = 5.0
    private let failureCooldown: TimeInterval = 10.0
    private let maxConsecutiveFailures: Int = 3

    /// 调用方可通过此属性查询当前是否处于失败冷却期
    var isInCooldown: Bool {
        Date() < failureCooldownDeadline
    }

    // MARK: - 状态转换

    func transition(to newState: State) {
        guard canTransition(from: currentState, to: newState) else {
            return
        }
        currentState = newState
    }

    private func canTransition(from: State, to: State) -> Bool {
        switch (from, to) {
        case (.active, .displayAsleep),
             (.displayAsleep, .preWaking),
             (.preWaking, .readyToUnlock),
             (.readyToUnlock, .unlocking),
             (.unlocking, .active),
             (.unlocking, .cooldown),
             (.cooldown, .active),
             (_, .degraded),
             (_, .active):  // 任意状态可以切回 active（用户干预）
            return true
        default:
            return false
        }
    }

    // MARK: - 解锁尝试

    func attemptUnlock() -> Bool {
        let now = Date()

        // 降级短路：已进入降级状态，拒绝任何解锁尝试
        guard currentState != .degraded else {
            return false
        }

        // 防抖检查
        guard now.timeIntervalSince(lastUnlockAttempt) > unlockCooldown else {
            return false
        }

        // 降级检查
        guard consecutiveFailures < maxConsecutiveFailures else {
            transition(to: .degraded)
            return false
        }

        lastUnlockAttempt = now
        transition(to: .unlocking)
        return true
    }

    // MARK: - 失败处理

    func handleUnlockFailure() {
        consecutiveFailures += 1
        failureCooldownDeadline = Date().addingTimeInterval(failureCooldown)

        if consecutiveFailures >= maxConsecutiveFailures {
            transition(to: .degraded)
        } else {
            transition(to: .cooldown)
        }
    }

    // MARK: - 成功处理

    func handleUnlockSuccess() {
        consecutiveFailures = 0
        lastUnlockAttempt = Date()
        transition(to: .active)
    }

    // MARK: - 重置状态

    func resetToActive() {
        currentState = .active
        consecutiveFailures = 0
        activeTask?.cancel()
        activeTask = nil
    }

    // MARK: - 任务管理

    func setActiveTask(_ task: Task<Void, Never>?) {
        activeTask?.cancel()
        activeTask = task
    }

    func cancelActiveTask() {
        activeTask?.cancel()
        activeTask = nil
    }
}
