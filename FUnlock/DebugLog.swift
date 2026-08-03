import Foundation

/// 写入文件诊断日志（不依赖 os.Logger，debug 级别不会被过滤）
func logDebug(component: String, _ message: String) {
    let ts = DebugLog.dateFormatter.string(from: Date())
    let line = "[\(ts)] [\(component)] \(message)\n"
    if let data = line.data(using: .utf8) {
        let fh = FileHandle(forWritingAtPath: DebugLog.path)
        fh?.seekToEndOfFile()
        fh?.write(data)
        fh?.closeFile()
    }
}

enum DebugLog {
    static let path = "/tmp/funlock_debug.log"
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
