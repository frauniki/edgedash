/// How often a reader fires relative to the 1 s base tick.
public enum MetricCadence: Sendable, Equatable {
    case everyTick
    case every(Int) // multiples of the base tick

    public var tickMultiple: Int {
        switch self {
        case .everyTick: 1
        case .every(let n): Swift.max(1, n)
        }
    }
}

/// Synchronous, cheap producer of metric samples. Called off-main by the
/// engine. Lives in EdgeCore so any module (EdgeMetrics, SMCBridge, future
/// MediaWidgets…) can implement readers without depending on the engine.
public protocol MetricReader: Sendable {
    var provides: [MetricID] { get }
    var cadence: MetricCadence { get }
    func read() throws -> [MetricSample]
}
