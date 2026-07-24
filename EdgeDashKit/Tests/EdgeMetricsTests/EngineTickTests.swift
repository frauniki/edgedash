import EdgeCore
@testable import EdgeMetrics
import Testing

private struct CountingReader: MetricReader {
    let id: MetricID
    let cadence: MetricCadence
    var provides: [MetricID] {
        [id]
    }

    func read() throws -> [MetricSample] {
        [MetricSample(id: id, value: .scalar(1))]
    }
}

@MainActor struct EngineTickTests {
    @Test func cadenceAndPauseGateSampling() async {
        let hub = MetricHub()
        let engine = MetricsEngine()
        let fast = MetricID("test.fast")
        let slow = MetricID("test.slow")
        await engine.register(CountingReader(id: fast, cadence: .everyTick))
        await engine.register(CountingReader(id: slow, cadence: .every(2)))
        await engine.activateAllRegistered()
        await engine.start(publishingTo: hub) // loop sleeps 1 s before first tick…
        await engine.stop() // …cancelled before it can fire

        for _ in 0..<4 {
            await engine.tick()
        }
        #expect(hub.store(for: fast).history.count == 4)
        #expect(hub.store(for: slow).history.count == 2)

        await engine.setPaused(true)
        await engine.tick()
        #expect(hub.store(for: fast).history.count == 4)
    }

    @Test func inactiveMetricsAreNotSampled() async {
        let hub = MetricHub()
        let engine = MetricsEngine()
        let wanted = MetricID("test.wanted")
        let ignored = MetricID("test.ignored")
        await engine.register(CountingReader(id: wanted, cadence: .everyTick))
        await engine.register(CountingReader(id: ignored, cadence: .everyTick))
        await engine.setActiveMetrics([wanted])
        await engine.start(publishingTo: hub)
        await engine.stop()

        await engine.tick()
        #expect(hub.store(for: wanted).history.count == 1)
        #expect(hub.store(for: ignored).history.count == 0)
    }
}
