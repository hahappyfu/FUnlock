import Foundation
import SwiftUI

func t(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

// MARK: - 日志滚动（防无界增长）

/// 日志文件滚动：单文件超过上限时归档为 `<filename>.old`（覆盖旧备份）并新建空文件，
/// 保证长期运行下日志目录磁盘占用有界。
///
/// 静默降级：任何一步失败都不抛错、不中断业务，返回 false 让调用方继续向原文件追加。
/// 调用方需在模块自身的锁 / 串行队列内调用，保证轮转与写入互斥。
enum LogRotator {
    /// 默认单文件上限 5MB
    static let defaultMaxBytes: UInt64 = 5 * 1024 * 1024

    /// 若文件大小严格超过 maxBytes：先删旧备份，再把当前文件重命名为 `<filename>.old`，并新建空文件继续写入。
    @discardableResult
    static func rotateIfNeeded(url: URL, maxBytes: UInt64 = LogRotator.defaultMaxBytes) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let size = attrs[.size] as? UInt64,
              size > maxBytes else { return false }

        let backup = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".old")
        try? fm.removeItem(at: backup)
        do {
            try fm.moveItem(at: url, to: backup)
        } catch {
            // 归档失败：保留原文件继续追加，绝不影响业务
            return false
        }
        fm.createFile(atPath: url.path, contents: nil)
        return true
    }
}

// MARK: - 时序埋点（按事件限流 + 异步落盘）

private let timingLock = NSLock()
/// 时序日志专用串行队列：文件创建/滚动/写入全部在此执行，不阻塞主线程。
private let timingLogQueue = DispatchQueue(label: "com.funlock.timingLog", qos: .utility)
/// 句柄仅在 timingLogQueue 上访问；限流状态由 timingLock 保护
nonisolated(unsafe) private var timingFileHandle: FileHandle?
nonisolated(unsafe) private var lastTimingWriteByType: [String: Date] = [:]
/// 测试覆盖：非 nil 时写该目录，避免污染真实日志
nonisolated(unsafe) private var timingLogTestDirectory: URL?
/// 单文件滚动上限（测试可调小）
nonisolated(unsafe) private var timingLogMaxBytes: UInt64 = LogRotator.defaultMaxBytes

var timingLogDirectory: URL {
    if let testDir = timingLogTestDirectory { return testDir }
    // 测试进程自动隔离：绝不写用户生产日志
    if NSClassFromString("XCTestCase") != nil {
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("FUnlock-TestLogs", isDirectory: true)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent("Library/Logs/FUnlock")
}

/// timing.log 完整路径（诊断导出引用单源，测试目录重定向时自动跟随）
var timingLogFileURL: URL {
    timingLogDirectory.appendingPathComponent("timing.log")
}

private let timingDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

/// 限流 key：优先提取 `event=<name>`，否则取首个空白前 token。
/// 用事件名而非完整消息，避免动态 RSSI 等字段让限流失效。
func timingLogEventKey(_ msg: String) -> String {
    if let range = msg.range(of: "event=") {
        let token = msg[range.upperBound...].prefix { !$0.isWhitespace }
        if !token.isEmpty { return String(token) }
    }
    return String(msg.prefix { !$0.isWhitespace })
}

/// 时序埋点：按事件名限流（同事件 1 秒最多 1 条），文件 I/O 异步到专用串行队列。
func timingLog(_ msg: String) {
    let now = Date()
    let key = timingLogEventKey(msg)
    timingLock.lock()
    if let last = lastTimingWriteByType[key], now.timeIntervalSince(last) < 1.0 {
        timingLock.unlock()
        return
    }
    lastTimingWriteByType[key] = now
    // 有界字典：超过 256 条时清理 60s 前的旧事件，防止长期运行无限增长
    if lastTimingWriteByType.count > 256 {
        let cutoff = now.addingTimeInterval(-60)
        lastTimingWriteByType = lastTimingWriteByType.filter { $0.value >= cutoff }
    }
    // DateFormatter 非线程安全：在锁内完成格式化
    let line = "[\(timingDateFormatter.string(from: now))] \(msg)\n"
    timingLock.unlock()

    let url = timingLogFileURL
    let directory = timingLogDirectory
    let maxBytes = timingLogMaxBytes
    timingLogQueue.async {
        writeTimingLine(line, url: url, directory: directory, maxBytes: maxBytes)
    }
}

/// 仅在 timingLogQueue 上调用（句柄独占）。
private func writeTimingLine(_ line: String, url: URL, directory: URL, maxBytes: UInt64) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    // 滚动：超限则归档为 .old 并新建空文件；缓存句柄随之失效
    if LogRotator.rotateIfNeeded(url: url, maxBytes: maxBytes) {
        timingFileHandle?.closeFile()
        timingFileHandle = nil
    }

    if timingFileHandle == nil || !FileManager.default.fileExists(atPath: url.path) {
        timingFileHandle = try? FileHandle(forWritingTo: url)
    }
    if let data = line.data(using: .utf8), let fh = timingFileHandle {
        fh.seekToEndOfFile()
        fh.write(data)
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
        timingFileHandle = try? FileHandle(forWritingTo: url)
    }
}

/// 测试支持：同步等待时序日志队列排空，便于断言落盘结果。
func flushTimingLogForTesting() {
    timingLogQueue.sync {}
}

/// 测试支持：重定向时序日志目录 / 调整滚动阈值（nil = 恢复真实路径），并清空句柄缓存与限流状态
func configureTimingLogForTesting(directory: URL?, maxBytes: UInt64 = LogRotator.defaultMaxBytes) {
    timingLogQueue.sync {
        timingFileHandle?.closeFile()
        timingFileHandle = nil
        timingLock.lock()
        timingLogTestDirectory = directory
        timingLogMaxBytes = maxBytes
        lastTimingWriteByType.removeAll()
        timingLock.unlock()
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
