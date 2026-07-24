/// Display rotation in degrees as reported by CGDisplayRotation. The touch
/// digitizer always reports physical panel coordinates, so this drives the
/// touch coordinate transform as well as grid transposition.
public enum DisplayRotation: Int, Sendable, Codable, CaseIterable {
    case none = 0
    case quarter = 90
    case half = 180
    case threeQuarter = 270

    public init(degrees: Double) {
        let normalized = (Int(degrees.rounded()) % 360 + 360) % 360
        self = DisplayRotation(rawValue: normalized) ?? .none
    }

    public var isPortrait: Bool {
        self == .quarter || self == .threeQuarter
    }
}
