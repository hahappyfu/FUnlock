import Foundation
import os

/// 日志 category：收敛原 component 标签与 os.Logger category
enum AppCategory {
    case sm, ble, unlock, lock, app

    /// debug.log 中的标签
    var tag: String {
        switch self {
        case .sm: "SM"; case .ble: "BLE"; case .unlock: "UNLOCK"
        case .lock: "LOCK"; case .app: "APP"
        }
    }
}

/// 统一日志门面：一次调用同时写 os.log 与 debug.log
/// - debug 高频原始数据（RSSI、didDiscover）
/// - info   状态机流转与业务分支（SKIP、displaySleep/Wake）
/// - error  异常与权限失败
/// - fault  需人工介入的严重异常
enum AppLog {
    private static func osLogger(for category: AppCategory) -> Logger {
        switch category {
        case .sm: Log.sm
        case .ble: Log.ble
        case .unlock, .lock: Log.sm   // UNLOCK/LOCK 映射到状态机 Logger，避免新建 subsystem category
        case .app: Log.dev
        }
    }

    /// key=value 拼接：nil 字段省略，含空白或非 ASCII 的 value 加双引号
    static func message(_ event: String, _ fields: [(String, String?)]) -> String {
        var parts = ["event=\(event)"]
        for (key, value) in fields {
            guard let value else { continue }
            let needsQuotes = value.contains(where: { $0.isWhitespace || !$0.isASCII })
            let quoted = needsQuotes ? "\"\(value)\"" : value
            parts.append("\(key)=\(quoted)")
        }
        return parts.joined(separator: " ")
    }

    static func debug(_ category: AppCategory, _ event: String, _ fields: [(String, String?)] = []) {
        log(category, event, fields, level: .debug)
    }
    static func info(_ category: AppCategory, _ event: String, _ fields: [(String, String?)] = []) {
        log(category, event, fields, level: .info)
    }
    static func error(_ category: AppCategory, _ event: String, _ fields: [(String, String?)] = []) {
        log(category, event, fields, level: .error)
    }
    static func fault(_ category: AppCategory, _ event: String, _ fields: [(String, String?)] = []) {
        log(category, event, fields, level: .fault)
    }

    private static func log(_ category: AppCategory, _ event: String,
                            _ fields: [(String, String?)], level: OSLogType) {
        let msg = message(event, fields)
        DebugLog.log(component: category.tag, msg)
        let logger = osLogger(for: category)
        switch level {
        case .debug: logger.debug("\(msg, privacy: .public)")
        case .info: logger.info("\(msg, privacy: .public)")
        case .error: logger.error("\(msg, privacy: .public)")
        case .fault: logger.fault("\(msg, privacy: .public)")
        default: logger.debug("\(msg, privacy: .public)")
        }
    }
}
