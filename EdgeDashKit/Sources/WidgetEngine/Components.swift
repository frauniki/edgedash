import EdgeCore
import SwiftUI

/// Shared drawing components for widgets. Canvas-based — no Swift Charts on
/// the per-second hot path. Track colors and glow come from the theme; the
/// data color is passed by the widget (it encodes meaning: accent, warn…).

public struct SparklineView: View {
    @Environment(\.theme) private var theme
    let values: [Double]
    let capacity: Int
    var maxValue: Double?
    var color: Color

    public init(history: RingBuffer<MetricPoint>, maxValue: Double? = nil, color: Color) {
        self.values = history.compactMap { Self.scalarize($0.value) }
        self.capacity = history.capacity
        self.maxValue = maxValue
        self.color = color
    }

    public init(values: [Double], capacity: Int? = nil, maxValue: Double? = nil, color: Color) {
        self.values = values
        self.capacity = capacity ?? values.count
        self.maxValue = maxValue
        self.color = color
    }

    public var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = max(maxValue ?? values.max() ?? 1, 0.0001)
            // Fixed horizontal scale from buffer CAPACITY: the graph grows in
            // from the right edge at constant density instead of stretching a
            // few points across the full width and shrinking as data arrives.
            let stepX = size.width / CGFloat(max(capacity - 1, 1))
            let startX = size.width - CGFloat(values.count - 1) * stepX

            var line = Path()
            for (i, v) in values.enumerated() {
                let point = CGPoint(
                    x: startX + CGFloat(i) * stepX,
                    y: size.height * (1 - CGFloat(min(v / top, 1)))
                )
                i == 0 ? line.move(to: point) : line.addLine(to: point)
            }

            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: startX, y: size.height))
            fill.closeSubpath()

            context.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(0.30), color.opacity(0.02)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            ))
            if theme.glowStrength > 0 {
                var glowContext = context
                glowContext.addFilter(.shadow(
                    color: color.opacity(theme.glowStrength),
                    radius: 4
                ))
                glowContext.stroke(line, with: .color(color), lineWidth: 1.5)
            } else {
                context.stroke(line, with: .color(color), lineWidth: 1.5)
            }
        }
    }

    public static func scalarize(_ value: MetricValue) -> Double? {
        switch value {
        case .scalar(let v): v
        case .perCore(let cores): cores.isEmpty ? nil : cores.reduce(0, +) / Double(cores.count)
        case .duplex(let inV, let outV): inV + outV
        case .composite: nil
        }
    }
}

/// Circular utilization gauge: 270° arc, gradient progress stroke with glow.
public struct RingGauge: View {
    @Environment(\.theme) private var theme
    let fraction: Double
    var color: Color

    public init(fraction: Double, color: Color) {
        self.fraction = min(max(fraction, 0), 1)
        self.color = color
    }

    public var body: some View {
        Canvas { context, size in
            let lineWidth = max(min(size.width, size.height) * 0.10, 4)
            let radius = (min(size.width, size.height) - lineWidth) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let start = Angle.degrees(135)
            let full = Angle.degrees(270)

            var track = Path()
            track.addArc(center: center, radius: radius, startAngle: start, endAngle: start + full, clockwise: false)
            context.stroke(track, with: .color(theme.track.color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            guard fraction > 0.001 else { return }
            var progress = Path()
            progress.addArc(center: center, radius: radius, startAngle: start, endAngle: start + full * fraction, clockwise: false)
            let shading = GraphicsContext.Shading.conicGradient(
                Gradient(colors: [color.opacity(0.55), color]),
                center: center,
                angle: start
            )
            if theme.glowStrength > 0 {
                var glowContext = context
                glowContext.addFilter(.shadow(color: color.opacity(theme.glowStrength * 0.9), radius: 5))
                glowContext.stroke(progress, with: shading, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            } else {
                context.stroke(progress, with: shading, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            }
        }
    }
}

/// Ring gauge with the value rendered in its center, font scaled to the
/// ring's size. Sizes itself to fill available space (square).
public struct LabeledRing: View {
    @Environment(\.theme) private var theme
    let fraction: Double
    var color: Color
    var label: String

    public init(fraction: Double, color: Color, label: String) {
        self.fraction = fraction
        self.color = color
        self.label = label
    }

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            RingGauge(fraction: fraction, color: color)
                .overlay(
                    Text(label)
                        .font(.system(size: side * 0.24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(theme.textPrimary.color)
                )
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Compact per-core utilization bars.
public struct CoreBars: View {
    @Environment(\.theme) private var theme
    let cores: [Double]
    var color: Color

    public init(cores: [Double], color: Color) {
        self.cores = cores
        self.color = color
    }

    public var body: some View {
        Canvas { context, size in
            guard !cores.isEmpty else { return }
            let gap: CGFloat = 2
            let barW = (size.width - gap * CGFloat(cores.count - 1)) / CGFloat(cores.count)
            for (i, v) in cores.enumerated() {
                let x = CGFloat(i) * (barW + gap)
                let track = Path(roundedRect: CGRect(x: x, y: 0, width: barW, height: size.height), cornerRadius: 1.5)
                context.fill(track, with: .color(theme.track.color))
                let h = size.height * CGFloat(min(max(v, 0), 1))
                if h > 0.5 {
                    let bar = Path(roundedRect: CGRect(x: x, y: size.height - h, width: barW, height: h), cornerRadius: 1.5)
                    context.fill(bar, with: .linearGradient(
                        Gradient(colors: [color, color.opacity(0.6)]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: size.height)
                    ))
                }
            }
        }
    }
}

/// iStat-style stacked bar histogram: two series stacked per sample
/// (e.g. CPU user + system), rendered as vertical bars.
/// Stacked two-series line chart (user + system on top), filled to the
/// baseline in sparkline style. Capacity-based density, newest at the right.
public struct StackedAreaHistory: View {
    @Environment(\.theme) private var theme
    let pairs: [(bottom: Double, top: Double)] // fractions of full height
    let capacity: Int
    var bottomColor: Color
    var topColor: Color

    public init(pairs: [(bottom: Double, top: Double)], capacity: Int, bottomColor: Color, topColor: Color) {
        self.pairs = pairs
        self.capacity = capacity
        self.bottomColor = bottomColor
        self.topColor = topColor
    }

    public var body: some View {
        Canvas { context, size in
            guard pairs.count > 1 else { return }
            let stepX = size.width / CGFloat(max(capacity - 1, 1))
            let startX = size.width - CGFloat(pairs.count - 1) * stepX
            let x = { (i: Int) in startX + CGFloat(i) * stepX }
            let y = { (fraction: Double) in size.height * (1 - CGFloat(min(max(fraction, 0), 1))) }

            var bottomLine = Path()
            var stackedLine = Path()
            for (i, pair) in pairs.enumerated() {
                let bottomPoint = CGPoint(x: x(i), y: y(pair.bottom))
                let stackedPoint = CGPoint(x: x(i), y: y(pair.bottom + pair.top))
                if i == 0 {
                    bottomLine.move(to: bottomPoint)
                    stackedLine.move(to: stackedPoint)
                } else {
                    bottomLine.addLine(to: bottomPoint)
                    stackedLine.addLine(to: stackedPoint)
                }
            }

            // Fill between the stacked line and the bottom line, then the
            // bottom line down to the baseline.
            var stackedFill = stackedLine
            for (i, pair) in pairs.enumerated().reversed() {
                stackedFill.addLine(to: CGPoint(x: x(i), y: y(pair.bottom)))
            }
            stackedFill.closeSubpath()
            context.fill(stackedFill, with: .color(topColor.opacity(0.18)))

            var bottomFill = bottomLine
            bottomFill.addLine(to: CGPoint(x: size.width, y: size.height))
            bottomFill.addLine(to: CGPoint(x: startX, y: size.height))
            bottomFill.closeSubpath()
            context.fill(bottomFill, with: .linearGradient(
                Gradient(colors: [bottomColor.opacity(0.30), bottomColor.opacity(0.02)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            ))

            stroke(line: stackedLine, color: topColor, in: context)
            stroke(line: bottomLine, color: bottomColor, in: context)
        }
    }

    private func stroke(line: Path, color: Color, in context: GraphicsContext) {
        if theme.glowStrength > 0 {
            var glowContext = context
            glowContext.addFilter(.shadow(color: color.opacity(theme.glowStrength), radius: 4))
            glowContext.stroke(line, with: .color(color), lineWidth: 1.5)
        } else {
            context.stroke(line, with: .color(color), lineWidth: 1.5)
        }
    }
}

/// Full-circle ring whose progress is split into colored segments (iStat's
/// memory ring: app + wired + compressed), with a big centered value and a
/// small caption beneath it. Sizes itself square.
public struct SegmentedRing: View {
    @Environment(\.theme) private var theme
    let segments: [(fraction: Double, color: Color)]
    let value: String
    let caption: String

    public init(segments: [(fraction: Double, color: Color)], value: String, caption: String) {
        self.segments = segments
        self.value = value
        self.caption = caption
    }

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            Canvas { context, size in
                let lineWidth = max(side * 0.09, 4)
                let radius = (side - lineWidth) / 2
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                var track = Path()
                track.addArc(center: center, radius: radius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
                context.stroke(track, with: .color(theme.track.color), lineWidth: lineWidth)

                var angle = Angle.degrees(-90)
                for segment in segments where segment.fraction > 0.002 {
                    let end = angle + .degrees(360 * min(segment.fraction, 1))
                    var arc = Path()
                    arc.addArc(center: center, radius: radius, startAngle: angle, endAngle: end, clockwise: false)
                    context.stroke(arc, with: .color(segment.color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    angle = end
                }
            }
            .overlay(
                VStack(spacing: 0) {
                    Text(value)
                        .font(.system(size: side * 0.22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary.color)
                    Text(caption)
                        .font(.system(size: max(side * 0.075, 9), weight: .semibold, design: .rounded))
                        .kerning(1)
                        .foregroundStyle(theme.textSecondary.color)
                }
            )
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// iStat-style mirrored network histogram: upload bars rise above a center
/// axis, download bars hang below it. Shared scale, capacity-based density,
/// newest at the right edge.
/// Mirrored two-series line chart around a center axis (up above, down
/// below), sparkline-style fills toward the axis. Capacity-based density,
/// newest at the right.
public struct MirroredAreaHistory: View {
    @Environment(\.theme) private var theme
    let pairs: [(up: Double, down: Double)]
    let capacity: Int
    var upColor: Color
    var downColor: Color

    public init(pairs: [(up: Double, down: Double)], capacity: Int, upColor: Color, downColor: Color) {
        self.pairs = pairs
        self.capacity = capacity
        self.upColor = upColor
        self.downColor = downColor
    }

    public var body: some View {
        Canvas { context, size in
            let centerY = size.height / 2
            context.fill(
                Path(CGRect(x: 0, y: centerY - 0.5, width: size.width, height: 1)),
                with: .color(theme.track.color)
            )
            guard pairs.count > 1 else { return }
            let top = max(pairs.map(\.up).max() ?? 0, pairs.map(\.down).max() ?? 0, 1)
            let stepX = size.width / CGFloat(max(capacity - 1, 1))
            let startX = size.width - CGFloat(pairs.count - 1) * stepX
            let half = centerY - 1

            func draw(_ series: [Double], sign: CGFloat, color: Color) {
                var line = Path()
                for (i, value) in series.enumerated() {
                    let point = CGPoint(
                        x: startX + CGFloat(i) * stepX,
                        y: centerY + sign * (1 + half * CGFloat(min(value / top, 1)))
                    )
                    i == 0 ? line.move(to: point) : line.addLine(to: point)
                }
                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: centerY))
                fill.addLine(to: CGPoint(x: startX, y: centerY))
                fill.closeSubpath()
                context.fill(fill, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.30), color.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: sign < 0 ? 0 : size.height),
                    endPoint: CGPoint(x: 0, y: centerY)
                ))
                if theme.glowStrength > 0 {
                    var glowContext = context
                    glowContext.addFilter(.shadow(color: color.opacity(theme.glowStrength), radius: 4))
                    glowContext.stroke(line, with: .color(color), lineWidth: 1.5)
                } else {
                    context.stroke(line, with: .color(color), lineWidth: 1.5)
                }
            }

            draw(pairs.map(\.up), sign: -1, color: upColor)
            draw(pairs.map(\.down), sign: 1, color: downColor)
        }
    }
}

/// Small full-circle progress ring (per-core displays).
public struct MiniRing: View {
    @Environment(\.theme) private var theme
    let fraction: Double
    var color: Color

    public init(fraction: Double, color: Color) {
        self.fraction = min(max(fraction, 0), 1)
        self.color = color
    }

    public var body: some View {
        Canvas { context, size in
            let lineWidth = max(min(size.width, size.height) * 0.16, 2.5)
            let radius = (min(size.width, size.height) - lineWidth) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            var track = Path()
            track.addArc(center: center, radius: radius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
            context.stroke(track, with: .color(theme.track.color), lineWidth: lineWidth)

            guard fraction > 0.01 else { return }
            var progress = Path()
            progress.addArc(
                center: center, radius: radius,
                startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction),
                clockwise: false
            )
            context.stroke(progress, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }
}

/// "● label ........ value" legend row, iStat style.
public struct LegendRow: View {
    @Environment(\.theme) private var theme
    let color: Color
    let label: String
    let value: String

    public init(color: Color, label: String, value: String) {
        self.color = color
        self.label = label
        self.value = value
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(theme.textSecondary.color)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
        }
        .font(.system(size: 13, design: .rounded))
    }
}

/// Slim horizontal meter (temperature rows, fan speed) with themed track.
public struct MeterBar: View {
    @Environment(\.theme) private var theme
    let fraction: Double
    var color: Color

    public init(fraction: Double, color: Color) {
        self.fraction = min(max(fraction, 0), 1)
        self.color = color
    }

    public var body: some View {
        Canvas { context, size in
            let radius = size.height / 2
            let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius)
            context.fill(track, with: .color(theme.track.color))
            let width = size.width * CGFloat(fraction)
            if width > 1 {
                let bar = Path(roundedRect: CGRect(x: 0, y: 0, width: width, height: size.height), cornerRadius: radius)
                context.fill(bar, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.65), color]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                ))
            }
        }
        .frame(height: 5)
    }
}
