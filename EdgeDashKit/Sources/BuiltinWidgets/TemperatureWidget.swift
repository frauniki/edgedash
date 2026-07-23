import EdgeCore
import EdgeTouch
import SMCBridge
import SwiftUI
import WidgetEngine

/// Combined hardware sensors widget: temperatures, fans, per-cluster core
/// clocks and system power, each section toggleable. Keeps the historical
/// "edgedash.temperature" type id so existing placements survive.
public struct TemperatureWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        public var showTemperatures = true
        public var showFans = true
        public var showCoreClock = true
        public var showPower = true
        /// Substrings to match sensor names against; empty = hottest sensors.
        public var sensorFilters: [String] = []
        public var maxRows = 6
        public var fahrenheit = false
        public init() {}

        // Lenient decoding: adding fields must not reset saved configs.
        private enum CodingKeys: String, CodingKey {
            case showTemperatures, showFans, showCoreClock, showPower, sensorFilters, maxRows, fahrenheit
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            showTemperatures = try container.decodeIfPresent(Bool.self, forKey: .showTemperatures) ?? true
            showFans = try container.decodeIfPresent(Bool.self, forKey: .showFans) ?? true
            showCoreClock = try container.decodeIfPresent(Bool.self, forKey: .showCoreClock) ?? true
            showPower = try container.decodeIfPresent(Bool.self, forKey: .showPower) ?? true
            sensorFilters = try container.decodeIfPresent([String].self, forKey: .sensorFilters) ?? []
            maxRows = try container.decodeIfPresent(Int.self, forKey: .maxRows) ?? 6
            fahrenheit = try container.decodeIfPresent(Bool.self, forKey: .fahrenheit) ?? false
        }
    }

    public static let typeID = WidgetTypeID("edgedash.temperature")
    public static let displayName = "Sensors"
    public static let category = WidgetCategory.monitoring
    public static let supportedSizes = [
        GridSize(cols: 1, rows: 1), GridSize(cols: 1, rows: 2),
        GridSize(cols: 2, rows: 2), GridSize(cols: 4, rows: 2),
    ]

    public static func requiredMetrics(for config: Config) -> Set<MetricID> {
        var ids: Set<MetricID> = []
        if config.showTemperatures { ids.insert(.temperatures) }
        if config.showFans { ids.insert(.fans) }
        if config.showCoreClock { ids.insert(.cpuClock) }
        if config.showPower { ids.insert(.systemPower) }
        return ids
    }

    @MainActor public static func makeView(config: Config, context: WidgetContext) -> AnyView {
        AnyView(SensorsView(
            config: config,
            temps: context.hub.store(for: .temperatures),
            fans: context.hub.store(for: .fans),
            clock: context.hub.store(for: .cpuClock),
            power: context.hub.store(for: .systemPower),
            size: context.size
        ))
    }

    @MainActor public static func makeConfigView(config: Binding<Config>, context: WidgetContext) -> AnyView {
        AnyView(SensorsConfigView(config: config, temps: context.hub.store(for: .temperatures)))
    }
}

private struct SensorsView: View {
    @Environment(\.theme) private var theme
    let config: TemperatureWidget.Config
    let temps: MetricStore
    let fans: MetricStore
    let clock: MetricStore
    let power: MetricStore
    let size: GridSize

    /// The 1×1 cell is too narrow for name + meter + value; drop the meters.
    private var showsMeter: Bool { size.cols > 1 || size.rows > 1 }

    // MARK: - Data

    private var temperatureRows: [(name: String, celsius: Double)] {
        guard case .composite(let sensors)? = temps.latest else { return [] }
        var entries = sensors.map { (name: $0.key, celsius: $0.value) }
        if !config.sensorFilters.isEmpty {
            entries = entries.filter { entry in
                config.sensorFilters.contains { entry.name.localizedCaseInsensitiveContains($0) }
            }
        }
        return entries
            .sorted { $0.celsius > $1.celsius }
            .prefix(max(1, config.maxRows))
            .map { $0 }
    }

    private var fanRows: [(name: String, rpm: Double)] {
        guard case .composite(let values)? = fans.latest else { return [] }
        return values.sorted { $0.key < $1.key }.map { (name: $0.key, rpm: $0.value) }
    }

    private var clocks: (e: Double, p: Double, eMax: Double, pMax: Double)? {
        guard case .composite(let values)? = clock.latest,
              let e = values["e"], let p = values["p"],
              let eMax = values["eMax"], let pMax = values["pMax"], pMax > 0 else { return nil }
        return (e, p, eMax, pMax)
    }

    private var watts: Double? {
        if case .scalar(let value)? = power.latest, value > 0 { value } else { nil }
    }

    // MARK: - Layout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetTitle(text: "SENSORS", value: temperatureRows.first.map { degrees($0.celsius) })
            TouchScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if config.showCoreClock, let clocks {
                        sectionHeader("CORE CLOCK")
                        meterRow(
                            name: "E-cores",
                            fraction: clocks.e / clocks.eMax,
                            value: Self.gigahertz(clocks.e),
                            color: theme.accentAlt.color
                        )
                        meterRow(
                            name: "P-cores",
                            fraction: clocks.p / clocks.pMax,
                            value: Self.gigahertz(clocks.p),
                            color: theme.accent.color
                        )
                    }
                    if config.showPower, let watts {
                        sectionHeader("POWER")
                        meterRow(
                            name: "System",
                            fraction: watts / 150, // M-series desktop-class ceiling
                            value: String(format: "%.1f W", watts),
                            color: theme.gaugeColor(watts / 150, warn: 0.6, critical: 0.85).color
                        )
                    }
                    if config.showFans {
                        sectionHeader("FANS")
                        if fanRows.isEmpty {
                            unavailableRow("No fans")
                        }
                        ForEach(fanRows, id: \.name) { fan in
                            meterRow(
                                name: fan.name,
                                fraction: fan.rpm / 6000,
                                value: String(format: "%.0f rpm", fan.rpm),
                                color: theme.gaugeColor(fan.rpm / 6000, warn: 0.7, critical: 0.9).color
                            )
                        }
                    }
                    if config.showTemperatures {
                        sectionHeader("TEMPERATURES")
                        if temperatureRows.isEmpty {
                            unavailableRow("Sensors unavailable")
                        }
                        ForEach(temperatureRows, id: \.name) { row in
                            meterRow(
                                name: row.name,
                                fraction: row.celsius / 105, // Apple Silicon throttle ceiling
                                value: degrees(row.celsius),
                                color: theme.gaugeColor(min(row.celsius / 105, 1), warn: 0.75, critical: 0.9).color
                            )
                        }
                    }
                }
            }
        }
        .padding(14)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(theme.textSecondary.color.opacity(0.8))
            .kerning(1.2)
            .padding(.top, 3)
    }

    private func meterRow(name: String, fraction: Double, value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if showsMeter {
                MeterBar(fraction: min(max(fraction, 0), 1), color: color)
                    .frame(width: size.cols >= 2 ? 60 : 44)
            }
            Text(value)
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
                .frame(width: 58, alignment: .trailing)
        }
        .font(.system(size: 12, design: .rounded))
    }

    private func unavailableRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(theme.textSecondary.color.opacity(0.7))
    }

    private func degrees(_ celsius: Double) -> String {
        config.fahrenheit
            ? String(format: "%.0f°F", celsius * 9 / 5 + 32)
            : String(format: "%.0f°C", celsius)
    }

    static func gigahertz(_ mhz: Double) -> String {
        mhz >= 1000 ? String(format: "%.2f GHz", mhz / 1000) : String(format: "%.0f MHz", mhz)
    }
}

private struct SensorsConfigView: View {
    @Binding var config: TemperatureWidget.Config
    let temps: MetricStore

    private var discoveredSensors: [String] {
        guard case .composite(let sensors)? = temps.latest else { return [] }
        return sensors.keys.sorted()
    }

    var body: some View {
        ConfigForm {
            ConfigSection("Sections") {
                Toggle("Core clock", isOn: $config.showCoreClock)
                Toggle("Power", isOn: $config.showPower)
                Toggle("Fans", isOn: $config.showFans)
                Toggle("Temperatures", isOn: $config.showTemperatures)
            }
            Stepper("Temperature rows: \(config.maxRows)", value: $config.maxRows, in: 1...12)
            Toggle("Fahrenheit", isOn: $config.fahrenheit)
            ConfigSection("Temperature sensors") {
                Toggle("All sensors (hottest first)", isOn: Binding(
                    get: { config.sensorFilters.isEmpty },
                    set: { all in if all { config.sensorFilters = [] } }
                ))
                if !discoveredSensors.isEmpty {
                    ForEach(discoveredSensors, id: \.self) { name in
                        Toggle(name, isOn: Binding(
                            get: { config.sensorFilters.contains(name) },
                            set: { on in
                                if on {
                                    config.sensorFilters.append(name)
                                } else {
                                    config.sensorFilters.removeAll { $0 == name }
                                }
                            }
                        ))
                        .font(.caption)
                    }
                } else {
                    Text("No sensors discovered yet")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
