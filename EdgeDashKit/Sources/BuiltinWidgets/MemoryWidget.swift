import EdgeCore
import EdgeMetrics
import SwiftUI
import WidgetEngine

public struct MemoryWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        public var showBreakdown = true
        public var showSwap = false
        public init() {}
    }

    public static let typeID = WidgetTypeID("edgedash.memory")
    public static let displayName = "Memory"
    public static let category = WidgetCategory.monitoring
    public static let supportedSizes = [
        GridSize(cols: 1, rows: 1), GridSize(cols: 2, rows: 1), GridSize(cols: 2, rows: 2),
    ]

    public static func requiredMetrics(for config: Config) -> Set<MetricID> {
        config.showBreakdown ? [.memoryUsage, .memoryBreakdown] : [.memoryUsage]
    }

    @MainActor public static func makeView(config: Config, context: WidgetContext) -> AnyView {
        AnyView(MemoryView(
            config: config,
            usage: context.hub.store(for: .memoryUsage),
            breakdown: context.hub.store(for: .memoryBreakdown),
            size: context.size
        ))
    }

    @MainActor public static func makeConfigView(config: Binding<Config>) -> AnyView {
        AnyView(MemoryConfigView(config: config))
    }
}

private struct MemoryView: View {
    @Environment(\.theme) private var theme
    let config: MemoryWidget.Config
    let usage: MetricStore
    let breakdown: MetricStore
    let size: GridSize

    private var fraction: Double {
        if case .scalar(let v)? = usage.latest { v } else { 0 }
    }

    private var details: [String: Double] {
        if case .composite(let v)? = breakdown.latest { v } else { [:] }
    }

    private var accent: Color {
        theme.gaugeColor(fraction, warn: 0.8, critical: 0.92).color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetTitle(text: "MEMORY", value: String(format: "%.0f%%", fraction * 100))
            if size.cols >= 2 || size.rows >= 2 {
                HStack(spacing: 14) {
                    RingGauge(fraction: fraction, color: accent)
                        .frame(maxWidth: 90)
                    if config.showBreakdown {
                        breakdownRows
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                RingGauge(fraction: fraction, color: accent)
            }
        }
        .padding(14)
    }

    private var breakdownRows: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("Used", details["used"])
            row("Wired", details["wired"])
            row("Compressed", details["compressed"])
            if config.showSwap {
                row("Swap", details["swapUsed"])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ bytes: Double?) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(theme.textSecondary.color)
            Spacer()
            Text(bytes.map(Self.gib) ?? "—")
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
        }
        .font(.system(size: 13, design: .rounded))
    }

    private static func gib(_ bytes: Double) -> String {
        String(format: "%.1f GB", bytes / 1_073_741_824)
    }
}

private struct MemoryConfigView: View {
    @Binding var config: MemoryWidget.Config

    var body: some View {
        Form {
            Toggle("Breakdown", isOn: $config.showBreakdown)
            Toggle("Swap", isOn: $config.showSwap)
        }
    }
}
