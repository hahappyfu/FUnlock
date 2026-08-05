import Foundation

func t(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

// MARK: - 时序埋点（限流 + 句柄缓存）

private let timingLock = NSLock()
private var timingFileHandle: FileHandle?
private var lastTimingWriteByType: [String: Date] = [:]

/// 时序埋点：按消息类型（首个空格前 token）限流，同类型 1 秒最多写 1 条；
/// 文件句柄缓存复用，避免高频开/关文件拖慢主线程。
/// 写入 /tmp/funlock_timing.log
func timingLog(_ msg: String) {
    timingLock.lock()
    defer { timingLock.unlock() }
    let now = Date()
    let type = msg.split(separator: " ").first.map(String.init) ?? msg
    if let last = lastTimingWriteByType[type], now.timeIntervalSince(last) < 1.0 {
        return
    }
    lastTimingWriteByType[type] = now
    let line = "[\(now.formatted(date: .omitted, time: .standard))] \(msg)\n"
    let url = URL(fileURLWithPath: "/tmp/funlock_timing.log")
    if timingFileHandle == nil {
        timingFileHandle = try? FileHandle(forWritingTo: url)
    }
    if let fh = timingFileHandle {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
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
