/// Semantic theme tokens. Codable so user themes can eventually ship as
/// config files. Widgets consume tokens only — never literal colors.
public struct ThemeColor: Codable, Sendable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// 0xRRGGBB convenience.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255,
            alpha
        )
    }

    public func opacity(_ value: Double) -> ThemeColor {
        ThemeColor(red, green, blue, alpha * value)
    }
}

public struct Theme: Codable, Sendable, Equatable, Identifiable {
    public var id: ThemeID
    public var name: String

    // Surfaces
    public var pageBackground: ThemeColor
    public var surfaceTop: ThemeColor
    public var surfaceBottom: ThemeColor
    public var strokeTop: ThemeColor
    public var strokeBottom: ThemeColor
    public var track: ThemeColor // gauge/bar backgrounds

    // Content
    public var textPrimary: ThemeColor
    public var textSecondary: ThemeColor
    public var accent: ThemeColor // primary data color (download, gauges)
    public var accentAlt: ThemeColor // counterpart data color (upload, writes)
    public var warn: ThemeColor
    public var critical: ThemeColor

    // Chrome
    public var cornerRadius: Double
    public var glowStrength: Double // 0–1: how luminous charts render

    public init(
        id: ThemeID, name: String,
        pageBackground: ThemeColor, surfaceTop: ThemeColor, surfaceBottom: ThemeColor,
        strokeTop: ThemeColor, strokeBottom: ThemeColor, track: ThemeColor,
        textPrimary: ThemeColor, textSecondary: ThemeColor,
        accent: ThemeColor, accentAlt: ThemeColor, warn: ThemeColor, critical: ThemeColor,
        cornerRadius: Double, glowStrength: Double
    ) {
        self.id = id
        self.name = name
        self.pageBackground = pageBackground
        self.surfaceTop = surfaceTop
        self.surfaceBottom = surfaceBottom
        self.strokeTop = strokeTop
        self.strokeBottom = strokeBottom
        self.track = track
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.accent = accent
        self.accentAlt = accentAlt
        self.warn = warn
        self.critical = critical
        self.cornerRadius = cornerRadius
        self.glowStrength = glowStrength
    }

    /// Threshold-mapped gauge color.
    public func gaugeColor(_ fraction: Double, warn warnAt: Double = 0.7, critical criticalAt: Double = 0.9) -> ThemeColor {
        fraction >= criticalAt ? critical : fraction >= warnAt ? warn : accent
    }
}

public extension ThemeID {
    static let aurora = ThemeID("aurora")
}

public enum BuiltinThemes {
    /// Default: deep graphite with cyan/violet data colors — an ambient,
    /// always-on look for a strip display.
    public static let graphite = Theme(
        id: .graphite, name: "Graphite",
        pageBackground: ThemeColor(hex: 0x000000),
        surfaceTop: ThemeColor(hex: 0x1B1D22),
        surfaceBottom: ThemeColor(hex: 0x121317),
        strokeTop: ThemeColor(hex: 0xFFFFFF, alpha: 0.14),
        strokeBottom: ThemeColor(hex: 0xFFFFFF, alpha: 0.03),
        track: ThemeColor(hex: 0xFFFFFF, alpha: 0.09),
        textPrimary: ThemeColor(hex: 0xF5F7FA),
        textSecondary: ThemeColor(hex: 0x8B93A1),
        accent: ThemeColor(hex: 0x38D6E8),
        accentAlt: ThemeColor(hex: 0xA78BFA),
        warn: ThemeColor(hex: 0xF5A623),
        critical: ThemeColor(hex: 0xFF4D5E),
        cornerRadius: 16,
        glowStrength: 0.55
    )

    /// Warm alternative: charcoal with mint/amber data colors.
    public static let aurora = Theme(
        id: .aurora, name: "Aurora",
        pageBackground: ThemeColor(hex: 0x06080A),
        surfaceTop: ThemeColor(hex: 0x16211E),
        surfaceBottom: ThemeColor(hex: 0x0D1412),
        strokeTop: ThemeColor(hex: 0x8CF5D2, alpha: 0.16),
        strokeBottom: ThemeColor(hex: 0x8CF5D2, alpha: 0.03),
        track: ThemeColor(hex: 0xFFFFFF, alpha: 0.08),
        textPrimary: ThemeColor(hex: 0xEDFDF6),
        textSecondary: ThemeColor(hex: 0x7FA396),
        accent: ThemeColor(hex: 0x4AE3B5),
        accentAlt: ThemeColor(hex: 0xF6C177),
        warn: ThemeColor(hex: 0xF6A03C),
        critical: ThemeColor(hex: 0xFF5C74),
        cornerRadius: 16,
        glowStrength: 0.75
    )

    public static let all: [Theme] = [graphite, aurora]

    public static func theme(for id: ThemeID) -> Theme {
        all.first { $0.id == id } ?? graphite
    }
}
