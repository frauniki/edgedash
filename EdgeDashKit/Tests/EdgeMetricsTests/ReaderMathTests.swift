import EdgeCore
import EdgeMetrics
import Testing

struct ReaderMathTests {
    @Test func cpuUsageDelta() {
        let prev = [
            CPUReader.CoreTicks(user: 100, system: 50, idle: 850, nice: 0),
            CPUReader.CoreTicks(user: 0, system: 0, idle: 1000, nice: 0),
        ]
        let curr = [
            CPUReader.CoreTicks(user: 200, system: 100, idle: 1000, nice: 0), // busy 150 / total 300
            CPUReader.CoreTicks(user: 0, system: 0, idle: 2000, nice: 0), // idle core
        ]
        let usage = CPUReader.usage(previous: prev, current: curr)
        #expect(usage.count == 2)
        #expect(abs(usage[0] - 0.5) < 0.0001)
        #expect(usage[1] == 0)
    }

    @Test func cpuUsageZeroDeltaIsZeroNotNaN() {
        let ticks = [CPUReader.CoreTicks(user: 10, system: 10, idle: 10, nice: 0)]
        #expect(CPUReader.usage(previous: ticks, current: ticks) == [0])
    }

    @Test func memoryFormulas() {
        let used = MemoryReader.usedBytes(app: 10, wired: 5, compressed: 5)
        #expect(used == 20)
        #expect(MemoryReader.usedFraction(used: 20, total: 80) == 0.25)
        #expect(MemoryReader.usedFraction(used: 100, total: 0) == 0)
        #expect(MemoryReader.usedFraction(used: 200, total: 100) == 1) // clamped
    }

    @Test func liveCPUReaderProducesDeltaOnSecondRead() throws {
        let reader = CPUReader()
        _ = try reader.read() // primes previous ticks — returns []
        let samples = try reader.read()
        let usage = samples.first { $0.id == .cpuUsage }
        #expect(usage != nil)
        if case .scalar(let v)? = usage?.value {
            #expect(v >= 0 && v <= 1)
        } else {
            Issue.record("cpu.usage should be scalar")
        }
    }
}
