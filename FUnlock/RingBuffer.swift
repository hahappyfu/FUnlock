// RingBuffer.swift
// 固定容量环形数组，O(1) 存取，无内存搬运

import Foundation

struct RingBuffer<T> {
    private var buffer: [T?]
    private var head: Int = 0      // 下一个写入位置
    private(set) var count: Int = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [T?](repeating: nil, count: capacity)
    }

    /// 追加元素；满时自动覆盖最旧的
    mutating func append(_ element: T) {
        buffer[head] = element
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    /// 按时间顺序读取（从最旧到最新）
    subscript(index: Int) -> T {
        precondition(index >= 0 && index < count, "RingBuffer index out of range")
        let start = (head - count + capacity) % capacity
        let actual = (start + index) % capacity
        return buffer[actual]!
    }

    /// 清空
    mutating func clear() {
        buffer = [T?](repeating: nil, count: capacity)
        head = 0
        count = 0
    }

    /// 转为有序数组（最旧在前）
    func toArray() -> [T] {
        var result = [T]()
        result.reserveCapacity(count)
        let start = (head - count + capacity) % capacity
        for i in 0..<count {
            result.append(buffer[(start + i) % capacity]!)
        }
        return result
    }
}
