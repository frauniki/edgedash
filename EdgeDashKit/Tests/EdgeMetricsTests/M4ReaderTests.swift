import EdgeCore
@testable import EdgeMetrics
import Testing

struct M4ReaderTests {
    @Test func rateCounterComputesPerSecond() throws {
        var counter = RateCounter()
        let t0 = ContinuousClock.now
        #expect(counter.rates(in: 1000, out: 500, at: t0) == nil) // no baseline
        let rates = counter.rates(in: 3000, out: 1500, at: t0.advanced(by: .seconds(2)))
        #expect(rates != nil)
        #expect(try abs(#require(rates?.in) - 1000) < 0.001) // 2000 bytes over 2 s
        #expect(try abs(#require(rates?.out) - 500) < 0.001)
    }

    @Test func rateCounterHandlesCounterReset() {
        var counter = RateCounter()
        let t0 = ContinuousClock.now
        _ = counter.rates(in: 5000, out: 5000, at: t0)
        // Counter went backwards (interface reset) → no bogus spike.
        #expect(counter.rates(in: 100, out: 100, at: t0.advanced(by: .seconds(1))) == nil)
    }

    @Test func gpuUtilizationParsing() {
        #expect(GPUReader.deviceUtilization(from: ["Device Utilization %": 42]) == 0.42)
        #expect(GPUReader.deviceUtilization(from: ["Device Utilization %": 250]) == 1.0) // clamped
        #expect(GPUReader.deviceUtilization(from: [:]) == nil)
        #expect(GPUReader.deviceUtilization(from: ["Device Utilization %": "bad"]) == nil)
    }

    // Live smoke tests — validate real APIs on this machine.

    @Test func liveDiskCapacity() throws {
        let samples = try DiskCapacityReader().read()
        guard case .composite(let d)? = samples.first?.value else {
            Issue.record("no capacity sample"); return
        }
        #expect(try #require(d["total"]) > 100_000_000_000) // a real Mac has >100 GB storage
        #expect(try #require(d["used"]) > 0 && d["used"]! < d["total"]!)
    }

    @Test func liveGPUStatisticsPresent() {
        // Verified present on Apple Silicon (M3 Max, macOS 26.5); this guards regressions.
        #expect(GPUReader.performanceStatistics() != nil)
    }

    @Test func liveNetworkCountersMonotonic() {
        let a = NetworkReader.byteCounts(interface: nil)
        let b = NetworkReader.byteCounts(interface: nil)
        #expect(b.rx >= a.rx)
        #expect(a.rx > 0) // machine has moved bytes since boot
    }
}
