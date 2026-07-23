import EdgeCore
import EdgeMetrics
import SwiftUI
import WidgetEngine

public struct MemoryWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        public var showBreakdown = true
        public var showSwap = true
        public var showPressureRing = true
        public var showProcesses = true
        public var processCount = 3
        public init() {}
    }

    public static let typeID = WidgetTypeID("edgedash.memory")
    public static let displayName = "Memory"
    public static let category = WidgetCategory.monitoring
    public static let supportedSizes = [
        GridSize(cols: 1, rows: 1), GridSize(cols: 2, rows: 1), GridSize(cols: 2, rows: 2),
    ]

    public static func requiredMetrics(for config: Config) -> Set<MetricID> {
        var ids: Set<MetricID> = [.memoryUsage, .memoryBreakdown]
        if config.showPressureRing { ids.formUnion([.memoryPressure, .memoryPressurePercent]) }
        if config.showProcesses { ids.insert(.topProcessesMemory) }
        return ids
    }

    @MainActor public static func makeView(config: Config, context: WidgetContext) -> AnyView {
        AnyView(MemoryView(
            config: config,
            usage: context.hub.store(for: .memoryUsage),
            breakdown: context.hub.store(for: .memoryBreakdown),
            pressure: context.hub.store(for: .memoryPressure),
            pressurePercent: context.hub.store(for: .memoryPressurePercent),
            processes: context.hub.store(for: .topProcessesMemory),
            size: context.size
        ))
    }

    @MainActor public static func makeConfigView(config: Binding<Config>, context: WidgetContext) -> AnyView {
        AnyView(MemoryConfigView(config: config))
    }
}

private struct MemoryView: View {
    @Environment(\.theme) private var theme
    let config: MemoryWidget.Config
    let usage: MetricStore
    let breakdown: MetricStore
    let pressure: MetricStore
    let pressurePercent: MetricStore
    let processes: MetricStore
    let size: GridSize

    // MARK: - Data

    private var fraction: Double {
        if case .scalar(let v)? = usage.latest { v } else { 0 }
    }

    private var details: [String: Double] {
        if case .composite(let v)? = breakdown.latest { v } else { [:] }
    }

    private var total: Double { max(details["total"] ?? 1, 1) }

    /// Ring segments in iStat order: app / wired / compressed.
    private var segments: [(fraction: Double, color: Color)] {
        [
            (fraction: (details["app"] ?? 0) / total, color: theme.accent.color),
            (fraction: (details["wired"] ?? 0) / total, color: theme.critical.color),
            (fraction: (details["compressed"] ?? 0) / total, color: theme.accentAlt.color),
        ]
    }

    private var pressureFraction: Double {
        if case .scalar(let v)? = pressurePercent.latest { v } else { 0 }
    }

    private var pressureColor: Color {
        guard case .scalar(let level)? = pressure.latest else { return theme.accent.color }
        return level >= 4 ? theme.critical.color : level >= 2 ? theme.warn.color : theme.accent.color
    }

    private var topProcesses: [(name: String, bytes: Double)] {
        guard config.showProcesses, case .composite(let values)? = processes.latest else { return [] }
        return values.sorted { $0.value > $1.value }
            .prefix(max(1, config.processCount))
            .map { (name: $0.key, bytes: $0.value) }
    }

    // MARK: - Layout

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            WidgetTitle(text: "MEMORY", value: size.rows >= 2 ? nil : String(format: "%.0f%%", fraction * 100))
            if size.rows >= 2 {
                rings
                if config.showBreakdown {
                    legendRows
                }
                if !topProcesses.isEmpty {
                    Divider().overlay(theme.track.color).padding(.vertical, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(topProcesses, id: \.name) { process in
                            ProcessRow(name: process.name, value: Self.gib(process.bytes))
                        }
                    }
                }
                Spacer(minLength: 0)
                if config.showSwap {
                    swapMeter
                }
            } else if size.cols >= 2 {
                HStack(spacing: 18) {
                    SegmentedRing(
                        segments: segments,
                        value: String(format: "%.0f%%", fraction * 100),
                        caption: "MEMORY"
                    )
                    if config.showBreakdown { legendRows }
                }
                .frame(maxHeight: .infinity)
            } else {
                // 1×1: same content as 2×1, stacked — the cell is just as
                // tall, only half as wide.
                VStack(spacing: 7) {
                    SegmentedRing(
                        segments: segments,
                        value: String(format: "%.0f%%", fraction * 100),
                        caption: "MEMORY"
                    )
                    .frame(maxHeight: .infinity)
                    if config.showBreakdown { legendRows }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
    }

    private var rings: some View {
        HStack(spacing: 20) {
            if config.showPressureRing {
                SegmentedRing(
                    segments: [(fraction: pressureFraction, color: pressureColor)],
                    value: String(format: "%.0f%%", pressureFraction * 100),
                    caption: "PRESSURE"
                )
            }
            SegmentedRing(
                segments: segments,
                value: String(format: "%.0f%%", fraction * 100),
                caption: "MEMORY"
            )
        }
        .frame(maxHeight: 150)
        .frame(maxWidth: .infinity)
    }

    private var legendRows: some View {
        VStack(alignment: .leading, spacing: 3) {
            LegendRow(color: theme.accent.color, label: "App", value: Self.gib(details["app"] ?? 0))
            LegendRow(color: theme.critical.color, label: "Wired", value: Self.gib(details["wired"] ?? 0))
            LegendRow(color: theme.accentAlt.color, label: "Compressed", value: Self.gib(details["compressed"] ?? 0))
            LegendRow(color: theme.textSecondary.color.opacity(0.5), label: "Free", value: Self.gib(details["free"] ?? 0))
        }
    }

    private var swapMeter: some View {
        let used = details["swapUsed"] ?? 0
        let swapTotal = details["swapTotal"] ?? 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Swap").foregroundStyle(theme.textSecondary.color)
                Spacer()
                Text("\(Self.gib(used)) / \(Self.gib(swapTotal))")
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary.color)
            }
            .font(.system(size: 13, design: .rounded))
            MeterBar(
                fraction: swapTotal > 0 ? used / swapTotal : 0,
                color: theme.accent.color
            )
        }
    }

    static func gib(_ bytes: Double) -> String {
        String(format: "%.1f GB", bytes / 1_073_741_824)
    }
}

private struct MemoryConfigView: View {
    @Binding var config: MemoryWidget.Config

    var body: some View {
        Form {
            Toggle("Breakdown", isOn: $config.showBreakdown)
            Toggle("Pressure ring", isOn: $config.showPressureRing)
            Toggle("Swap", isOn: $config.showSwap)
            Toggle("Top processes", isOn: $config.showProcesses)
            Stepper("Processes: \(config.processCount)", value: $config.processCount, in: 1...8)
        }
    }
}
