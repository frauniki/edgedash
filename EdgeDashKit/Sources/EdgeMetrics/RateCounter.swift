import EdgeCore
import Foundation

/// Turns monotonically increasing byte counters into bytes/s using real
/// elapsed time (the engine tick has tolerance, so wall-clock deltas matter).
struct RateCounter {
    private var previous: (in: UInt64, out: UInt64)?
    private var previousAt: ContinuousClock.Instant?

    /// Pure step function: returns rates for the new totals, or nil on the
    /// first call (no baseline) or counter reset (reboot/interface renewal).
    mutating func rates(in inBytes: UInt64, out outBytes: UInt64, at now: ContinuousClock.Instant = .now) -> (in: Double, out: Double)? {
        defer {
            previous = (inBytes, outBytes)
            previousAt = now
        }
        guard let previous, let previousAt else { return nil }
        let elapsed = Double((now - previousAt).components.attoseconds) / 1e18
            + Double((now - previousAt).components.seconds)
        guard elapsed > 0, inBytes >= previous.in, outBytes >= previous.out else { return nil }
        return (
            in: Double(inBytes - previous.in) / elapsed,
            out: Double(outBytes - previous.out) / elapsed
        )
    }
}
