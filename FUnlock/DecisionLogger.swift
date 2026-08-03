// DecisionLogger.swift
// 决策记录器：把「为什么没解锁 / 为什么锁屏」变成结构化决策事件，
// 内存环形缓冲 + JSON Lines 持久化，供「诊断」Tab 与后续数据驱动调参使用。

import Foundation
import Combine

// MARK: - 事件模型

enum DecisionCategory: String, Codable, CaseIterable {
    case unlock, lock, system, user
}

enum DecisionOutcome: String, Codable {
    case success, skipped, failed, blocked, info
}

/// 结构化决策原因（解锁跳过 / 锁屏跳过 / 结果 / 系统事件）
enum DecisionReason: String, Codable, CaseIterable {
    // 解锁跳过
    case noPresence
    case signalBelowThreshold
    case unlockCooldownActive
    case lockBufferActive
    case manualLockActive
    case wifiPaused
    case disabled
    case unlockDisabled
    case stateMachineBlocked
    case axRevoked
    case noPassword
    case keychainColdBoot
    case notSecureForInjection
    case displaySleeping
    case systemNotReady
    case wakeWithoutUnlocking
    case recentlyUnlocked
    case screenNotLocked
    // 锁屏跳过
    case inputActive
    case gracePeriod
    case signalBelowLockThreshold
    // 结果
    case unlockSuccess
    case unlockFailed
    case unlockTimeout
    case passwordMismatch
    case lockedAway
    case lockedLost
    // 系统 / 用户
    case displaySleep
    case displayWake
    case systemSleep
    case systemWake
    case userUnlocked
    case userLocked
}

/// 操作提示：由 reason 派生，UI 据此渲染按钮
enum ActionHint: Equatable {
    case lowerUnlockThreshold
    case openAccessibilitySettings
    case reEnterPassword
    case goToTab(String)   // MenuTab.rawValue
    case resetStateMachine

    var labelKey: String {
        switch self {
        case .lowerUnlockThreshold: return "action_lower_unlock_threshold"
        case .openAccessibilitySettings: return "action_open_accessibility"
        case .reEnterPassword: return "action_reenter_password"
        case .goToTab: return "action_go_to_settings"
        case .resetStateMachine: return "action_reset_state_machine"
        }
    }
}

struct DecisionEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let timestamp: Date
    let category: DecisionCategory
    let outcome: DecisionOutcome
    let reason: DecisionReason?
    let rssi: Int?
    let device: String?
    let screen: String?
    let detail: String

    init(id: UUID = UUID(), timestamp: Date, category: DecisionCategory,
         outcome: DecisionOutcome, reason: DecisionReason?, rssi: Int?,
         device: String?, screen: String?, detail: String = "") {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.outcome = outcome
        self.reason = reason
        self.rssi = rssi
        self.device = device
        self.screen = screen
        self.detail = detail
    }
}

// MARK: - 记录器

@MainActor
final class DecisionLogger: ObservableObject {
    static let shared = DecisionLogger()

    /// 内存环形缓冲容量
    static let capacity = 500
    /// 同因合并窗口：连续相同 (category, outcome, reason) 在该秒数内只更新时间戳
    var coalescingWindow: TimeInterval = 3.0
    /// 持久化文件轮转上限
    var maxFileSize: UInt64 = 1 * 1024 * 1024
    /// 测试覆盖：非 nil 时读写该目录，避免污染用户真实决策日志
    var testLogDirectory: URL?

    @Published private(set) var events: [DecisionEvent] = []

    private var ring = RingBuffer<DecisionEvent>(capacity: DecisionLogger.capacity)
    private let queue = DispatchQueue(label: "com.funlock.decisions", qos: .utility)
    private var nowProvider: () -> Date = { Date() }

    init(testLogDirectory: URL? = nil, nowProvider: @escaping () -> Date = { Date() }) {
        self.testLogDirectory = testLogDirectory
        self.nowProvider = nowProvider
    }

    // MARK: - 路径

    var logDirectory: URL {
        if let testDir = testLogDirectory { return testDir }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/FUnlock")
    }

    var logFile: URL {
        logDirectory.appendingPathComponent("decisions.jsonl")
    }

    // MARK: - 记录

    func record(category: DecisionCategory,
                outcome: DecisionOutcome,
                reason: DecisionReason?,
                rssi: Int? = nil,
                device: String? = nil,
                screen: String? = nil,
                detail: String = "") {
        let now = nowProvider()

        // 同因合并：连续相同 (category, outcome, reason) 且间隔 < 窗口 → 只更新时间戳
        if var last = events.last,
           last.category == category,
           last.outcome == outcome,
           last.reason == reason,
           now.timeIntervalSince(last.timestamp) < coalescingWindow {
            // 创建新的 DecisionEvent 替代旧的，保持值类型不可变性
            let updatedEvent = DecisionEvent(
                id: last.id,
                timestamp: now,
                category: last.category,
                outcome: last.outcome,
                reason: last.reason,
                rssi: rssi ?? last.rssi,
                device: device ?? last.device,
                screen: screen ?? last.screen,
                detail: detail
            )
            events[events.count - 1] = updatedEvent
            return
        }

        let event = DecisionEvent(timestamp: now, category: category, outcome: outcome,
                                  reason: reason, rssi: rssi, device: device,
                                  screen: screen, detail: detail)
        ring.append(event)
        events = ring.toArray()

        let latest = events
        let file = logFile
        let maxSize = maxFileSize
        queue.async {
            Self.write(event, latest: latest, to: file, maxFileSize: maxSize)
        }
    }

    // MARK: - 历史加载

    /// 首次打开「诊断」Tab 时读取文件尾部灌入内存（events 非空时幂等跳过）
    func loadHistory() {
        guard events.isEmpty else { return }
        let file = logFile
        queue.async {
            let loaded = Self.readTail(from: file, max: DecisionLogger.capacity)
            Task { @MainActor [weak self] in
                guard let self, self.events.isEmpty else { return }
                for e in loaded { self.ring.append(e) }
                self.events = self.ring.toArray()
            }
        }
    }

    // MARK: - 清空

    func clear() {
        ring.clear()
        events = []
        let file = logFile
        queue.async {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// 等待持久化队列排空（测试专用）
    func flushSync() {
        queue.sync {}
    }

    // MARK: - 持久化（静态实现，仅处理值类型，无 self 捕获）

    private static func write(_ event: DecisionEvent, latest: [DecisionEvent], to url: URL, maxFileSize: UInt64) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        appendLine(event, to: url)

        // 轮转：超过上限 → 用当前缓冲的最新事件重写文件
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64,
           size > maxFileSize {
            try? FileManager.default.removeItem(at: url)
            for e in latest {
                appendLine(e, to: url)
            }
        }
    }

    private static func appendLine(_ event: DecisionEvent, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: url)
        }
    }

    /// 读取文件尾部最多 max 条（按时间顺序返回）
    static func readTail(from url: URL, max: Int) -> [DecisionEvent] {
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var result: [DecisionEvent] = []
        for line in content.components(separatedBy: .newlines).suffix(max) {
            guard let lineData = line.data(using: .utf8),
                  let event = try? decoder.decode(DecisionEvent.self, from: lineData) else { continue }
            result.append(event)
        }
        return result
    }
}

// MARK: - 原因 → 文案 / 操作映射

extension DecisionReason {
    /// 本地化 key（各语言见 Base.lproj / zh-Hans.lproj）
    var titleKey: String {
        switch self {
        case .noPresence: return "reason_no_presence"
        case .signalBelowThreshold: return "reason_signal_below_threshold"
        case .unlockCooldownActive: return "reason_unlock_cooldown"
        case .lockBufferActive: return "reason_lock_buffer"
        case .manualLockActive: return "reason_manual_lock"
        case .wifiPaused: return "reason_wifi_paused"
        case .disabled: return "reason_disabled"
        case .unlockDisabled: return "reason_unlock_disabled"
        case .stateMachineBlocked: return "reason_state_machine"
        case .axRevoked: return "reason_ax_revoked"
        case .noPassword: return "reason_no_password"
        case .keychainColdBoot: return "reason_keychain_cold_boot"
        case .notSecureForInjection: return "reason_not_secure"
        case .displaySleeping: return "reason_display_sleeping"
        case .systemNotReady: return "reason_system_not_ready"
        case .wakeWithoutUnlocking: return "reason_wake_without_unlock"
        case .recentlyUnlocked: return "reason_recently_unlocked"
        case .screenNotLocked: return "reason_screen_not_locked"
        case .inputActive: return "reason_input_active"
        case .gracePeriod: return "reason_grace_period"
        case .signalBelowLockThreshold: return "reason_signal_below_lock_threshold"
        case .unlockSuccess: return "reason_unlock_success"
        case .unlockFailed: return "reason_unlock_failed"
        case .unlockTimeout: return "reason_unlock_timeout"
        case .passwordMismatch: return "reason_password_mismatch"
        case .lockedAway: return "reason_locked_away"
        case .lockedLost: return "reason_locked_lost"
        case .displaySleep: return "reason_display_sleep"
        case .displayWake: return "reason_display_wake"
        case .systemSleep: return "reason_system_sleep"
        case .systemWake: return "reason_system_wake"
        case .userUnlocked: return "reason_user_unlocked"
        case .userLocked: return "reason_user_locked"
        }
    }

    /// 操作提示（无操作时为 nil）
    var action: ActionHint? {
        switch self {
        case .signalBelowThreshold: return .lowerUnlockThreshold
        case .manualLockActive: return .goToTab("lock")
        case .wifiPaused: return .goToTab("network")
        case .disabled: return .goToTab("basic")
        case .unlockDisabled: return .goToTab("unlock")
        case .stateMachineBlocked: return .resetStateMachine
        case .axRevoked: return .openAccessibilitySettings
        case .noPassword: return .reEnterPassword
        case .keychainColdBoot: return .reEnterPassword
        case .unlockFailed: return .reEnterPassword
        case .passwordMismatch: return .reEnterPassword
        case .signalBelowLockThreshold: return .goToTab("unlock")
        default: return nil
        }
    }
}
