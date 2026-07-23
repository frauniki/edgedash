import EdgeCore
import EdgeMetrics
import SwiftUI
import WidgetEngine

public struct DiskWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        public var showIO = true
        public init() {}
    }

    public static let typeID = WidgetTypeID("edgedash.disk")
    public static let displayName = "Disk"
    public static let category = WidgetCategory.monitoring
    public static let supportedSizes = [
        GridSize(cols: 1, rows: 1), GridSize(cols: 2, rows: 1), GridSize(cols: 2, rows: 2),
    ]

    public static func requiredMetrics(for config: Config) -> Set<MetricID> {
        config.showIO ? [.diskCapacity, .diskIO] : [.diskCapacity]
    }

    @MainActor public static func makeView(config: Config, context: WidgetContext) -> AnyView {
        AnyView(DiskView(
            config: config,
            capacity: context.hub.store(for: .diskCapacity),
            io: context.hub.store(for: .diskIO),
            size: context.size
        ))
    }

    @MainActor public static func makeConfigView(config: Binding<Config>) -> AnyView {
        AnyView(DiskConfigView(config: config))
    }
}

private struct DiskView: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetTitle(text: "DISK", value: String(format: "%.0f%%", fraction * 100))
            if size.cols >= 2 || size.rows >= 2 {
                HStack(spacing: 14) {
                    RingGauge(fraction: fraction, color: GaugeColor.forFraction(fraction, warn: 0.8, critical: 0.92))
                        .frame(maxWidth: 90)
                    VStack(alignment: .leading, spacing: 3) {
                        detailRow("Free", details["free"])
                        detailRow("Total", details["total"])
                        if config.showIO, let ioRates {
                            ioRow("R", ioRates.read, .cyan)
                            ioRow("W", ioRates.write, .orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            } else {
                RingGauge(fraction: fraction, color: GaugeColor.forFraction(fraction, warn: 0.8, critical: 0.92))
            }
        }
        .padding(14)
    }

    private func detailRow(_ label: String, _ bytes: Double?) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(bytes.map { String(format: "%.0f GB", $0 / 1_000_000_000) } ?? "—")
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .font(.system(size: 13, design: .rounded))
    }

    private func ioRow(_ label: String, _ rate: Double, _ color: Color) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(ByteRate.text(rate))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .font(.system(size: 13, design: .rounded))
    }
}

private struct DiskConfigView: View {
    @Binding var config: DiskWidget.Config

    var body: some View {
        Form {
            Toggle("Read/write rates", isOn: $config.showIO)
        }
    }
}
