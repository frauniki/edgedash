import Foundation

/// Stable identifier for a single metric stream, e.g. "cpu.usage", "net.en0.throughput".
public struct MetricID: Hashable, Codable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }
}

public enum MetricValue: Sendable, Equatable {
    /// Single number: 0–1 utilization, °C, RPM, bytes…
    case scalar(Double)
    /// Per-core values (CPU).
    case perCore([Double])
    /// Bidirectional rates in bytes/s: network rx/tx, disk read/write.
    case duplex(in: Double, out: Double)
    /// Named sub-values: memory breakdown, sensor groups.
    case composite([String: Double])
}

public struct MetricSample: Sendable {
    public let id: MetricID
    public let value: MetricValue
    public let timestamp: ContinuousClock.Instant

    public init(id: MetricID, value: MetricValue, timestamp: ContinuousClock.Instant = .now) {
        self.id = id
        self.value = value
        self.timestamp = timestamp
    }
}
