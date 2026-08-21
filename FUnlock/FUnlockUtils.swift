import Foundation
import SwiftUI

func t(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

// MARK: - 时序埋点（限流 + 句柄缓存）

private let timingLock = NSLock()
private var timingFileHandle: FileHandle?
private var lastTimingWriteByType: [String: Date] = [:]

private var timingLogDirectory: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent("Library/Logs/FUnlock")
}

private var timingLogFileURL: URL {
    timingLogDirectory.appendingPathComponent("timing.log")
}

private let timingDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

/// 时序埋点：按完整消息限流，同文案 1 秒最多写 1 条；
/// 文件句柄缓存复用，避免高频开/关文件拖慢主线程。
/// 写入 ~/Library/Logs/FUnlock/timing.log
func timingLog(_ msg: String) {
    timingLock.lock()
    defer { timingLock.unlock() }
    let now = Date()
    if let last = lastTimingWriteByType[msg], now.timeIntervalSince(last) < 1.0 {
        return
    }
    lastTimingWriteByType[msg] = now
    let ts = timingDateFormatter.string(from: now)
    let line = "[\(ts)] \(msg)\n"
    let url = timingLogFileURL
    try? FileManager.default.createDirectory(at: timingLogDirectory, withIntermediateDirectories: true)
    if timingFileHandle == nil || !FileManager.default.fileExists(atPath: url.path) {
        timingFileHandle = try? FileHandle(forWritingTo: url)
    }
    if let fh = timingFileHandle {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
        timingFileHandle = try? FileHandle(forWritingTo: url)
    }
}

/// 按设备名推断设备图标（Apple Watch / AirPods / iPad / Mac / iPhone 等）
func deviceIconName(for deviceName: String) -> String {
    if deviceName.contains("Watch") { return "applewatch" }
    if deviceName.contains("AirPods") { return "airpods" }
    if deviceName.contains("iPad") { return "ipad" }
    if deviceName.contains("MacBook") || deviceName.contains("Mac") { return "laptopcomputer" }
    if deviceName.contains("iPhone") { return "iphone" }
    return "iphone"
}

// MARK: - 决策事件 UI 映射

extension DecisionEvent {
    /// 事件图标与颜色（诊断页/统计页共享）
    var icon: (String, Color) {
        switch (category, outcome) {
        case (.unlock, .success): return ("lock.open.fill", .green)
        case (.unlock, .failed), (.unlock, .blocked): return ("exclamationmark.triangle.fill", .red)
        case (.unlock, .skipped), (.unlock, .info): return ("lock.open", .secondary)
        case (.lock, .success): return ("lock.fill", .orange)
        case (.lock, _): return ("lock", .secondary)
        case (.system, _): return ("power", .blue)
        case (.user, _): return ("person.fill", .teal)
        }
    }

    /// 屏幕状态 → 本地化 key（静态，便于测试）
    static func screenLabel(_ screen: String?) -> String? {
        guard let screen else { return nil }
        switch screen {
        case "unlocked": return "screen_unlocked"
        case "locked(away)": return "screen_locked_away"
        case "locked(manual)": return "screen_locked_manual"
        case "locked(lost)": return "screen_locked_lost"
        case "locked(timeout)": return "screen_locked_timeout"
        case "displaySleeping": return "screen_display_sleeping"
        case "screensaver": return "screen_screensaver"
        default: return screen
        }
    }
}
