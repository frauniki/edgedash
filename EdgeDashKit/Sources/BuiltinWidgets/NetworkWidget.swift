import EdgeCore
import EdgeMetrics
import SwiftUI
import WidgetEngine

public struct NetworkWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        public var showAddress = true
        public init() {}
    }

    public static let typeID = WidgetTypeID("edgedash.network")
    public static let displayName = "Network"
    public static let category = WidgetCategory.monitoring
    public static let supportedSizes = [
        GridSize(cols: 2, rows: 1), GridSize(cols: 2, rows: 2), GridSize(cols: 4, rows: 2),
    ]

    public static func requiredMetrics(for config: Config) -> Set<MetricID> {
        [.networkThroughput]
    }

    @MainActor public static func makeView(config: Config, context: WidgetContext) -> AnyView {
        AnyView(NetworkView(
            config: config,
            throughput: context.hub.store(for: .networkThroughput),
            size: context.size
        ))
    }

    @MainActor public static func makeConfigView(config: Binding<Config>) -> AnyView {
        AnyView(NetworkConfigView(config: config))
    }
}

private struct NetworkView: View {
    @Environment(\.theme) private var theme
    let config: NetworkWidget.Config
    let throughput: MetricStore
    let size: GridSize
    // Interface/IP lookups hit SCDynamicStore — refreshed on a slow cadence,
    // never in the render path.
    @State private var addressLine = ""

    private var rates: (down: Double, up: Double) {
        if case .duplex(let inV, let outV)? = throughput.latest { (inV, outV) } else { (0, 0) }
    }

    private var downHistory: [Double] {
        throughput.history.compactMap {
            if case .duplex(let inV, _) = $0.value { inV } else { nil }
        }
    }

    private var upHistory: [Double] {
        throughput.history.compactMap {
            if case .duplex(_, let outV) = $0.value { outV } else { nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("NETWORK")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textSecondary.color)
                    .kerning(1.5)
                Spacer()
                rateLabel("↓", rates.down, theme.accent.color)
                rateLabel("↑", rates.up, theme.accentAlt.color)
            }
            ZStack {
                // Shared scale so up/down are visually comparable.
                let top = max(downHistory.max() ?? 0, upHistory.max() ?? 0, 1)
                let capacity = throughput.history.capacity
                SparklineView(values: downHistory, capacity: capacity, maxValue: top, color: theme.accent.color)
                SparklineView(values: upHistory, capacity: capacity, maxValue: top, color: theme.accentAlt.color)
            }
            .frame(maxHeight: .infinity)
            if config.showAddress, size.rows >= 2 {
                Text(addressLine)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.textSecondary.color)
            }
        }
        .padding(14)
        .task(id: config.showAddress) {
            guard config.showAddress else { return }
            while !Task.isCancelled {
                addressLine = Self.currentAddressLine()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func rateLabel(_ arrow: String, _ rate: Double, _ color: Color) -> some View {
        Text("\(arrow) \(ByteRate.text(rate))")
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
    }

    private static func currentAddressLine() -> String {
        guard let interface = NetworkReader.primaryInterface() else { return "offline" }
        let ip = NetworkReader.ipv4Address(interface: interface) ?? "–"
        return "\(interface)  \(ip)"
    }
}

private struct NetworkConfigView: View {
    @Binding var config: NetworkWidget.Config

    var body: some View {
        Form {
            Toggle("Interface / IP address", isOn: $config.showAddress)
        }
    }
}
