import EdgeCore
import EdgeMetrics
import SwiftUI
import WidgetEngine

public struct DiskWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        public var showIO = true
        public var volumePath = "/"
        public init() {}
    }

    public static let typeID = WidgetTypeID("edgedash.disk")
    public static let displayName = "Disk"
    public static let category = WidgetCategory.monitoring
    public static let supportedSizes = [
        GridSize(cols: 1, rows: 1), GridSize(cols: 2, rows: 1), GridSize(cols: 2, rows: 2),
    ]

    public static func requiredMetrics(for config: Config) -> Set<MetricID> {
        let capacity = MetricID.diskCapacity(volume: config.volumePath)
        return config.showIO ? [capacity, .diskIO] : [capacity]
    }

    @MainActor public static func makeView(config: Config, context: WidgetContext) -> AnyView {
        AnyView(DiskView(
            config: config,
            capacity: context.hub.store(for: .diskCapacity(volume: config.volumePath)),
            io: context.hub.store(for: .diskIO),
            size: context.size
        ))
    }

    @MainActor public static func makeConfigView(config: Binding<Config>, context: WidgetContext) -> AnyView {
        AnyView(DiskConfigView(config: config))
    }
}

private struct DiskView: View {
    @Environment(\.theme) private var theme
    let config: DiskWidget.Config
    let capacity: MetricStore
    let io: MetricStore
    let size: GridSize

    private var details: [String: Double] {
        if case .composite(let v)? = capacity.latest { v } else { [:] }
    }

    private var fraction: Double {
        guard let used = details["used"], let total = details["total"], total > 0 else { return 0 }
        return used / total
    }

    private var ioRates: (read: Double, write: Double)? {
        if case .duplex(let inV, let outV)? = io.latest { (inV, outV) } else { nil }
    }

    private var ringColor: Color {
        theme.gaugeColor(fraction, warn: 0.8, critical: 0.92).color
    }

    private var percentText: String {
        String(format: "%.0f%%", fraction * 100)
    }

    private var volumeName: String {
        DiskCapacityReader.mountedVolumes()
            .first { $0.path == config.volumePath }?.name ?? config.volumePath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetTitle(
                text: config.volumePath == "/" ? "DISK" : "DISK · \(volumeName)",
                value: nil
            )
            if size.cols >= 2 || size.rows >= 2 {
                HStack(spacing: 18) {
                    LabeledRing(fraction: fraction, color: ringColor, label: percentText)
                    VStack(alignment: .leading, spacing: 4) {
                        detailRow("Free", details["free"])
                        detailRow("Total", details["total"])
                        if config.showIO, let ioRates {
                            ioRow("Read", ioRates.read, theme.accent.color)
                            ioRow("Write", ioRates.write, theme.accentAlt.color)
                        }
                        Spacer(minLength: 4)
                        if config.showIO {
                            SparklineView(history: io.history, color: theme.accent.color)
                                .frame(height: 36)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
            } else {
                LabeledRing(fraction: fraction, color: ringColor, label: percentText)
            }
        }
        .padding(14)
    }

    private func detailRow(_ label: String, _ bytes: Double?) -> some View {
        HStack {
            Text(label).foregroundStyle(theme.textSecondary.color)
            Spacer()
            Text(bytes.map { String(format: "%.0f GB", $0 / 1_000_000_000) } ?? "—")
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
        }
        .font(.system(size: 14, design: .rounded))
    }

    private func ioRow(_ label: String, _ rate: Double, _ color: Color) -> some View {
        HStack {
            Text(label).foregroundStyle(theme.textSecondary.color)
            Spacer()
            Text(ByteRate.text(rate))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .font(.system(size: 14, design: .rounded))
    }
}

private struct DiskConfigView: View {
    @Binding var config: DiskWidget.Config
    @State private var volumes: [(path: String, name: String)] = []

    var body: some View {
        Form {
            Picker("Volume", selection: $config.volumePath) {
                ForEach(volumes, id: \.path) { volume in
                    Text(volume.name).tag(volume.path)
                }
            }
            Toggle("Read/write rates", isOn: $config.showIO)
        }
        .onAppear { volumes = DiskCapacityReader.mountedVolumes() }
    }
}
