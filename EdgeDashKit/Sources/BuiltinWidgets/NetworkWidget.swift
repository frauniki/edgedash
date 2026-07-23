import EdgeCore
import EdgeMetrics
import SwiftUI
import WidgetEngine

public struct NetworkWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        public var showAddress = true
        public var showIPv6 = false
        public var showPublicIP = true
        public var showPeaks = true
        public init() {}
    }

    public static let typeID = WidgetTypeID("edgedash.network")
    public static let displayName = "Network"
    public static let category = WidgetCategory.monitoring
    public static let supportedSizes = [
        GridSize(cols: 1, rows: 1), GridSize(cols: 2, rows: 1),
        GridSize(cols: 2, rows: 2), GridSize(cols: 4, rows: 2),
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

    @MainActor public static func makeConfigView(config: Binding<Config>, context: WidgetContext) -> AnyView {
        AnyView(NetworkConfigView(config: config))
    }
}

/// Public IP with a long-lived cache — fetched at most every 15 minutes and
/// only while a network widget wanting it is on screen.
@MainActor final class PublicIPCache {
    static let shared = PublicIPCache()
    private(set) var address: String?
    private var fetchedAt: Date?
    private var inFlight = false

    func refreshIfStale() async {
        if let fetchedAt, Date().timeIntervalSince(fetchedAt) < 900 { return }
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        var request = URLRequest(url: URL(string: "https://api.ipify.org")!)
        request.timeoutInterval = 5
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let text = String(data: data, encoding: .utf8), text.count < 64 {
            address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        fetchedAt = Date() // also backs off after failures
    }
}

private struct NetworkView: View {
    @Environment(\.theme) private var theme
    let config: NetworkWidget.Config
    let throughput: MetricStore
    let size: GridSize

    @State private var interfaceLine = ""
    @State private var ipv4 = ""
    @State private var ipv6 = ""
    @State private var publicIP = ""

    // MARK: - Data

    private var rates: (down: Double, up: Double) {
        if case .duplex(let inV, let outV)? = throughput.latest { (inV, outV) } else { (0, 0) }
    }

    private var pairs: [(up: Double, down: Double)] {
        throughput.history.compactMap {
            if case .duplex(let down, let up) = $0.value { (up: up, down: down) } else { nil }
        }
    }

    private var peaks: (up: Double, down: Double) {
        (up: pairs.map(\.up).max() ?? 0, down: pairs.map(\.down).max() ?? 0)
    }

    // MARK: - Layout

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if size.cols == 1 {
                compactHeader
            } else {
                header
            }
            MirroredBarHistory(
                pairs: pairs,
                capacity: throughput.history.capacity,
                upColor: theme.accentAlt.color,
                downColor: theme.accent.color
            )
            .frame(maxHeight: .infinity)
            if config.showPeaks, size.rows >= 2 {
                HStack(spacing: 16) {
                    LegendRow(color: theme.accentAlt.color, label: "peak up", value: ByteRate.text(peaks.up))
                    LegendRow(color: theme.accent.color, label: "peak down", value: ByteRate.text(peaks.down))
                }
            }
            if size.rows >= 2 {
                infoRows
            }
        }
        .padding(14)
        .task(id: taskKey) { await refreshInfo() }
    }

    /// 1×1: rates stacked under the title — the wide header doesn't fit.
    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NETWORK")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textSecondary.color)
                .kerning(1.5)
            rateColumn(value: rates.up, dot: theme.accentAlt.color, caption: "up")
            rateColumn(value: rates.down, dot: theme.accent.color, caption: "down")
        }
    }

    /// Big current-rate numbers with dot captions, iStat style.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("NETWORK")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textSecondary.color)
                .kerning(1.5)
            Spacer()
            rateColumn(value: rates.up, dot: theme.accentAlt.color, caption: "up")
            rateColumn(value: rates.down, dot: theme.accent.color, caption: "down")
        }
    }

    private func rateColumn(value: Double, dot: Color, caption: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(ByteRate.text(value))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
            Text(caption)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.textSecondary.color)
        }
    }

    @ViewBuilder private var infoRows: some View {
        VStack(alignment: .leading, spacing: 3) {
            if config.showAddress {
                infoRow(icon: "network", label: interfaceLine.isEmpty ? "offline" : interfaceLine, value: ipv4)
                if config.showIPv6, !ipv6.isEmpty {
                    infoRow(icon: "6.circle", label: "IPv6", value: ipv6)
                }
            }
            if config.showPublicIP {
                infoRow(icon: "globe", label: "Public", value: publicIP.isEmpty ? "—" : publicIP)
            }
        }
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary.color)
                .frame(width: 14)
            Text(label)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
            Spacer()
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12, design: .rounded))
    }

    // MARK: - Slow-changing info (never in the render path)

    private var taskKey: String {
        "\(config.showAddress)-\(config.showIPv6)-\(config.showPublicIP)"
    }

    private func refreshInfo() async {
        while !Task.isCancelled {
            if let interface = NetworkReader.primaryInterface() {
                interfaceLine = interface
                ipv4 = NetworkReader.ipv4Address(interface: interface) ?? "—"
                ipv6 = config.showIPv6 ? (NetworkReader.ipv6Address(interface: interface) ?? "") : ""
            } else {
                interfaceLine = ""
                ipv4 = ""
                ipv6 = ""
            }
            if config.showPublicIP {
                await PublicIPCache.shared.refreshIfStale()
                publicIP = PublicIPCache.shared.address ?? ""
            }
            try? await Task.sleep(for: .seconds(30))
        }
    }
}

private struct NetworkConfigView: View {
    @Binding var config: NetworkWidget.Config

    var body: some View {
        Form {
            Toggle("Interface / IP address", isOn: $config.showAddress)
            Toggle("IPv6 address", isOn: $config.showIPv6)
            Toggle("Public IP", isOn: $config.showPublicIP)
            Toggle("Peak rates", isOn: $config.showPeaks)
        }
    }
}
