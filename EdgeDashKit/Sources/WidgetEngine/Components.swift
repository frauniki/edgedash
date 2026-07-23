import EdgeCore
import SwiftUI

/// Shared drawing components for widgets. Canvas-based — no Swift Charts on
/// the per-second hot path.

public struct SparklineView: View {
    let values: [Double]
    var maxValue: Double?
    var color: Color

    public init(history: RingBuffer<MetricPoint>, maxValue: Double? = nil, color: Color = .cyan) {
        self.values = history.compactMap { Self.scalarize($0.value) }
        self.maxValue = maxValue
        self.color = color
    }

    public init(values: [Double], maxValue: Double? = nil, color: Color = .cyan) {
        self.values = values
        self.maxValue = maxValue
        self.color = color
    }

    public var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let top = max(maxValue ?? values.max() ?? 1, 0.0001)
            let stepX = size.width / CGFloat(values.count - 1)

            var line = Path()
            for (i, v) in values.enumerated() {
                let point = CGPoint(
                    x: CGFloat(i) * stepX,
                    y: size.height * (1 - CGFloat(min(v / top, 1)))
                )
                i == 0 ? line.move(to: point) : line.addLine(to: point)
            }

            var fill = line
            fill.addLine(to: CGPoint(x: CGFloat(values.count - 1) * stepX, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()

            context.fill(fill, with: .linearGradient(
                Gradient(colors: [color.opacity(0.25), color.opacity(0.02)]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            ))
            context.stroke(line, with: .color(color), lineWidth: 1.5)
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

/// Circular utilization gauge: 270° arc with a colored progress stroke.
public struct RingGauge: View {
    let fraction: Double
    var color: Color

    public init(fraction: Double, color: Color = .cyan) {
        self.fraction = min(max(fraction, 0), 1)
        self.color = color
    }

    public var body: some View {
        Canvas { context, size in
            let lineWidth = max(size.width * 0.08, 4)
            let radius = (min(size.width, size.height) - lineWidth) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let start = Angle.degrees(135)
            let full = Angle.degrees(270)

            var track = Path()
            track.addArc(center: center, radius: radius, startAngle: start, endAngle: start + full, clockwise: false)
            context.stroke(track, with: .color(.white.opacity(0.1)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            guard fraction > 0 else { return }
            var progress = Path()
            progress.addArc(center: center, radius: radius, startAngle: start, endAngle: start + full * fraction, clockwise: false)
            context.stroke(progress, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
    }
}

/// Compact per-core utilization bars.
public struct CoreBars: View {
    let cores: [Double]
    var color: Color

    public init(cores: [Double], color: Color = .cyan) {
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
                context.fill(track, with: .color(.white.opacity(0.1)))
                let h = size.height * CGFloat(min(max(v, 0), 1))
                if h > 0 {
                    let bar = Path(roundedRect: CGRect(x: x, y: size.height - h, width: barW, height: h), cornerRadius: 1.5)
                    context.fill(bar, with: .color(color))
                }
            }
        }
    }
}

/// Threshold → color mapping shared by gauges.
public enum GaugeColor {
    public static func forFraction(_ fraction: Double, warn: Double = 0.7, critical: Double = 0.9) -> Color {
        fraction >= critical ? .red : fraction >= warn ? .orange : .cyan
    }
}
