import Foundation

/// 设备不可变纯值快照：跨线程 / 跨 Actor 传递与 UI 消费的唯一形态。
/// 由 `Device.toSnapshot(isMonitored:)` 生成，替代引用类型跨并发域共享。
public struct DeviceSnapshot: Sendable, Identifiable, Hashable, Equatable {
    public let id: UUID
    public let uuid: UUID
    public let name: String
    public let rssi: Int
    public let manufacture: String?
    public let model: String?
    /// LE 厂商解析出的 MAC 地址（若可得），供设备列表副标题展示
    public let macAddr: String?
    public let isMonitored: Bool

    public init(id: UUID, uuid: UUID, name: String, rssi: Int, manufacture: String? = nil, model: String? = nil, macAddr: String? = nil, isMonitored: Bool = false) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.rssi = rssi
        self.manufacture = manufacture
        self.model = model
        self.macAddr = macAddr
        self.isMonitored = isMonitored
    }
}
