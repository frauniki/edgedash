import EdgeCore
import EdgeMetrics
import SwiftUI
import WidgetEngine

public struct DiskWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        public var showIO = true
        public var showCapacity = true
        public var volumePath = "/"
        public init() {}

        /// Lenient decoding: adding fields must not reset saved configs.
        private enum CodingKeys: String, CodingKey { case showIO, showCapacity, volumePath }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            showIO = try container.decodeIfPresent(Bool.self, forKey: .showIO) ?? true
            showCapacity = try container.decodeIfPresent(Bool.self, forKey: .showCapacity) ?? true
            volumePath = try container.decodeIfPresent(String.self, forKey: .volumePath) ?? "/"
        }
    }

    public static let typeID = WidgetTypeID("edgedash.disk")
    public static var displayName: String {
        loc("Disk")
    }

    public static let category = WidgetCategory.monitoring
    public static let supportedSizes = [
        GridSize(cols: 1, rows: 1), GridSize(cols: 2, rows: 1), GridSize(cols: 2, rows: 2),
    ]

    public static func requiredMetrics(for config: Config) -> Set<MetricID> {
        var ids: Set<MetricID> = []
        if config.showCapacity { ids.insert(.diskCapacity(volume: config.volumePath)) }
        if config.showIO { ids.insert(.diskIO) }
        return ids
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
                    if config.showCapacity {
                        LabeledRing(fraction: fraction, color: ringColor, label: percentText)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        if config.showCapacity {
                            detailRow("Free", details["free"])
                            detailRow("Total", details["total"])
                        }
                        if config.showIO, let ioRates {
                            ioRow("Read", ioRates.read, theme.accent.color)
                            ioRow("Write", ioRates.write, theme.accentAlt.color)
                        }
                        Spacer(minLength: 4)
                        if config.showIO {
                            SparklineView(history: io.history, color: theme.accent.color)
                                .frame(height: config.showCapacity ? 36 : 60)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
            } else {
                // 1×1: ring (if wanted) on top, live access rates + sparkline.
                VStack(alignment: .leading, spacing: 5) {
                    if config.showCapacity {
                        LabeledRing(fraction: fraction, color: ringColor, label: percentText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity) // centered, not hugging the left
                    }
                    if config.showIO {
                        if let ioRates {
                            ioRow("Read", ioRates.read, theme.accent.color)
                            ioRow("Write", ioRates.write, theme.accentAlt.color)
                        }
                        SparklineView(history: io.history, color: theme.accent.color)
                            .frame(maxHeight: config.showCapacity ? 26 : .infinity)
                    }
                }
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
        ConfigForm {
            Picker(loc("Volume"), selection: $config.volumePath) {
                ForEach(volumes, id: \.path) { volume in
                    Text(volume.name).tag(volume.path)
                }
            }
            Toggle(loc("Capacity ring"), isOn: $config.showCapacity)
            Toggle(loc("Read/write rates"), isOn: $config.showIO)
        }
        .onAppear { volumes = DiskCapacityReader.mountedVolumes() }
    }
}
