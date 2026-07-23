import EdgeCore
import SwiftUI
import WidgetEngine

/// M2 verification surface: live values + spark history for every registered
/// metric. Lives under a "Debug" tab until the real settings sidebar (M6).
public struct DebugMetricsView: View {
    private let hub: MetricHub
    private let ids: [MetricID]

    public init(hub: MetricHub, ids: [MetricID]) {
        self.hub = hub
        self.ids = ids
    }

    public var body: some View {
        List(ids, id: \.self) { id in
            MetricRow(id: id, store: hub.store(for: id))
        }
        .listStyle(.inset)
    }
}

private struct MetricRow: View {
    let id: MetricID
    let store: MetricStore

    var body: some View {
        HStack(spacing: 12) {
            Text(id.rawValue)
                .font(.system(.body, design: .monospaced))
                .frame(width: 140, alignment: .leading)
            SparklineView(history: store.history, color: .accentColor)
                .frame(width: 160, height: 24)
            Spacer()
            Text(Self.format(store.latest))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    static func format(_ value: MetricValue?) -> String {
        switch value {
        case .scalar(let v):
            v <= 1.0 ? String(format: "%.1f%%", v * 100) : String(format: "%.2f", v)
        case .perCore(let cores):
            cores.map { String(format: "%.0f", $0 * 100) }.joined(separator: " ")
        case .duplex(let inV, let outV):
            "↓\(Self.bytes(inV))/s ↑\(Self.bytes(outV))/s"
        case .composite(let dict):
            dict.sorted { $0.key < $1.key }
                .map { "\($0.key)=\(Self.compact($0.value))" }
                .joined(separator: " ")
        case nil:
            "—"
        }
    }

    private static func bytes(_ v: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .binary)
    }

    private static func compact(_ v: Double) -> String {
        v >= 1_000_000_000 ? String(format: "%.1fG", v / 1_073_741_824)
            : v >= 1_000_000 ? String(format: "%.0fM", v / 1_048_576)
            : v >= 1_000 ? String(format: "%.0fK", v / 1_024)
            : String(format: "%.2f", v)
    }
}

