import Foundation

/// 写入文件诊断日志（不依赖 os.Logger，debug 级别不会被过滤）
func logDebug(component: String, _ message: String) {
    DebugLog.log(component: component, message)
}

enum DebugLog {
    static var path: String { logFileURL.path }

    /// 测试覆盖：非 nil 时写该目录，避免污染用户真实日志
    nonisolated(unsafe) static var testLogDirectory: URL?
    /// 单文件滚动上限（测试可调小）
    nonisolated(unsafe) static var maxFileSize: UInt64 = LogRotator.defaultMaxBytes

    static var logDirectory: URL {
        if let testDir = testLogDirectory { return testDir }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/FUnlock")
    }

    static var logFileURL: URL {
        logDirectory.appendingPathComponent("debug.log")
    }

    private static let queue = DispatchQueue(label: "com.funlock.debugLog")
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(component: String, _ message: String) {
        // 入队前捕获路径与阈值，避免后续配置变更影响已排队的写入
        let url = logFileURL
        let maxSize = maxFileSize
        queue.async {
            let ts = dateFormatter.string(from: Date())
            let line = "[\(ts)] [\(component)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

            // 滚动：在串行队列内执行，天然与写入互斥
            LogRotator.rotateIfNeeded(url: url, maxBytes: maxSize)

            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        }
    }

    /// 同步刷盘（关键路径崩溃前调用）
    static func flush() {
        queue.sync {}
    }
}
