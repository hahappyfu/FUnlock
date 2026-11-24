import XCTest
@testable import FUnlock

/// 生产域快照哨兵：被测组件（FUnManager / SignalHysteresisEngine / ProfileManager）硬编码
/// 读写 ConfigStore.shared（生产 suite 域），测试侧无法注入替代 store，只能写后恢复。
/// init 时快照 key 原始状态，restore() 精确还原（原值回写 / 原不存在则删除），
/// 注册为 teardown block 后断言失败也会执行，保证测试对生产配置域零净影响。
/// @unchecked Sendable：快照 init 后不可变，UserDefaults 自身线程安全。
struct ConfigKeySnapshot: @unchecked Sendable {
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

// MARK: - 会话锁态测试开关

/// 测试注入：模拟系统会话锁定/解锁（CGSession + 屏保 provider）。
func setSessionLockedForTesting(_ locked: Bool) {
    SystemInteractionService.sessionDictProvider = { ["CGSSessionScreenIsLocked": locked ? 1 : 0] }
    SystemInteractionService.screensaverRunningProvider = { false }
}

func resetSessionProvidersForTesting() {
    SystemInteractionService.sessionDictProvider = nil
    SystemInteractionService.screensaverRunningProvider = nil
}

// MARK: - 测试 bundle 守卫

/// 测试 bundle 主类（FUnlockTests/Info.plist NSPrincipalClass）：
/// 每个用例开始前确保 lockActionOverride 已安装，任何新增测试都不会真实锁屏。
@objc(TestBundleGuard)
final class TestBundleGuard: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        SystemInteractionService.lockActionOverride = {}
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        if SystemInteractionService.lockActionOverride == nil {
            SystemInteractionService.lockActionOverride = {}
        }
    }
}

