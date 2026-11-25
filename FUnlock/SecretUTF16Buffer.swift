import Foundation

/// 托管机密密码 UTF-16 编码单元缓冲区。
/// 全程不构造 Swift `String` / `NSString` 实例，释放或退出前通过 C `memset_s`（`funlock_secureZero`）
/// 强制零覆写密码字节，缩短或消除敏感数据在堆上的可控驻留窗口。
final class SecretUTF16Buffer {
    private var pointer: UnsafeMutablePointer<UniChar>?
    private(set) var count: Int
    private(set) var isWiped: Bool = false

    /// 将 UTF-8 `Data` 直接解码为 UTF-16 编码单元并立即清零源 `Data`。
    init?(utf8Data: inout Data) {
        defer {
            if !utf8Data.isEmpty {
                utf8Data.withUnsafeMutableBytes { raw in
                    if let base = raw.baseAddress {
                        funlock_secureZero(base, raw.count)
                    }
                }
            }
            utf8Data = Data()
        }

        guard !utf8Data.isEmpty else { return nil }

        var decoded: [UniChar] = []
        decoded.reserveCapacity(utf8Data.count)
        defer {
            decoded.withUnsafeMutableBufferPointer { buf in
                if let base = buf.baseAddress {
                    funlock_secureZero(base, buf.count * MemoryLayout<UniChar>.stride)
                }
            }
        }

        let validUTF8: Bool = utf8Data.withUnsafeBytes { raw in
            var iter = raw.makeIterator()
            var utf8 = UTF8()
            while true {
                switch utf8.decode(&iter) {
                case .scalarValue(let scalar):
                    for unit in scalar.utf16 {
                        decoded.append(unit)
                    }
                case .emptyInput:
                    return true
                case .error:
                    return false
                }
            }
        }
        guard validUTF8, !decoded.isEmpty else { return nil }

        let allocated = UnsafeMutablePointer<UniChar>.allocate(capacity: decoded.count)
        decoded.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                allocated.initialize(from: base, count: decoded.count)
            }
        }
        self.pointer = allocated
        self.count = decoded.count
    }

    deinit {
        wipe()
    }

    /// 按每批最多 `maxUnits` 个 UTF-16 编码单元（默认 20，对应 CGEvent 单次上限）流式投喂给注入闭包。
    @discardableResult
    func forEachCGEventBatch(maxUnits: Int = 20, _ body: (UnsafeMutablePointer<UniChar>, Int) -> Bool) -> Bool {
        guard !isWiped, let pointer, count > 0, maxUnits > 0 else { return false }
        var offset = 0
        while offset < count {
            let chunkCount = min(maxUnits, count - offset)
            if !body(pointer.advanced(by: offset), chunkCount) {
                return false
            }
            offset += chunkCount
        }
        return true
    }

    /// 通过 `memset_s` 零覆写敏感缓冲区并释放内存；可安全多次调用。
    func wipe() {
        guard !isWiped else { return }
        isWiped = true
        if let pointer {
            if count > 0 {
                funlock_secureZero(pointer, count * MemoryLayout<UniChar>.stride)
            }
            pointer.deinitialize(count: count)
            pointer.deallocate()
        }
        self.pointer = nil
        self.count = 0
    }
}
