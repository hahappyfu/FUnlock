// TelemetryLogger.swift
// 形子模式数据采集：记录解锁/锁屏/异常事件，落盘 CSV 供后续智能调参

import Foundation

/// 形子模式遥测事件类型
enum TelemetryEvent: String {
    case autoUnlock = "auto_unlock"
    case autoLock = "auto_lock"
    case abnormalAlert = "abnormal_alert"
}

/// 单条遥测记录
struct TelemetryRecord {
    let timestamp: Date
    let eventType: TelemetryEvent
    let deviceModel: String?
    let rawRSSI: Int
    let kalmanRSSI: Double
    let effectiveRSSI: Double
    let slope: Double
    let isAnomalous: Bool
    let result: String
    let durationMs: Double?
}

/// 形子模式遥测日志单例
/// 监听 FUnManager 的真实动作，异步追加写入 CSV 文件
final class TelemetryLogger {
    static let shared = TelemetryLogger()
    private init() {
        ensureDirectory()
    }

    // MARK: - 测试支持（仅 @testable import 可见）

    /// 测试用日志目录（nil = 使用真实路径）
    var testLogDirectory: URL?
    /// 测试用日志文件（自动从 testLogDirectory 推导，未设置时回退到真实路径）
    var testLogFile: URL {
        if let testDir = testLogDirectory {
            return testDir.appendingPathComponent("shadow_telemetry.csv")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/FUnlock/shadow_telemetry.csv")
    }

    /// 同步写入（测试专用，绕过异步队列）
    func logSync(event: TelemetryEvent,
                 deviceModel: String?,
                 rawRSSI: Int,
                 kalmanRSSI: Double,
                 effectiveRSSI: Double,
                 slope: Double,
                 isAnomalous: Bool,
                 result: String = "N/A",
                 durationMs: Double? = nil) {
        let record = TelemetryRecord(
            timestamp: Date(),
            eventType: event,
            deviceModel: deviceModel,
            rawRSSI: rawRSSI,
            kalmanRSSI: kalmanRSSI,
            effectiveRSSI: effectiveRSSI,
            slope: slope,
            isAnomalous: isAnomalous,
            result: result,
            durationMs: durationMs
        )
        writeRecord(record)
    }

    // MARK: - 配置

    private let maxFileSize: UInt64 = 5 * 1024 * 1024  // 5MB 熔断
    private let queue = DispatchQueue(label: "com.funlock.telemetry", qos: .utility)

    // MARK: - 文件路径

    private var logDirectory: URL {
        if let testDir = testLogDirectory { return testDir }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Logs/FUnlock")
    }

    private var logFile: URL {
        testLogFile
    }

    // MARK: - 公开接口

    /// 记录一条遥测事件（线程安全，异步落盘）
    func log(event: TelemetryEvent,
             deviceModel: String?,
             rawRSSI: Int,
             kalmanRSSI: Double,
             effectiveRSSI: Double,
             slope: Double,
             isAnomalous: Bool,
             result: String = "N/A",
             durationMs: Double? = nil) {
        let record = TelemetryRecord(
            timestamp: Date(),
            eventType: event,
            deviceModel: deviceModel,
            rawRSSI: rawRSSI,
            kalmanRSSI: kalmanRSSI,
            effectiveRSSI: effectiveRSSI,
            slope: slope,
            isAnomalous: isAnomalous,
            result: result,
            durationMs: durationMs
        )
        queue.async { [weak self] in
            self?.writeRecord(record)
        }
    }

    // MARK: - 内部实现

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )
    }

    /// 同步写入单条记录（在 utility 队列上调用）
    private func writeRecord(_ record: TelemetryRecord) {
        // 容量熔断：超过 5MB 清空重写
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
           let size = attrs[.size] as? UInt64,
           size > maxFileSize {
            // 保留表头，清空数据
            try? FileManager.default.removeItem(at: logFile)
            writeHeaderIfNeeded()
        }

        // 首次写入：创建文件并写 CSV 表头
        writeHeaderIfNeeded()

        // 格式化数据行
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let ts = formatter.string(from: record.timestamp)
        let model = record.deviceModel ?? "unknown"
        let durationStr: String
        if let d = record.durationMs {
            durationStr = String(format: "%.2f", d)
        } else {
            durationStr = "N/A"
        }
        let line = "\(ts),\(record.eventType.rawValue),\(model),\(record.rawRSSI),\(String(format: "%.2f", record.kalmanRSSI)),\(String(format: "%.2f", record.effectiveRSSI)),\(String(format: "%.4f", record.slope)),\(record.isAnomalous),\(record.result),\(durationStr)\n"

        guard let data = line.data(using: .utf8) else { return }

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

    /// 写入 CSV 表头（仅当文件不存在时）
    private func writeHeaderIfNeeded() {
        guard !FileManager.default.fileExists(atPath: logFile.path) else { return }
        let header = "Timestamp,Event_Type,Device_Model,Raw_RSSI,Kalman_RSSI,Effective_RSSI,Slope,Is_Anomalous,Result,Duration_ms\n"
        try? header.data(using: .utf8)?.write(to: logFile)
    }
}
