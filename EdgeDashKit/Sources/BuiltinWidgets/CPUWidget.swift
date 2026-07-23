import EdgeCore
import EdgeMetrics
import SwiftUI
import WidgetEngine

public struct CPUWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        public var showPerCore = true
        public var showHistory = true
        public var warnThreshold = 0.7
        public var criticalThreshold = 0.9
        public init() {}
    }

    public static let typeID = WidgetTypeID("edgedash.cpu")
    public static let displayName = "CPU"
    public static let category = WidgetCategory.monitoring
    public static let supportedSizes = [
        GridSize(cols: 1, rows: 1), GridSize(cols: 2, rows: 1),
        GridSize(cols: 2, rows: 2), GridSize(cols: 4, rows: 2),
    ]

    public static func requiredMetrics(for config: Config) -> Set<MetricID> {
        config.showPerCore ? [.cpuUsage, .cpuPerCore] : [.cpuUsage]
    }

    @MainActor public static func makeView(config: Config, context: WidgetContext) -> AnyView {
        AnyView(CPUView(
            config: config,
            usage: context.hub.store(for: .cpuUsage),
            perCore: context.hub.store(for: .cpuPerCore),
            size: context.size
        ))
    }

    @MainActor public static func makeConfigView(config: Binding<Config>) -> AnyView {
        AnyView(CPUConfigView(config: config))
    }
}

private struct CPUView: View {
    @Environment(\.theme) private var theme
    let config: CPUWidget.Config
    let usage: MetricStore
    let perCore: MetricStore
    let size: GridSize

    private var fraction: Double {
        if case .scalar(let v)? = usage.latest { v } else { 0 }
    }

    private var cores: [Double] {
        if case .perCore(let v)? = perCore.latest { v } else { [] }
    }

    private var accent: Color {
        theme.gaugeColor(fraction, warn: config.warnThreshold, critical: config.criticalThreshold).color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetTitle(text: "CPU", value: percentText)
            if size.rows >= 2 || size.cols >= 2 {
                if config.showHistory {
                    SparklineView(history: usage.history, maxValue: 1, color: accent)
                        .frame(maxHeight: .infinity)
                }
                if config.showPerCore, !cores.isEmpty {
                    CoreBars(cores: cores, color: accent)
                        .frame(height: size.rows >= 2 ? 32 : 20)
                }
            } else {
                RingGauge(fraction: fraction, color: accent)
                    .overlay(
                        Text(percentText)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(theme.textPrimary.color)
                    )
            }
        }
        .padding(14)
    }

    private var percentText: String {
        String(format: "%.0f%%", fraction * 100)
    }
}

private struct CPUConfigView: View {
    @Binding var config: CPUWidget.Config

    var body: some View {
        Form {
            Toggle("Per-core bars", isOn: $config.showPerCore)
            Toggle("History graph", isOn: $config.showHistory)
        }
    }
}

/// Common "TITLE          value" header line for monitoring widgets.
struct WidgetTitle: View {
    @Environment(\.theme) private var theme
    let text: String
    var value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textSecondary.color)
                .kerning(1.5)
            Spacer()
            if let value {
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary.color)
            }
        }
    }
}
