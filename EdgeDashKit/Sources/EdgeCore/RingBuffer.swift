/// Fixed-capacity ring buffer. Appending beyond capacity overwrites the oldest
/// element. Index 0 is always the oldest retained element. No allocation after
/// initialization.
public struct RingBuffer<Element: Sendable>: Sendable {
    private var storage: ContiguousArray<Element?>
    private var head = 0 // next write position
    public private(set) var count = 0
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
        self.storage = ContiguousArray(repeating: nil, count: capacity)
    }

    public mutating func append(_ element: Element) {
        storage[head] = element
        head = (head + 1) % capacity
        count = Swift.min(count + 1, capacity)
    }

    public mutating func removeAll() {
        storage = ContiguousArray(repeating: nil, count: capacity)
        head = 0
        count = 0
    }

    public var isEmpty: Bool { count == 0 }
    public var last: Element? { count > 0 ? self[count - 1] : nil }

    public subscript(_ index: Int) -> Element {
        precondition(index >= 0 && index < count, "RingBuffer index out of range")
        let start = (head - count + capacity) % capacity
        return storage[(start + index) % capacity]!
    }
}

extension RingBuffer: Sequence {
    public func makeIterator() -> AnyIterator<Element> {
        var index = 0
        return AnyIterator {
            guard index < count else { return nil }
            defer { index += 1 }
            return self[index]
        }
    }
}
