// CoreBridge.swift
// FUnlockCore 纯逻辑包与主工程的桥接层：
// 1) 统一再导出，使既有源码与测试无需逐文件 import；
// 2) 收纳仅依赖 ConfigStore 的扩展（纯逻辑包禁止依赖 ConfigStore）。

@_exported import FUnlockCore

import Foundation

extension SignalHysteresisEngine {
    /// 读取偏移设置，越界/缺失时回退默认值（依赖 ConfigStore，故保留在主工程）
    static func offsetSetting(_ key: String, default dft: Int) -> Int {
        let value = ConfigStore.shared.object(forKey: key) as? Int ?? dft
        return clampOffset(value)
    }
}