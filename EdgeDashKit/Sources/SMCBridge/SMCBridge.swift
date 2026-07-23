import EdgeCore
import Foundation

public extension MetricID {
    static let temperatures = MetricID("smc.temps") // composite: sensor name → °C
    static let fans = MetricID("smc.fans")          // composite: "Fan N" → RPM
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
