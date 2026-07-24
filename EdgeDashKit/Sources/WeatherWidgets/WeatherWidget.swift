import EdgeCore
import SwiftUI
import WidgetEngine

public struct WeatherWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        public enum Mode: String, Codable, Sendable {
            case auto, manual
        }

        public struct Place: Codable, Sendable, Equatable {
            public var name: String
            public var latitude: Double
            public var longitude: Double
        }

        public var mode: Mode = .auto
        public var place: Place?
        public var fahrenheit = false
        /// 1×1 squeezes the weekly list in under a small current-conditions
        /// row; off restores the big-temperature layout.
        public var compactWeekly = true

        public init() {}

        /// Lenient decoding: adding fields must not reset saved configs, and
        /// an unknown mode string degrades to .auto instead of throwing.
        private enum CodingKeys: String, CodingKey { case mode, place, fahrenheit, compactWeekly }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mode = (try? container.decodeIfPresent(String.self, forKey: .mode))
                .flatMap(Mode.init(rawValue:)) ?? .auto
            place = try? container.decodeIfPresent(Place.self, forKey: .place)
            fahrenheit = (try? container.decodeIfPresent(Bool.self, forKey: .fahrenheit)) ?? false
            compactWeekly = (try? container.decodeIfPresent(Bool.self, forKey: .compactWeekly)) ?? true
        }
    }

    public static let typeID = WidgetTypeID("edgedash.weather")
    public static var displayName: String {
        loc("Weather")
    }

    public static let category = WidgetCategory.utility
    public static let supportedSizes = [
        GridSize(cols: 1, rows: 1), GridSize(cols: 2, rows: 1),
        GridSize(cols: 2, rows: 2), GridSize(cols: 4, rows: 2),
    ]

    public static func requiredMetrics(for config: Config) -> Set<MetricID> {
        []
    }

    @MainActor public static func makeView(config: Config, context: WidgetContext) -> AnyView {
        AnyView(WeatherView(
            config: config,
            monitor: context.services.resolve(WeatherMonitor.self),
            size: context.size
        ))
    }

    @MainActor public static func makeConfigView(config: Binding<Config>, context: WidgetContext) -> AnyView {
        AnyView(WeatherConfigView(
            config: config,
            monitor: context.services.resolve(WeatherMonitor.self)
        ))
    }
}

// MARK: - View

private struct WeatherView: View {
    @Environment(\.theme) private var theme
    let config: WeatherWidget.Config
    let monitor: WeatherMonitor?
    let size: GridSize

    private var spec: WeatherMonitor.LocationSpec? {
        switch config.mode {
        case .manual:
            guard let place = config.place else { return nil }
            return WeatherMonitor.LocationSpec(
                latitude: place.latitude, longitude: place.longitude, label: place.name
            )
        case .auto:
            guard case .located(let latitude, let longitude) = monitor?.location.state else { return nil }
            return WeatherMonitor.LocationSpec(
                latitude: latitude, longitude: longitude,
                label: monitor?.location.placeLabel ?? "Current Location"
            )
        }
    }

    private var snapshot: WeatherSnapshot? {
        spec.flatMap { monitor?.snapshots[$0.key] }
    }

    private var title: String {
        spec.map { "WEATHER · \($0.label)" } ?? "WEATHER"
    }

    var body: some View {
        Group {
            if let snapshot {
                content(snapshot)
            } else {
                emptyState
            }
        }
        .padding(14)
        .task(id: taskID) { await pollLoop() }
    }

    /// Restarts the loop when settings change what we point at; auto-mode
    /// location changes are picked up inside the loop via `spec`.
    private var taskID: String {
        "\(config.mode.rawValue)|\(config.place?.latitude ?? 0),\(config.place?.longitude ?? 0)"
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            if config.mode == .auto { monitor?.location.requestIfNeeded() }
            if let spec { monitor?.ensureFresh(spec) }
            // Tight cadence until first paint (monitor cooldowns keep it
            // cheap), then a relaxed staleness check.
            try? await Task.sleep(for: .seconds(snapshot == nil ? 2 : 60))
        }
    }

    // MARK: Layouts

    @ViewBuilder private func content(_ snapshot: WeatherSnapshot) -> some View {
        switch (size.cols, size.rows) {
        case (1, _):
            compactLayout(snapshot)
        case (_, 1):
            wideLayout(snapshot)
        case (2, _):
            tallLayout(snapshot)
        default:
            fullLayout(snapshot)
        }
    }

    /// 1×1: weekly list under a small current row, or (compactWeekly off)
    /// icon + big temperature + today's range.
    @ViewBuilder private func compactLayout(_ snapshot: WeatherSnapshot) -> some View {
        if config.compactWeekly {
            VStack(alignment: .leading, spacing: 6) {
                WidgetTitle(text: title)
                HStack(spacing: 8) {
                    conditionIcon(snapshot.current, points: 22)
                    Text(degrees(snapshot.current.temperature))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary.color)
                    Spacer(minLength: 0)
                    highLow(snapshot)
                }
                dailyList(snapshot, compact: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                WidgetTitle(text: "WEATHER")
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    conditionIcon(snapshot.current, points: 38)
                    Text(degrees(snapshot.current.temperature))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary.color)
                }
                highLow(snapshot)
                Text(spec?.label ?? "")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.textSecondary.color)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 2×1: current block + five-day strip.
    private func wideLayout(_ snapshot: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetTitle(text: title)
            HStack(alignment: .center, spacing: 14) {
                currentBlock(snapshot)
                Spacer(minLength: 8)
                HStack(spacing: 12) {
                    ForEach(snapshot.daily.prefix(5), id: \.date) { day in
                        dayColumn(day)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// 2×2: current + 24h strip + weekly rows.
    private func tallLayout(_ snapshot: WeatherSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetTitle(text: title)
            currentBlock(snapshot)
            ForecastStrip(hours: snapshot.hourly, fahrenheit: config.fahrenheit)
                .frame(minHeight: 70, maxHeight: 140)
            dailyList(snapshot)
        }
    }

    /// 4×2: current + hourly graph left, week column right.
    private func fullLayout(_ snapshot: WeatherSnapshot) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                WidgetTitle(text: title)
                currentBlock(snapshot)
                ForecastStrip(hours: snapshot.hourly, fahrenheit: config.fahrenheit)
                    .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity)
            dailyList(snapshot)
                .frame(width: 330)
        }
    }

    // MARK: Pieces

    private func currentBlock(_ snapshot: WeatherSnapshot) -> some View {
        HStack(spacing: 12) {
            conditionIcon(snapshot.current, points: 42)
            Text(degrees(snapshot.current.temperature))
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(WeatherCondition.text(code: snapshot.current.code))
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textPrimary.color)
                Text("Feels \(degrees(snapshot.current.apparentTemperature))")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.textSecondary.color)
                Text("\(Int(snapshot.current.humidity))%  ·  \(String(format: "%.1f", snapshot.current.windSpeed)) m/s")
                    .font(.system(size: 12, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary.color)
            }
        }
    }

    private func highLow(_ snapshot: WeatherSnapshot) -> some View {
        HStack(spacing: 10) {
            if let high = snapshot.todayHigh {
                Text("H \(degrees(high))")
                    .foregroundStyle(theme.textPrimary.color)
            }
            if let low = snapshot.todayLow {
                Text("L \(degrees(low))")
                    .foregroundStyle(theme.textSecondary.color)
            }
        }
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .monospacedDigit()
    }

    private func dayColumn(_ day: WeatherSnapshot.Day) -> some View {
        VStack(spacing: 3) {
            Text(day.weekday)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(theme.textSecondary.color)
            Image(systemName: WeatherCondition.symbol(code: day.code, isDay: true))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 16))
                .frame(height: 20)
            Text(degrees(day.high))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
            Text(degrees(day.low))
                .font(.system(size: 11, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary.color)
        }
    }

    /// Weekly rows with a temperature-range bar spanning the week's extremes.
    /// `compact` tightens every column for the 1×1 cell (and drops the
    /// precipitation column — there is no width for it).
    private func dailyList(_ snapshot: WeatherSnapshot, compact: Bool = false) -> some View {
        let weekLow = snapshot.daily.map(\.low).min() ?? 0
        let weekHigh = snapshot.daily.map(\.high).max() ?? 1
        return VStack(spacing: 0) {
            ForEach(Array(snapshot.daily.enumerated()), id: \.element.date) { index, day in
                HStack(spacing: compact ? 6 : 8) {
                    Text(index == 0 ? "Today" : day.weekday)
                        .font(.system(size: compact ? 11 : 12, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.textSecondary.color)
                        .frame(width: compact ? 38 : 44, alignment: .leading)
                    Image(systemName: WeatherCondition.symbol(code: day.code, isDay: true))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: compact ? 12 : 13))
                        .frame(width: compact ? 18 : 22)
                    if !compact {
                        Text(day.precipitationProbability >= 20 ? "\(Int(day.precipitationProbability))%" : "")
                            .font(.system(size: 10, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(theme.accentAlt.color)
                            .frame(width: 30, alignment: .leading)
                    }
                    Text(degrees(day.low))
                        .font(.system(size: compact ? 11 : 12, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary.color)
                        .frame(width: compact ? 28 : 32, alignment: .trailing)
                    TempRangeBar(
                        low: day.low, high: day.high,
                        weekLow: weekLow, weekHigh: weekHigh,
                        color: theme.accent.color, track: theme.track.color
                    )
                    .frame(height: 4)
                    Text(degrees(day.high))
                        .font(.system(size: compact ? 11 : 12, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary.color)
                        .frame(width: compact ? 28 : 32, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func conditionIcon(_ current: WeatherSnapshot.Current, points: CGFloat) -> some View {
        Image(systemName: WeatherCondition.symbol(code: current.code, isDay: current.isDay))
            .symbolRenderingMode(.multicolor)
            .font(.system(size: points))
    }

    private func degrees(_ celsius: Double) -> String {
        WeatherUnits.degrees(celsius, fahrenheit: config.fahrenheit)
    }

    // MARK: Empty / error states

    private var statusText: String {
        guard let monitor else { return "Weather unavailable" }
        if config.mode == .manual, config.place == nil {
            return "Choose a city in settings"
        }
        if config.mode == .auto {
            switch monitor.location.state {
            case .denied:
                return "Location access denied —\nset a city in settings"
            case .failed:
                return "No location fix —\nset a city in settings"
            case .waitingForPermission:
                return "Waiting for location permission —\nor set a city in settings"
            case .idle, .locating:
                return "Locating…"
            case .located:
                break
            }
        }
        if let spec, monitor.failures[spec.key] != nil {
            return "Weather unavailable"
        }
        return "Loading…"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            WidgetTitle(text: "WEATHER")
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "cloud.sun")
                        .font(.system(size: 26))
                        .foregroundStyle(theme.textSecondary.color)
                    Text(statusText)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.textSecondary.color)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            Spacer()
        }
    }
}

// MARK: - Components

/// 24-hour temperature curve with precipitation-probability bars and hour
/// labels. Forecast data, not MetricStore history — hence its own canvas
/// rather than StackedAreaHistory.
struct ForecastStrip: View {
    @Environment(\.theme) private var theme
    let hours: [WeatherSnapshot.Hour]
    let fahrenheit: Bool

    var body: some View {
        Canvas { context, size in
            guard hours.count > 1 else { return }
            let labelHeight: CGFloat = 14
            let chartHeight = size.height - labelHeight
            guard chartHeight > 10 else { return }

            let temps = hours.map(\.temperature)
            let minT = temps.min()!
            let maxT = temps.max()!
            let span = max(maxT - minT, 1)
            let stepX = size.width / CGFloat(hours.count - 1)
            let x = { (index: Int) in CGFloat(index) * stepX }
            // Curve occupies a middle band: headroom for the max label,
            // floor space so precip bars don't collide with the line.
            let y = { (temperature: Double) in
                chartHeight * 0.16 + chartHeight * 0.56 * CGFloat(1 - (temperature - minT) / span)
            }

            for (index, hour) in hours.enumerated() where hour.precipitationProbability > 0 {
                let barHeight = chartHeight * 0.26 * CGFloat(hour.precipitationProbability / 100)
                let rect = CGRect(
                    x: x(index) - stepX * 0.28, y: chartHeight - barHeight,
                    width: stepX * 0.56, height: barHeight
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1.5),
                    with: .color(theme.accentAlt.color.opacity(0.4))
                )
            }

            var line = Path()
            for (index, hour) in hours.enumerated() {
                let point = CGPoint(x: x(index), y: y(hour.temperature))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: x(hours.count - 1), y: chartHeight))
            fill.addLine(to: CGPoint(x: 0, y: chartHeight))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(
                Gradient(colors: [theme.accent.color.opacity(0.22), theme.accent.color.opacity(0.02)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: chartHeight)
            ))
            if theme.glowStrength > 0 {
                var glow = context
                glow.addFilter(.shadow(color: theme.accent.color.opacity(theme.glowStrength), radius: 4))
                glow.stroke(line, with: .color(theme.accent.color), lineWidth: 1.5)
            } else {
                context.stroke(line, with: .color(theme.accent.color), lineWidth: 1.5)
            }

            // Warmest/coolest hour annotations.
            if let maxIndex = temps.indices.max(by: { temps[$0] < temps[$1] }) {
                context.draw(
                    label(degrees(temps[maxIndex]), color: theme.textPrimary.color),
                    at: CGPoint(x: min(max(x(maxIndex), 12), size.width - 12), y: y(temps[maxIndex]) - 9),
                    anchor: .center
                )
            }
            if let minIndex = temps.indices.min(by: { temps[$0] < temps[$1] }) {
                context.draw(
                    label(degrees(temps[minIndex]), color: theme.textSecondary.color),
                    at: CGPoint(x: min(max(x(minIndex), 12), size.width - 12), y: y(temps[minIndex]) + 10),
                    anchor: .center
                )
            }

            for (index, hour) in hours.enumerated() where index % 6 == 0 {
                context.draw(
                    Text(hour.hourLabel)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(theme.textSecondary.color),
                    at: CGPoint(x: min(max(x(index), 6), size.width - 6), y: size.height - labelHeight / 2),
                    anchor: .center
                )
            }
        }
    }

    private func label(_ text: String, color: Color) -> Text {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(color)
    }

    private func degrees(_ celsius: Double) -> String {
        WeatherUnits.degrees(celsius, fahrenheit: fahrenheit)
    }
}

/// One day's low–high span positioned within the week's extremes.
private struct TempRangeBar: View {
    let low: Double
    let high: Double
    let weekLow: Double
    let weekHigh: Double
    let color: Color
    let track: Color

    var body: some View {
        GeometryReader { geo in
            let span = max(weekHigh - weekLow, 1)
            let start = CGFloat((low - weekLow) / span) * geo.size.width
            let end = CGFloat((high - weekLow) / span) * geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(color)
                    .frame(width: max(end - start, 4))
                    .offset(x: start)
            }
        }
    }
}

// MARK: - Config UI

private struct WeatherConfigView: View {
    @Binding var config: WeatherWidget.Config
    let monitor: WeatherMonitor?
    @State private var query = ""
    @State private var results: [GeocodedPlace] = []
    @State private var searching = false
    @State private var searchError: String?

    var body: some View {
        ConfigForm {
            Picker(loc("Location"), selection: $config.mode) {
                Text("Current location", bundle: Bundle.module).tag(WeatherWidget.Config.Mode.auto)
                Text("Fixed city", bundle: Bundle.module).tag(WeatherWidget.Config.Mode.manual)
            }
            if config.mode == .auto {
                if monitor?.location.state == .denied {
                    Text("Location access is denied. Allow EdgeDash under System Settings › Privacy & Security › Location Services, or switch to a fixed city.", bundle: Bundle.module)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField(loc("Search city"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                if searching {
                    ProgressView().controlSize(.small)
                }
                if let searchError {
                    Text(searchError).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(results) { place in
                    Button {
                        config.place = .init(
                            name: place.name, latitude: place.latitude, longitude: place.longitude
                        )
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(place.name)
                                if !place.detail.isEmpty {
                                    Text(place.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if config.place?.latitude == place.latitude,
                               config.place?.longitude == place.longitude
                            {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let place = config.place {
                    Text("Selected: \(place.name)", bundle: Bundle.module)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(loc("Fahrenheit"), isOn: $config.fahrenheit)
            Toggle(loc("Weekly forecast in 1×1"), isOn: $config.compactWeekly)
        }
    }

    private func search() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        searching = true
        searchError = nil
        Task {
            defer { searching = false }
            do {
                results = try await OpenMeteoClient.geocode(trimmed)
                if results.isEmpty { searchError = loc("No matches") }
            } catch {
                searchError = loc("Search failed — check your connection")
            }
        }
    }
}
