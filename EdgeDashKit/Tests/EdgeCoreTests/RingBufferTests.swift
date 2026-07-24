import EdgeCore
import Testing

struct RingBufferTests {
    @Test func appendBelowCapacityKeepsOrder() {
        var buffer = RingBuffer<Int>(capacity: 4)
        buffer.append(1)
        buffer.append(2)
        buffer.append(3)
        #expect(buffer.count == 3)
        #expect(Array(buffer) == [1, 2, 3])
        #expect(buffer.last == 3)
    }

    @Test func wrapAroundDropsOldest() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for i in 1...5 {
            buffer.append(i)
        }
        #expect(buffer.count == 3)
        #expect(Array(buffer) == [3, 4, 5])
        #expect(buffer[0] == 3)
        #expect(buffer.last == 5)
    }

    @Test func removeAllResets() {
        var buffer = RingBuffer<Int>(capacity: 2)
        buffer.append(1)
        buffer.append(2)
        buffer.removeAll()
        #expect(buffer.isEmpty)
        #expect(buffer.last == nil)
        buffer.append(9)
        #expect(Array(buffer) == [9])
    }
}
