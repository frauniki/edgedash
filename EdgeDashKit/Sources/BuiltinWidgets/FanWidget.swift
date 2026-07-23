import EdgeCore
import SMCBridge
import SwiftUI
import WidgetEngine

public struct FanWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        /// Visual full-scale RPM for the bars.
        public var maxRPM = 6000.0
        public init() {}
    }

    public static let typeID = WidgetTypeID("edgedash.fan")
    public static let displayName = "Fans"
    public static let category = WidgetCategory.monitoring
    public static let supportedSizes = [
        GridSize(cols: 1, rows: 1), GridSize(cols: 2, rows: 1), GridSize(cols: 2, rows: 2),
    ]

    public static func requiredMetrics(for config: Config) -> Set<MetricID> {
        [.fans]
    }

    @MainActor public static func makeView(config: Config, context: WidgetContext) -> AnyView {
        AnyView(FanView(config: config, fans: context.hub.store(for: .fans)))
    }

    @MainActor public static func makeConfigView(config: Binding<Config>) -> AnyView {
        AnyView(FanConfigView(config: config))
    }
}

private struct FanView: View {
    @Environment(\.theme) private var theme
    let config: FanWidget.Config
    let fans: MetricStore

    private var rows: [(name: String, rpm: Double)] {
        guard case .composite(let values)? = fans.latest else { return [] }
        return values.sorted { $0.key < $1.key }.map { (name: $0.key, rpm: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetTitle(text: "FANS", value: rows.first.map { String(format: "%.0f", $0.rpm) })
            if rows.isEmpty {
                Text("No fans")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows, id: \.name) { row in
                        fanRow(row)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(14)
    }

    private func fanRow(_ row: (name: String, rpm: Double)) -> some View {
        let fraction = min(row.rpm / max(config.maxRPM, 1), 1)
        return HStack(spacing: 8) {
            Text(row.name)
                .foregroundStyle(theme.textSecondary.color)
            MeterBar(fraction: fraction, color: theme.gaugeColor(fraction, warn: 0.7, critical: 0.9).color)
            Text(String(format: "%.0f rpm", row.rpm))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
                .frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 12, design: .rounded))
    }
}

private struct FanConfigView: View {
    @Binding var config: FanWidget.Config

    var body: some View {
        Form {
            Stepper(
                "Max RPM: \(Int(config.maxRPM))",
                value: $config.maxRPM,
                in: 1000...12000,
                step: 500
            )
        }
    }
}
