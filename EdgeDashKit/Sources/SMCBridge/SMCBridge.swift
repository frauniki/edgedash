import EdgeCore
import Foundation

public extension MetricID {
    static let temperatures = MetricID("smc.temps") // composite: sensor name → °C
    static let fans = MetricID("smc.fans")          // composite: "Fan N" → RPM
    static let systemPower = MetricID("smc.power")  // scalar: total system watts
}

/// Quarantine module for private-API access. Everything here feature-detects
/// at runtime and degrades to "no samples" — no other module touches private
/// APIs, and the temperature/fan widgets show an unavailable state instead
/// of failing.
public enum SMCBridge {
    /// True when at least one temperature sensor is readable.
    public static func temperatureSensorsAvailable() -> Bool {
        !HIDTemperatureSensors.readAll().isEmpty
    }

    /// True on actively cooled machines with a reachable AppleSMC (fanless
    /// Airs report zero fans).
    public static func fansAvailable() -> Bool {
        fanCount() > 0
    }

    static func fanCount() -> Int {
        guard let smc = SMCConnection(),
              let (bytes, type) = smc.read(key: "FNum"),
              let count = SMCConnection.decodeFloat(bytes: bytes, type: type) else {
            return 0
        }
        return Int(count)
    }
}

/// All AppleVendor temperature sensors as one composite sample. Discovery is
/// dynamic — sensor names vary per model and feed the widget's picker.
public struct SMCTemperatureReader: MetricReader {
    public init() {}

    public var provides: [MetricID] { [.temperatures] }
    public var cadence: MetricCadence { .every(3) }

    public func read() throws -> [MetricSample] {
        let sensors = HIDTemperatureSensors.readAll()
        guard !sensors.isEmpty else { return [] }
        return [MetricSample(id: .temperatures, value: .composite(sensors))]
    }
}

/// Power draw in watts. Primary source is the SMC "PSTR" key (whole-system,
/// where it exists); machines without it (e.g. M3 Max/macOS 26) fall back to
/// the IOReport Energy Model counters — SoC power (CPU+GPU+ANE+DRAM), the
/// same numbers powermetrics reports, readable without root.
public final class SMCPowerReader: MetricReader, @unchecked Sendable {
    private var smc: SMCConnection? // engine calls read() serially
    private var openAttempted = false
    private var previousEnergy: (sample: CFDictionary, at: Date)?

    public init() {}

    public var provides: [MetricID] { [.systemPower] }
    public var cadence: MetricCadence { .every(2) }

    public func read() throws -> [MetricSample] {
        if smc == nil, !openAttempted {
            openAttempted = true
            smc = SMCConnection()
        }
        if let smc,
           let (bytes, type) = smc.read(key: "PSTR"),
           let watts = SMCConnection.decodeFloat(bytes: bytes, type: type),
           watts > 0, watts < 1000 {
            return [MetricSample(id: .systemPower, value: .scalar(watts))]
        }
        return energyModelWatts()
    }

    private func energyModelWatts() -> [MetricSample] {
        guard let bridge = IOReportBridge.shared, let current = bridge.energySample() else { return [] }
        let now = Date()
        defer { previousEnergy = (current, now) }
        guard let previousEnergy else { return [] }
        let elapsed = now.timeIntervalSince(previousEnergy.at)
        guard elapsed > 0.2,
              let watts = bridge.energyWatts(previous: previousEnergy.sample, current: current, elapsed: elapsed),
              watts > 0, watts < 1000 else { return [] }
        return [MetricSample(id: .systemPower, value: .scalar(watts))]
    }
}

/// Fan RPMs from AppleSMC F<n>Ac keys.
public final class SMCFanReader: MetricReader, @unchecked Sendable {
    private var smc: SMCConnection? // engine calls read() serially
    private var openAttempted = false

    public init() {}

    public var provides: [MetricID] { [.fans] }
    public var cadence: MetricCadence { .every(3) }

    public func read() throws -> [MetricSample] {
        if smc == nil, !openAttempted {
            openAttempted = true
            smc = SMCConnection()
        }
        guard let smc,
              let (countBytes, countType) = smc.read(key: "FNum"),
              let count = SMCConnection.decodeFloat(bytes: countBytes, type: countType),
              count > 0 else {
            return []
        }

        var fans: [String: Double] = [:]
        for index in 0..<Int(count) {
            if let (bytes, type) = smc.read(key: "F\(index)Ac"),
               let rpm = SMCConnection.decodeFloat(bytes: bytes, type: type) {
                fans["Fan \(index)"] = rpm
            }
        }
        guard !fans.isEmpty else { return [] }
        return [MetricSample(id: .fans, value: .composite(fans))]
    }
}
