import os

/// 日志分级约定：
/// - .debug  高频原始数据（RSSI、didDiscover、updateMonitored）
/// - .info   状态机流转与业务分支（SKIP、displaySleep/Wake）
/// - .error  异常与权限失败（CGEvent 失败、连接超时、DB prepare 失败）
/// - .fault  需人工介入的严重异常（暂未使用）
enum Log {
    static let sm  = Logger(subsystem: "com.funlock.app", category: "StateMachine")
    static let ble = Logger(subsystem: "com.funlock.app", category: "BLE")
    static let dev = Logger(subsystem: "com.funlock.app", category: "Device")
}
