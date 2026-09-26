import Foundation
import CoreBluetooth

/// BLE 扫描发现的设备实体（CoreBluetooth 底层引用类型）。
/// 跨并发域传递请改用不可变纯值快照 `DeviceSnapshot`（见 `toSnapshot(isMonitored:)`）。
class Device: NSObject {
    let uuid: UUID
    var peripheral : CBPeripheral?
    var manufacture : String?
    var model : String?
    var advData: Data?
    var rssi: Int = 0
    var scanTimer: Timer?
    var macAddr: String?
    var blName: String?

    override var description: String {
        get {
            if let name = blName {
                if name != "iPhone" && name != "iPad" {
                    return name
                }
            }
            if let manu = manufacture {
                if let mod = model {
                    if manu == "Apple Inc." && appleDeviceNames[mod] != nil {
                        return appleDeviceNames[mod]!
                    }
                    return String(format: "%@/%@", manu, mod)
                } else {
                    return manu
                }
            }
            if let name = peripheral?.name {
                if name.trimmingCharacters(in: .whitespaces).count != 0 {
                    return name
                }
            }
            if let mod = model {
                return mod
            }
            // iBeacon
            if let adv = advData {
                if adv.count >= 25 {
                    var iBeaconPrefix : [uint16] = [0x004c, 0x01502]
                    if adv[0...3] == Data(bytes: &iBeaconPrefix, count: 4) {
                        let major = uint16(adv[20]) << 8 | uint16(adv[21])
                        let minor = uint16(adv[22]) << 8 | uint16(adv[23])
                        let tx = Int8(bitPattern: adv[24])
                        let distance = pow(10, Double(Int(tx) - rssi)/20.0)
                        let d = String(format:"%.1f", distance)
                        return "iBeacon [\(major), \(minor)] \(d)m"
                    }
                }
            }
            if let name = blName {
                return name
            }
            if let mac = macAddr {
                return mac
            }
            return uuid.description
        }
    }

    init(uuid _uuid: UUID) {
        uuid = _uuid
    }
}

extension Device {
    /// 生成不可变纯值快照，用于跨线程 / 跨 Actor 传递与 UI 消费。
    /// - Parameter isMonitored: 是否处于监控列表，由持有监控状态的一端提供。
    func toSnapshot(isMonitored: Bool) -> DeviceSnapshot {
        DeviceSnapshot(
            uuid: uuid,
            name: description,
            rssi: rssi,
            manufacture: manufacture,
            model: model,
            macAddr: macAddr,
            isMonitored: isMonitored
        )
    }
}
