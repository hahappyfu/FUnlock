import Foundation

/// Event logging (events.log) and user script execution (event script)
final class ScriptRunner {
    static let shared = ScriptRunner()
    private init() { nowProvider = { Date() } }

    // MARK: - Dedup & Extension Fields

    private var dedupWindow: TimeInterval = 3.0
    private var nowProvider: () -> Date
    private var lastLogTime: [String: Date] = [:]
    private let lock = NSLock()

    /// 便利初始化器，用于测试或自定义去重窗口
    init(dedupWindow: TimeInterval, nowProvider: @escaping () -> Date) {
        self.dedupWindow = dedupWindow
        self.nowProvider = nowProvider
    }

    private var now: Date { nowProvider() }

    /// 记录事件（带去重），返回 true 表示实际写入，false 表示在窗口内被跳过
    func logEventIfNeeded(_ event: String, rssi: Int? = nil, extraFields: [String: String] = [:]) -> Bool {
        let currentTime = now
        lock.lock()
        if let last = lastLogTime[event], currentTime.timeIntervalSince(last) < dedupWindow {
            lock.unlock()
            return false
        }
        lastLogTime[event] = currentTime
        lock.unlock()
        let line = buildEventLine(event, rssi: rssi, extraFields: extraFields)
        writeLine(line)
        return true
    }

    /// 构建日志行，格式：timestamp | event | RSSI: value [| key=value ...]
    func buildEventLine(_ event: String, rssi: Int?, extraFields: [String: String]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let rssiStr = rssi.map { String($0) } ?? "N/A"
        var line = "\(formatter.string(from: now)) | \(event) | RSSI: \(rssiStr)"
        let sorted = extraFields.sorted { $0.key < $1.key }
        for (key, value) in sorted {
            line += " | \(key)=\(value)"
        }
        return line + "\n"
    }

    private func writeLine(_ line: String) {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let logDir = dir.appendingPathComponent("FUnlock", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("events.log")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    // MARK: - Event Logging (Legacy)

    /// Append an event to ~/Library/Application Support/FUnlock/events.log
    func logEvent(_ event: String, rssi: Int? = nil) {
        let line = buildEventLine(event, rssi: rssi, extraFields: [:])
        writeLine(line)
    }

    // MARK: - User Script Execution

    /// Run the user's ~/Library/Application Scripts/FUnlock/event script with context args
    func runScript(_ arg: String, rssi: Int? = nil, deviceName: String? = nil, uuid: UUID? = nil) {
        guard let directory = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let file = directory.appendingPathComponent("event")
        let process = Process()
        process.executableURL = file
        var args = [arg]
        if let r = rssi { args.append(String(r)) }
        if let name = deviceName { args.append(name) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        args.append(formatter.string(from: Date()))
        process.arguments = args
        try? process.run()
    }
}
