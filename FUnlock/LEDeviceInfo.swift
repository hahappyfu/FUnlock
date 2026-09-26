// Resolve MAC address and device name of BLE device from SQLite database at /Library/Bluetooth introduced in Monterey.

import Foundation
import SQLite3

// 连接状态：connect() 首调初始化，之后仅读取。
// leDbLock 保护 inited / db_paired / db_other 三个全局句柄：BLE 回调线程与扫描线程
// 可能并发首次调用，无锁则会重复 sqlite3_open 覆盖句柄（旧句柄泄漏 + 半初始化状态可读）。
// nonisolated(unsafe) 在此成立的前提即为下列写读全部收在 leDbLock 临界区内。
private let leDbLock = NSLock()
nonisolated(unsafe) private var inited = false
nonisolated(unsafe) private var db_paired: OpaquePointer?
nonisolated(unsafe) private var db_other: OpaquePointer?

private func connect() {
    if inited { return }

    if sqlite3_open("/Library/Bluetooth/com.apple.MobileBluetooth.ledevices.paired.db", &db_paired) == SQLITE_OK {
        Log.dev.debug("paired.db open success")
    } else {
        db_paired = nil
    }

    if sqlite3_open("/Library/Bluetooth/com.apple.MobileBluetooth.ledevices.other.db", &db_other) == SQLITE_OK {
        Log.dev.debug("other.db open success")
    } else {
        db_other = nil
    }

    inited = true
}

struct LEDeviceInfo {
    var name: String?
    var macAddr: String?
}

private func getStringFromRow(stmt: OpaquePointer?, index: Int32) -> String? {
    if sqlite3_column_type(stmt, index) != SQLITE_TEXT { return nil }
    let s = String(cString: sqlite3_column_text(stmt, index))
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    if trimmed == "" { return nil }
    return trimmed
}

private func getPairedDeviceFromUUID(_ uuid: String) -> LEDeviceInfo? {
    guard let db = db_paired else { return nil }
    var stmt: OpaquePointer?
    if sqlite3_prepare(db, "SELECT Name, Address, ResolvedAddress FROM PairedDevices where Uuid=?", -1, &stmt, nil) != SQLITE_OK {
        Log.dev.error("failed to prepare PairedDevices: \(String(cString: sqlite3_errmsg(db)))")
        return nil
    }
    // prepare 成功后 stmt 已有效，defer 保证所有正常返回路径都释放 statement，避免泄漏
    defer { sqlite3_finalize(stmt) }
    _ = uuid.withCString { sqlite3_bind_text(stmt, 1, $0, -1, nil) }
    if sqlite3_step(stmt) != SQLITE_ROW {
        return nil
    }
    let name = getStringFromRow(stmt: stmt, index: 0)
    let address = getStringFromRow(stmt: stmt, index: 1)
    let resolvedAddress = getStringFromRow(stmt: stmt, index: 2)
    var mac: String? = nil
    if let addr = resolvedAddress ?? address {
        // It's like "Public XX:XX:..." or "Random XX:XX:...", so split by space and take the second one
        let parts = addr.split(separator: " ")
        if parts.count > 1 {
            mac = String(parts[1])
        }
    }
    return LEDeviceInfo(name: name, macAddr: mac)
}

private func getOtherDeviceFromUUID(_ uuid: String) -> LEDeviceInfo? {
    guard let db = db_other else { return nil }
    var stmt: OpaquePointer?
    if sqlite3_prepare(db, "SELECT Name, Address FROM OtherDevices where Uuid=?", -1, &stmt, nil) != SQLITE_OK {
        Log.dev.error("failed to prepare OtherDevices: \(String(cString: sqlite3_errmsg(db)))")
        return nil
    }
    // prepare 成功后 stmt 已有效，defer 保证所有正常返回路径都释放 statement，避免泄漏
    defer { sqlite3_finalize(stmt) }
    _ = uuid.withCString { sqlite3_bind_text(stmt, 1, $0, -1, nil) }
    if sqlite3_step(stmt) != SQLITE_ROW {
        return nil
    }
    let name = getStringFromRow(stmt: stmt, index: 0)
    let address = getStringFromRow(stmt: stmt, index: 1)
    var mac: String? = nil
    if let addr = address {
        // It's like "Public XX:XX:..." or "Random XX:XX:...", so split by space and take the second one
        let parts = addr.split(separator: " ")
        if parts.count > 1 {
            mac = String(parts[1])
        }
    }
    return LEDeviceInfo(name: name, macAddr: mac)
}

func getLEDeviceInfoFromUUID(_ uuid: String) -> LEDeviceInfo? {
    // NSLock 不可重入：在入口一次性加锁，覆盖 connect() 的句柄初始化与其后两次查询，
    // 保证「首调 open」与「读句柄」在并发下互斥
    leDbLock.lock()
    defer { leDbLock.unlock() }
    connect()
    return getPairedDeviceFromUUID(uuid) ?? getOtherDeviceFromUUID(uuid);
}
