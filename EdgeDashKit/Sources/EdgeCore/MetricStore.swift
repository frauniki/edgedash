import Foundation
import Observation

public struct MetricPoint: Sendable {
    public let timestamp: ContinuousClock.Instant
    public let value: MetricValue

    public init(timestamp: ContinuousClock.Instant, value: MetricValue) {
        self.timestamp = timestamp
        self.value = value
    }
}

/// One store per metric — the SwiftUI performance linchpin: Observation
/// tracking re-renders only the views that read the store that changed.
@Observable @MainActor public final class MetricStore {
    public private(set) var latest: MetricValue?
    public private(set) var history: RingBuffer<MetricPoint>

    public init(historyCapacity: Int = 120) {
        history = RingBuffer(capacity: historyCapacity)
    }

    public func ingest(_ sample: MetricSample) {
        latest = sample.value
        history.append(MetricPoint(timestamp: sample.timestamp, value: sample.value))
    }
}

/// MetricID → MetricStore. Views ask for a store up front (created empty on
/// demand) and observe it; the engine batches samples in once per tick.
@MainActor public final class MetricHub {
    private var stores: [MetricID: MetricStore] = [:]

    public init() {}

    public func store(for id: MetricID) -> MetricStore {
        if let existing = stores[id] { return existing }
        let store = MetricStore()
        stores[id] = store
        return store
    }

    public func ingest(_ samples: [MetricSample]) {
        for sample in samples {
            store(for: sample.id).ingest(sample)
        }
    }
}
