import CoreGraphics

/// A single digitizer contact in normalized panel coordinates (0–1 on the
/// physical panel's axes, before any display-rotation transform).
public struct RawTouch: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case began
        case moved
        case ended
    }

    public var phase: Phase
    public var normalized: CGPoint

    public init(phase: Phase, normalized: CGPoint) {
        self.phase = phase
        self.normalized = normalized
    }
}
