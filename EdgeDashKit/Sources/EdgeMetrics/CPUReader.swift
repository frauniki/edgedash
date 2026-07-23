import Darwin
import EdgeCore
import Foundation

public extension MetricID {
    static let cpuUsage = MetricID("cpu.usage")         // scalar 0–1
    static let cpuPerCore = MetricID("cpu.perCore")     // perCore 0–1
    static let cpuLoadAverage = MetricID("cpu.loadavg") // composite 1/5/15
    static let cpuBreakdown = MetricID("cpu.breakdown") // composite user/system/idle 0–1
    static let systemUptime = MetricID("sys.uptime")    // scalar seconds
    static let cpuTopology = MetricID("cpu.topology")   // composite e/p logical core counts
}

/// CPU utilization from host_processor_info tick deltas.
/// State (previous ticks) is only touched from the engine's serial context.
public final class CPUReader: MetricReader, @unchecked Sendable {
    public struct CoreTicks: Sendable, Equatable {
        public var user: UInt64
        public var system: UInt64
        public var idle: UInt64
        public var nice: UInt64

        public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
            self.user = user
            self.system = system
            self.idle = idle
            self.nice = nice
        }
    }

    private var previous: [CoreTicks] = []

    public init() {}

    /// Verified on M3 Max: perflevel0 = Performance, perflevel1 = Efficiency,
    /// and host_processor_info orders EFFICIENCY cores first in the array.
    private static let coreCounts: (e: Int, p: Int) = (
        e: Int(Sysctl.value("hw.perflevel1.logicalcpu", default: Int32(0))),
        p: Int(Sysctl.value("hw.perflevel0.logicalcpu", default: Int32(0)))
    )

    public var provides: [MetricID] { [.cpuUsage, .cpuPerCore, .cpuLoadAverage, .cpuBreakdown, .systemUptime, .cpuTopology] }
    public var cadence: MetricCadence { .everyTick }

    public func read() throws -> [MetricSample] {
        let current = Self.sampleTicks()
        defer { previous = current }
        guard current.count == previous.count, !current.isEmpty else {
            return [] // first tick (or core-count change): no delta yet
        }
        let perCore = Self.usage(previous: previous, current: current)
        let total = perCore.reduce(0, +) / Double(perCore.count)

        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)

        return [
            MetricSample(id: .cpuUsage, value: .scalar(total)),
            MetricSample(id: .cpuPerCore, value: .perCore(perCore)),
            MetricSample(id: .cpuLoadAverage, value: .composite(["1": load[0], "5": load[1], "15": load[2]])),
            MetricSample(id: .cpuBreakdown, value: .composite(Self.breakdown(previous: previous, current: current))),
            MetricSample(id: .systemUptime, value: .scalar(Self.uptimeSeconds())),
            MetricSample(id: .cpuTopology, value: .composite([
                "e": Double(Self.coreCounts.e), "p": Double(Self.coreCounts.p),
            ])),
        ]
    }

    /// Aggregate user/system/idle split across all cores.
    public static func breakdown(previous: [CoreTicks], current: [CoreTicks]) -> [String: Double] {
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0
        for (prev, curr) in zip(previous, current) {
            user &+= (curr.user &- prev.user) &+ (curr.nice &- prev.nice)
            system &+= curr.system &- prev.system
            idle &+= curr.idle &- prev.idle
        }
        let total = Double(user &+ system &+ idle)
        guard total > 0 else { return ["user": 0, "system": 0, "idle": 1] }
        return [
            "user": Double(user) / total,
            "system": Double(system) / total,
            "idle": Double(idle) / total,
        ]
    }

    static func uptimeSeconds() -> Double {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &boottime, &size, nil, 0) == 0 else { return 0 }
        return max(0, Date().timeIntervalSince1970 - Double(boottime.tv_sec))
    }

    /// Pure delta math, unit-tested without Mach.
    public static func usage(previous: [CoreTicks], current: [CoreTicks]) -> [Double] {
        zip(previous, current).map { prev, curr in
            let busy = (curr.user &- prev.user) &+ (curr.system &- prev.system) &+ (curr.nice &- prev.nice)
            let total = busy &+ (curr.idle &- prev.idle)
            return total > 0 ? Double(busy) / Double(total) : 0
        }
    }

    static func sampleTicks() -> [CoreTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount
        )
        guard result == KERN_SUCCESS, let info else { return [] }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }
        // Note: on Apple Silicon this array orders E-cluster cores first.
        return (0..<Int(cpuCount)).map { core in
            let base = core * Int(CPU_STATE_MAX)
            return CoreTicks(
                user: UInt64(bitPattern: Int64(info[base + Int(CPU_STATE_USER)])),
                system: UInt64(bitPattern: Int64(info[base + Int(CPU_STATE_SYSTEM)])),
                idle: UInt64(bitPattern: Int64(info[base + Int(CPU_STATE_IDLE)])),
                nice: UInt64(bitPattern: Int64(info[base + Int(CPU_STATE_NICE)]))
            )
        }
    }
}
