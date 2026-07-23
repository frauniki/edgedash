import EdgeCore
import EdgeMetrics
import SwiftUI
import WidgetEngine

public struct GPUWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        public var showHistory = true
        public var showMemory = true
        public init() {}
    }

    public static let typeID = WidgetTypeID("edgedash.gpu")
    public static let displayName = "GPU"
    public static let category = WidgetCategory.monitoring
    public static let supportedSizes = [
        GridSize(cols: 1, rows: 1), GridSize(cols: 2, rows: 1), GridSize(cols: 2, rows: 2),
    ]

    public static func requiredMetrics(for config: Config) -> Set<MetricID> {
        config.showMemory ? [.gpuUsage, .gpuMemory] : [.gpuUsage]
    }

    @MainActor public static func makeView(config: Config, context: WidgetContext) -> AnyView {
        AnyView(GPUView(
            config: config,
            usage: context.hub.store(for: .gpuUsage),
            memory: context.hub.store(for: .gpuMemory),
            size: context.size
        ))
    }

    @MainActor public static func makeConfigView(config: Binding<Config>) -> AnyView {
        AnyView(GPUConfigView(config: config))
    }
}

private struct GPUView: View {
    @Environment(\.theme) private var theme
    let config: GPUWidget.Config
    let usage: MetricStore
    let memory: MetricStore
    let size: GridSize

    private var fraction: Double {
        if case .scalar(let v)? = usage.latest { v } else { 0 }
    }

    private var accent: Color {
        theme.gaugeColor(fraction).color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetTitle(text: "GPU", value: String(format: "%.0f%%", fraction * 100))
            if size.cols >= 2 || size.rows >= 2 {
                if config.showHistory {
                    SparklineView(history: usage.history, maxValue: 1, color: accent)
                        .frame(maxHeight: .infinity)
                }
                if config.showMemory, case .scalar(let bytes)? = memory.latest {
                    Text(String(format: "MEM %.1f GB", bytes / 1_073_741_824))
                        .font(.system(size: 13, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary.color)
                }
            } else {
                RingGauge(fraction: fraction, color: accent)
            }
        }
        .padding(14)
    }
}

private struct GPUConfigView: View {
    @Binding var config: GPUWidget.Config

    var body: some View {
        Form {
            Toggle("History graph", isOn: $config.showHistory)
            Toggle("GPU memory", isOn: $config.showMemory)
        }
    }
}
