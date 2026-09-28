import XCTest
@testable import FUnlock

/// 生产域快照哨兵：被测组件（FUnManager / SignalHysteresisEngine / ProfileManager）硬编码
/// 读写 ConfigStore.shared（生产 suite 域），测试侧无法注入替代 store，只能写后恢复。
/// init 时快照 key 原始状态，restore() 精确还原（原值回写 / 原不存在则删除），
/// 注册为 teardown block 后断言失败也会执行，保证测试对生产配置域零净影响。
struct ConfigKeySnapshot {
    private let defaults: UserDefaults
    private let originals: [(key: String, value: Any?)]

    init(keys: [String]) {
        let defaults = ConfigStore.shared.defaults
        originals = keys.map { ($0, defaults.object(forKey: $0)) }
        self.defaults = defaults
    }

    func restore() {
        for (key, value) in originals {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}

