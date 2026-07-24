import EdgeCore
import SwiftUI
import WidgetEngine

public struct ClockWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        public var is24Hour = true
        public var showSeconds = true
        public var showDate = true
        public init() {}
    }

    public static let typeID = WidgetTypeID("edgedash.clock")
    public static var displayName: String {
        loc("Clock")
    }

    public static let category = WidgetCategory.utility
    public static let supportedSizes = [
        GridSize(cols: 1, rows: 1), GridSize(cols: 2, rows: 1), GridSize(cols: 2, rows: 2),
    ]

    public static func requiredMetrics(for config: Config) -> Set<MetricID> {
        []
    }

    @MainActor public static func makeView(config: Config, context: WidgetContext) -> AnyView {
        AnyView(ClockView(config: config))
    }

    @MainActor public static func makeConfigView(config: Binding<Config>, context: WidgetContext) -> AnyView {
        AnyView(ClockConfigView(config: config))
    }
}

private struct ClockView: View {
    @Environment(\.theme) private var theme
    let config: ClockWidget.Config

    var body: some View {
        TimelineView(.periodic(from: .now, by: config.showSeconds ? 1 : 60)) { timeline in
            VStack(spacing: 2) {
                Text(timeString(timeline.date))
                    .font(.system(size: 100, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.2)
                    .lineLimit(1)
                    .foregroundStyle(theme.textPrimary.color)
                if config.showDate {
                    Text(dateString(timeline.date))
                        .font(.system(size: 20, weight: .regular, design: .rounded))
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                        .foregroundStyle(theme.textSecondary.color)
                }
            }
            .padding(12)
        }
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = switch (config.is24Hour, config.showSeconds) {
        case (true, true): "HH:mm:ss"
        case (true, false): "HH:mm"
        case (false, true): "h:mm:ss a"
        case (false, false): "h:mm a"
        }
        return formatter.string(from: date)
    }

    private func dateString(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

private struct ClockConfigView: View {
    @Binding var config: ClockWidget.Config

    var body: some View {
        ConfigForm {
            Toggle(loc("24-hour"), isOn: $config.is24Hour)
            Toggle(loc("Show seconds"), isOn: $config.showSeconds)
            Toggle(loc("Show date"), isOn: $config.showDate)
        }
    }
}
