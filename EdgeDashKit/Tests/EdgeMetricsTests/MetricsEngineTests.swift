import EdgeCore
import EdgeMetrics
import Testing

private struct FakeReader: MetricReader {
    var provides: [MetricID] { [MetricID("test.fake")] }
    var cadence: MetricCadence { .everyTick }
    func read() throws -> [MetricSample] {
        [MetricSample(id: MetricID("test.fake"), value: .scalar(0.5))]
    }
}

@Suite struct MetricsEngineTests {
    @Test func registrationExposesMetricIDs() async {
        let engine = MetricsEngine()
        await engine.register(FakeReader())
        let ids = await engine.registeredMetricIDs
        #expect(ids == [MetricID("test.fake")])
    }

    @Test func cadenceTickMultiples() {
        #expect(MetricCadence.everyTick.tickMultiple == 1)
        #expect(MetricCadence.every(3).tickMultiple == 3)
        #expect(MetricCadence.every(0).tickMultiple == 1)
    }
}
