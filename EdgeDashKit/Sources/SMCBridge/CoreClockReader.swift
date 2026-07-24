import EdgeCore
import Foundation
import IOKit

public extension MetricID {
    /// Composite MHz: e / p (weighted active average) + eMax / pMax (DVFS top).
    static let cpuClock = MetricID("cpu.clock")
}

/// Per-cluster CPU frequency via the private IOReport framework — the same
/// source powermetrics uses, but readable without root. Residency deltas per
/// DVFS state are weighted by the pmgr frequency tables. Quarantined here
/// with runtime detection: if anything is missing we report nothing and the
/// widget degrades to "unavailable".
public final class CoreClockReader: MetricReader, @unchecked Sendable {
    public var provides: [MetricID] {
        [.cpuClock]
    }

    public var cadence: MetricCadence {
        .everyTick
    }

    private let bridge = IOReportBridge.shared
    private var previous: CFDictionary? // engine calls read() serially

    public init() {}

    public func read() throws -> [MetricSample] {
        guard let bridge, let current = bridge.sample() else { return [] }
        defer { previous = current }
        guard let previous,
              let clusters = bridge.clusterFrequencies(previous: previous, current: current),
              !clusters.isEmpty else { return [] }

        var eActive: (mhz: Double, weight: Double) = (0, 0)
        var pActive: (mhz: Double, weight: Double) = (0, 0)
        for cluster in clusters {
            if cluster.isEfficiency {
                eActive.mhz += cluster.averageMHz * cluster.activeResidency
                eActive.weight += cluster.activeResidency
            } else {
                pActive.mhz += cluster.averageMHz * cluster.activeResidency
                pActive.weight += cluster.activeResidency
            }
        }
        let values: [String: Double] = [
            "e": eActive.weight > 0 ? eActive.mhz / eActive.weight : 0,
            "p": pActive.weight > 0 ? pActive.mhz / pActive.weight : 0,
            "eMax": bridge.eMaxMHz,
            "pMax": bridge.pMaxMHz,
        ]
        return [MetricSample(id: .cpuClock, value: .composite(values))]
    }
}

/// dlopen/dlsym binding to libIOReport plus the pmgr DVFS tables.
final class IOReportBridge: @unchecked Sendable {
    struct Cluster {
        var isEfficiency: Bool
        var averageMHz: Double
        var activeResidency: Double
    }

    static let shared = IOReportBridge()

    private typealias CopyChannelsFn = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    // swiftlint:disable:next line_length
    private typealias CreateSubscriptionFn = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
    private typealias CreateSamplesFn = @convention(c) (UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias SamplesDeltaFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias IterateFn = @convention(c) (CFDictionary, @convention(block) (CFDictionary) -> Int32) -> Void
    private typealias ChannelNameFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateCountFn = @convention(c) (CFDictionary) -> Int32
    private typealias StateNameFn = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidencyFn = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias SimpleIntegerFn = @convention(c) (CFDictionary, Int32) -> Int64

    private let createSamples: CreateSamplesFn
    private let samplesDelta: SamplesDeltaFn
    private let iterate: IterateFn
    private let channelName: ChannelNameFn
    private let unitLabel: ChannelNameFn
    private let stateCount: StateCountFn
    private let stateName: StateNameFn
    private let stateResidency: StateResidencyFn
    private let simpleInteger: SimpleIntegerFn
    private let subscription: UnsafeMutableRawPointer
    private let subscribedChannels: CFMutableDictionary
    /// Energy Model subscription (SoC power); nil where the group is absent.
    private let energySubscription: UnsafeMutableRawPointer?
    private let energyChannels: CFMutableDictionary?
    /// MHz per DVFS index; efficiency = voltage-states1, performance = 5.
    private let eFrequencies: [Double]
    private let pFrequencies: [Double]

    var eMaxMHz: Double {
        eFrequencies.last ?? 0
    }

    var pMaxMHz: Double {
        pFrequencies.last ?? 0
    }

    /// nil when the private API is unavailable (future macOS, Intel, …).
    private init?() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(lib, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let copyChannels = sym("IOReportCopyChannelsInGroup", as: CopyChannelsFn.self),
              let createSubscription = sym("IOReportCreateSubscription", as: CreateSubscriptionFn.self),
              let createSamples = sym("IOReportCreateSamples", as: CreateSamplesFn.self),
              let samplesDelta = sym("IOReportCreateSamplesDelta", as: SamplesDeltaFn.self),
              let iterate = sym("IOReportIterate", as: IterateFn.self),
              let channelName = sym("IOReportChannelGetChannelName", as: ChannelNameFn.self),
              let unitLabel = sym("IOReportChannelGetUnitLabel", as: ChannelNameFn.self),
              let stateCount = sym("IOReportStateGetCount", as: StateCountFn.self),
              let stateName = sym("IOReportStateGetNameForIndex", as: StateNameFn.self),
              let stateResidency = sym("IOReportStateGetResidency", as: StateResidencyFn.self),
              let simpleInteger = sym("IOReportSimpleGetIntegerValue", as: SimpleIntegerFn.self)
        else { return nil }

        guard let channels = copyChannels(
            "CPU Stats" as CFString, "CPU Complex Performance States" as CFString, 0, 0, 0
        )?.takeRetainedValue() else { return nil }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(nil, channels, &subbed, 0, nil),
              let subscribedChannels = subbed?.takeRetainedValue() else { return nil }

        let eFrequencies = Self.dvfsTableMHz(property: "voltage-states1-sram")
        let pFrequencies = Self.dvfsTableMHz(property: "voltage-states5-sram")
        guard !eFrequencies.isEmpty, !pFrequencies.isEmpty else { return nil }

        // Energy Model (power) is independent — missing is fine.
        var energySubscription: UnsafeMutableRawPointer?
        var energyChannels: CFMutableDictionary?
        if let channels = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() {
            var subbedEnergy: Unmanaged<CFMutableDictionary>?
            if let sub = createSubscription(nil, channels, &subbedEnergy, 0, nil),
               let dict = subbedEnergy?.takeRetainedValue()
            {
                energySubscription = sub
                energyChannels = dict
            }
        }

        self.createSamples = createSamples
        self.samplesDelta = samplesDelta
        self.iterate = iterate
        self.channelName = channelName
        self.unitLabel = unitLabel
        self.stateCount = stateCount
        self.stateName = stateName
        self.stateResidency = stateResidency
        self.simpleInteger = simpleInteger
        self.subscription = subscription
        self.subscribedChannels = subscribedChannels
        self.energySubscription = energySubscription
        self.energyChannels = energyChannels
        self.eFrequencies = eFrequencies
        self.pFrequencies = pFrequencies
    }

    func sample() -> CFDictionary? {
        createSamples(subscription, subscribedChannels, nil)?.takeRetainedValue()
    }

    func energySample() -> CFDictionary? {
        guard let energySubscription, let energyChannels else { return nil }
        return createSamples(energySubscription, energyChannels, nil)?.takeRetainedValue()
    }

    /// SoC watts over the interval: CPU cores + GPU + ANE + DRAM energy
    /// deltas (unit label decides the scale; other blocks are skipped to
    /// avoid double counting the memory subsystem).
    func energyWatts(previous: CFDictionary, current: CFDictionary, elapsed: TimeInterval) -> Double? {
        guard elapsed > 0, let delta = samplesDelta(previous, current, nil)?.takeRetainedValue() else { return nil }
        var joules = 0.0
        iterate(delta) { [self] channel in
            guard let name = channelName(channel)?.takeUnretainedValue() as String? else { return 0 }
            let counted = name.hasPrefix("EACC") || name.hasPrefix("PACC")
                || name.hasPrefix("GPU") || name.hasPrefix("ANE") || name.hasPrefix("DRAM")
            guard counted else { return 0 }
            let scale: Double = switch unitLabel(channel)?.takeUnretainedValue() as String? {
            case "nJ": 1e-9
            case "uJ", "µJ": 1e-6
            case "mJ": 1e-3
            case "J": 1
            default: 0 // unknown unit: safer to skip than to guess
            }
            joules += Double(simpleInteger(channel, 0)) * scale
            return 0
        }
        return joules > 0 ? joules / elapsed : nil
    }

    /// One entry per CPU cluster channel (ECPU, PCPU, PCPU1 …).
    func clusterFrequencies(previous: CFDictionary, current: CFDictionary) -> [Cluster]? {
        guard let delta = samplesDelta(previous, current, nil)?.takeRetainedValue() else { return nil }
        var clusters: [Cluster] = []
        iterate(delta) { [self] channel in
            guard let name = channelName(channel)?.takeUnretainedValue() as String? else { return 0 }
            // ECPM/PCPM etc. are power-management channels, not the clusters.
            let isEfficiency = name.hasPrefix("ECPU")
            let isPerformance = name.hasPrefix("PCPU")
            guard isEfficiency || isPerformance, !name.contains("CPM") else { return 0 }

            let table = isEfficiency ? eFrequencies : pFrequencies
            var weighted = 0.0
            var active = 0.0
            var dvfsIndex = 0
            for i in 0..<stateCount(channel) {
                let stateLabel = stateName(channel, i)?.takeUnretainedValue() as String? ?? ""
                let residency = Double(stateResidency(channel, i))
                // DVFS states are named V0…Vn in table order; IDLE/DOWN are not.
                if stateLabel.hasPrefix("V") {
                    if dvfsIndex < table.count {
                        weighted += residency * table[dvfsIndex]
                        active += residency
                    }
                    dvfsIndex += 1
                }
            }
            clusters.append(Cluster(
                isEfficiency: isEfficiency,
                averageMHz: active > 0 ? weighted / active : 0,
                activeResidency: active
            ))
            return 0
        }
        return clusters
    }

    /// pmgr DVFS table: pairs of (u32 Hz, u32 mV).
    private static func dvfsTableMHz(property: String) -> [Double] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(service, &nameBuffer)
            guard String(cString: nameBuffer) == "pmgr" else { continue }
            guard let data = IORegistryEntryCreateCFProperty(
                service, property as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? Data else { return [] }
            var frequencies: [Double] = []
            for offset in stride(from: 0, to: data.count - 7, by: 8) {
                let hz = data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.load(as: UInt32.self) }
                if hz > 0 { frequencies.append(Double(hz) / 1_000_000) }
            }
            return frequencies
        }
        return []
    }
}
