import EdgeCore
import Foundation
import IOKit

public extension MetricID {
    static let gpuUsage = MetricID("gpu.usage") // scalar 0–1
    static let gpuMemory = MetricID("gpu.memory") // scalar bytes in use
}

/// GPU utilization from IOAccelerator PerformanceStatistics (undocumented but
/// stable property; feature-detected — absent keys simply produce no samples).
public struct GPUReader: MetricReader {
    public init() {}

    public var provides: [MetricID] {
        [.gpuUsage, .gpuMemory]
    }

    public var cadence: MetricCadence {
        .everyTick
    }

    public func read() throws -> [MetricSample] {
        guard let stats = Self.performanceStatistics() else { return [] }
        var samples: [MetricSample] = []
        if let utilization = Self.deviceUtilization(from: stats) {
            samples.append(MetricSample(id: .gpuUsage, value: .scalar(utilization)))
        }
        if let bytes = stats["In use system memory"] as? UInt64 {
            samples.append(MetricSample(id: .gpuMemory, value: .scalar(Double(bytes))))
        }
        return samples
    }

    /// Pure extraction, unit-tested: utilization key is an Int percent.
    public static func deviceUtilization(from stats: [String: Any]) -> Double? {
        guard let percent = stats["Device Utilization %"] as? Int else { return nil }
        return min(max(Double(percent) / 100, 0), 1)
    }

    static func performanceStatistics() -> [String: Any]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any],
                  let stats = props["PerformanceStatistics"] as? [String: Any] else { continue }
            return stats
        }
        return nil
    }
}
