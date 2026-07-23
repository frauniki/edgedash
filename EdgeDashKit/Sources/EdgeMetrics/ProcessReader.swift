import Darwin
import EdgeCore
import Foundation

public extension MetricID {
    /// name → CPU fraction (1.0 = one full core, can exceed 1 like iStat/top).
    static let topProcessesCPU = MetricID("proc.topCPU")
    /// name → resident bytes.
    static let topProcessesMemory = MetricID("proc.topMem")
}

/// Per-process CPU/memory via proc_pidinfo deltas — the data behind
/// iStat-style "top processes" lists.
public final class ProcessReader: MetricReader, @unchecked Sendable {
    public var topCount = 8

    // pid → cumulative cpu time (mach absolute units); engine calls serially.
    private var previousCPUTime: [pid_t: UInt64] = [:]
    private var previousSampleTime: UInt64 = 0
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public init() {}

    public var provides: [MetricID] { [.topProcessesCPU, .topProcessesMemory] }
    public var cadence: MetricCadence { .every(5) }

    public func read() throws -> [MetricSample] {
        let now = mach_absolute_time()
        let elapsed = Double(now - previousSampleTime)
        let hadBaseline = previousSampleTime != 0
        previousSampleTime = now

        var pids = [pid_t](repeating: 0, count: 4096)
        let byteCount = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard byteCount > 0 else { return [] }
        let pidCount = Int(byteCount)

        var cpuTimes: [pid_t: UInt64] = [:]
        var cpuTop: [String: Double] = [:]
        var memTop: [String: Double] = [:]
        var rows: [(pid: pid_t, name: String, cpuTime: UInt64, resident: UInt64)] = []
        rows.reserveCapacity(pidCount)

        for pid in pids.prefix(pidCount) where pid > 0 {
            var info = proc_taskinfo()
            let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.stride))
            guard size == Int32(MemoryLayout<proc_taskinfo>.stride) else { continue }

            var nameBuffer = [CChar](repeating: 0, count: 64)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = String(cString: nameBuffer)
            guard !name.isEmpty else { continue }

            let cpuTime = info.pti_total_user &+ info.pti_total_system
            rows.append((pid, name, cpuTime, info.pti_resident_size))
            cpuTimes[pid] = cpuTime
        }

        // CPU: delta against previous sample (needs a baseline).
        if hadBaseline, elapsed > 0 {
            var fractions: [(String, Double)] = []
            for row in rows {
                guard let previous = previousCPUTime[row.pid], row.cpuTime >= previous else { continue }
                let fraction = Double(row.cpuTime - previous) / elapsed
                if fraction > 0.001 { fractions.append((row.name, fraction)) }
            }
            for (name, fraction) in fractions.sorted(by: { $0.1 > $1.1 }).prefix(topCount) {
                cpuTop[name, default: 0] += fraction
            }
        }
        previousCPUTime = cpuTimes

        for row in rows.sorted(by: { $0.resident > $1.resident }).prefix(topCount) {
            memTop[row.name, default: 0] += Double(row.resident)
        }

        var samples = [MetricSample(id: .topProcessesMemory, value: .composite(memTop))]
        if !cpuTop.isEmpty {
            samples.append(MetricSample(id: .topProcessesCPU, value: .composite(cpuTop)))
        }
        return samples
    }
}
