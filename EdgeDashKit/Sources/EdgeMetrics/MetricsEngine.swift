import EdgeCore
import Foundation

/// Owns the sampling clock. One loop with tolerance-based coalescing; readers
/// fire on their tick multiple, but only while a metric they provide is
/// active. Results batch into a single main-actor hop per tick.
public actor MetricsEngine {
    private var readers: [any MetricReader] = []
    private var activeMetrics: Set<MetricID> = []
    private var paused = false
    private var tickCount = 0
    private var loop: Task<Void, Never>?
    private weak var hub: MetricHub?

    public init() {}

    public func register(_ reader: any MetricReader) {
        readers.append(reader)
    }

    public var registeredMetricIDs: [MetricID] {
        readers.flatMap(\.provides)
    }

    /// The set of metrics currently worth sampling (what visible surfaces
    /// need). Readers providing none of them are skipped entirely.
    public func setActiveMetrics(_ ids: Set<MetricID>) {
        activeMetrics = ids
    }

    public func activateAllRegistered() {
        activeMetrics = Set(registeredMetricIDs)
    }

    /// Full stop while the dashboard is disconnected/asleep/occluded.
    public func setPaused(_ paused: Bool) {
        self.paused = paused
    }

    public var isPaused: Bool { paused }

    public func start(publishingTo hub: MetricHub) {
        guard loop == nil else { return }
        self.hub = hub
        loop = Task(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(150))
                if Task.isCancelled { break }
                await self.tick()
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    func tick() async {
        guard !paused, let hub else { return }
        tickCount += 1
        var batch: [MetricSample] = []
        for reader in readers where tickCount % reader.cadence.tickMultiple == 0 {
            guard !activeMetrics.isDisjoint(with: reader.provides) else { continue }
            batch.append(contentsOf: (try? reader.read()) ?? [])
        }
        guard !batch.isEmpty else { return }
        let samples = batch
        await MainActor.run { hub.ingest(samples) }
    }
}
