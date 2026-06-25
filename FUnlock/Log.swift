import os

enum Log {
    static let sm  = Logger(subsystem: "com.funlock.app", category: "StateMachine")
    static let ble = Logger(subsystem: "com.funlock.app", category: "BLE")
    static let dev = Logger(subsystem: "com.funlock.app", category: "Device")
}
