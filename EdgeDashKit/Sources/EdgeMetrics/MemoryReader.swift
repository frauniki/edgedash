import Darwin
import EdgeCore
import Foundation

public extension MetricID {
    static let memoryUsage = MetricID("mem.usage") // scalar 0–1 (Activity Monitor "Used" / total)
    static let memoryBreakdown = MetricID("mem.breakdown") // composite, bytes
    static let memoryPressure = MetricID("mem.pressure") // scalar: 1 normal / 2 warning / 4 critical
    static let memoryPressurePercent = MetricID("mem.pressurePct") // scalar 0–1 (1 − kern.memorystatus_level)
}

public struct MemoryReader: MetricReader {
    public init() {}

    public var provides: [MetricID] {
        [.memoryUsage, .memoryBreakdown, .memoryPressure, .memoryPressurePercent]
    }

    public var cadence: MetricCadence {
        .every(2)
    }

    public func read() throws -> [MetricSample] {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return [] }

        let pageSize = UInt64(Sysctl.value("hw.pagesize", default: Int64(16384)))
        let total = ProcessInfo.processInfo.physicalMemory
        let app = (UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)) &* pageSize
        let wired = UInt64(stats.wire_count) &* pageSize
        let compressed = UInt64(stats.compressor_page_count) &* pageSize
        let used = Self.usedBytes(app: app, wired: wired, compressed: compressed)
        let swap = Sysctl.swapUsage()

        // kern.memorystatus_level = free percentage; iStat-style pressure is
        // its complement.
        let level = Sysctl.value("kern.memorystatus_level", default: Int32(100))
        let pressureFraction = Double(100 - min(max(level, 0), 100)) / 100

        return [
            MetricSample(id: .memoryUsage, value: .scalar(Self.usedFraction(used: used, total: total))),
            MetricSample(id: .memoryBreakdown, value: .composite([
                "app": Double(app),
                "wired": Double(wired),
                "compressed": Double(compressed),
                "used": Double(used),
                "free": Double(total > used ? total - used : 0),
                "total": Double(total),
                "swapUsed": Double(swap.xsu_used),
                "swapTotal": Double(swap.xsu_total),
            ])),
            MetricSample(id: .memoryPressure, value: .scalar(Double(Sysctl.memoryPressureLevel()))),
            MetricSample(id: .memoryPressurePercent, value: .scalar(pressureFraction)),
        ]
    }

    /// Activity Monitor's "Memory Used" = App (internal − purgeable) + Wired + Compressed.
    public static func usedBytes(app: UInt64, wired: UInt64, compressed: UInt64) -> UInt64 {
        app &+ wired &+ compressed
    }

    public static func usedFraction(used: UInt64, total: UInt64) -> Double {
        total > 0 ? min(1, Double(used) / Double(total)) : 0
    }
}
