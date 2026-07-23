import EdgeCore
import EdgeTouch
import SMCBridge
import SwiftUI
import WidgetEngine

public struct TemperatureWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        /// Substrings to match sensor names against; empty = hottest sensors.
        public var sensorFilters: [String] = []
        public var maxRows = 6
        public var fahrenheit = false
        public init() {}
    }

    public static let typeID = WidgetTypeID("edgedash.temperature")
    public static let displayName = "Temperatures"
    public static let category = WidgetCategory.monitoring
    public static let supportedSizes = [
        GridSize(cols: 1, rows: 2), GridSize(cols: 2, rows: 2), GridSize(cols: 4, rows: 2),
    ]

    public static func requiredMetrics(for config: Config) -> Set<MetricID> {
        [.temperatures]
    }

    @MainActor public static func makeView(config: Config, context: WidgetContext) -> AnyView {
        AnyView(TemperatureView(config: config, temps: context.hub.store(for: .temperatures)))
    }

    @MainActor public static func makeConfigView(config: Binding<Config>, context: WidgetContext) -> AnyView {
        AnyView(TemperatureConfigView(config: config, temps: context.hub.store(for: .temperatures)))
    }
}

private struct TemperatureView: View {
    @Environment(\.theme) private var theme
    let config: TemperatureWidget.Config
    let temps: MetricStore

    private var rows: [(name: String, celsius: Double)] {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetTitle(text: "TEMPERATURES", value: rows.first.map { degrees($0.celsius) })
            if rows.isEmpty {
                unavailable
            } else {
                // Touch-scrollable when the sensor list overflows the cell.
                TouchScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(rows, id: \.name) { row in
                            sensorRow(row)
                        }
                    }
                }
            }
        }
        .padding(14)
    }

    private func sensorRow(_ row: (name: String, celsius: Double)) -> some View {
        // 105 °C ≈ Apple Silicon throttle ceiling.
        let fraction = min(row.celsius / 105, 1)
        return HStack(spacing: 8) {
            Text(row.name)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            MeterBar(fraction: fraction, color: theme.gaugeColor(fraction, warn: 0.75, critical: 0.9).color)
                .frame(width: 60)
            Text(degrees(row.celsius))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
                .frame(width: 52, alignment: .trailing)
        }
        .font(.system(size: 12, design: .rounded))
    }

    private var unavailable: some View {
        Text("Sensors unavailable")
            .font(.system(size: 13, design: .rounded))
            .foregroundStyle(theme.textSecondary.color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func degrees(_ celsius: Double) -> String {
        config.fahrenheit
            ? String(format: "%.0f°F", celsius * 9 / 5 + 32)
            : String(format: "%.0f°C", celsius)
    }
}

private struct TemperatureConfigView: View {
    @Binding var config: TemperatureWidget.Config
    let temps: MetricStore

    private var discoveredSensors: [String] {
        guard case .composite(let sensors)? = temps.latest else { return [] }
        return sensors.keys.sorted()
    }

    var body: some View {
        Form {
            Stepper("Rows: \(config.maxRows)", value: $config.maxRows, in: 1...12)
            Toggle("Fahrenheit", isOn: $config.fahrenheit)
            Section("Sensors") {
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
