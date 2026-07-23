import EdgeCore
import SMCBridge
import SwiftUI
import WidgetEngine

public struct PowerWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        public var showHistory = true
        public init() {}
    }

    public static let typeID = WidgetTypeID("edgedash.power")
    public static let displayName = "Power"
    public static let category = WidgetCategory.monitoring
    public static let supportedSizes = [
        GridSize(cols: 1, rows: 1), GridSize(cols: 2, rows: 1),
    ]

    public static func requiredMetrics(for config: Config) -> Set<MetricID> {
        [.systemPower]
    }

    @MainActor public static func makeView(config: Config, context: WidgetContext) -> AnyView {
        AnyView(PowerView(config: config, power: context.hub.store(for: .systemPower)))
    }

    @MainActor public static func makeConfigView(config: Binding<Config>) -> AnyView {
        AnyView(PowerConfigView(config: config))
    }
}

private struct PowerView: View {
    @Environment(\.theme) private var theme
    let config: PowerWidget.Config
    let power: MetricStore

    private var watts: Double? {
        if case .scalar(let v)? = power.latest { v } else { nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetTitle(text: "POWER", value: watts.map { String(format: "%.1f W", $0) })
            if let _ = watts {
                if config.showHistory {
                    SparklineView(history: power.history, color: theme.accentAlt.color)
                        .frame(maxHeight: .infinity)
                }
            } else {
                Text("Unavailable")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(theme.textSecondary.color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
    }
}

private struct PowerConfigView: View {
    @Binding var config: PowerWidget.Config

    var body: some View {
        Form {
            Toggle("History graph", isOn: $config.showHistory)
        }
    }
}
