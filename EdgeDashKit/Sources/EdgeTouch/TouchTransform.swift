import CoreGraphics
import EdgeCore

/// Maps normalized physical-panel coordinates to normalized window
/// coordinates under display rotation. The digitizer always reports along the
/// panel's physical axes; when macOS rotates the framebuffer, window space
/// rotates with it. Pure — unit-tested for all four cases.
public enum TouchTransform {
    public static func toWindowSpace(_ panel: CGPoint, rotation: DisplayRotation) -> CGPoint {
        switch rotation {
        case .none:
            panel
        case .quarter: // framebuffer rotated 90° CW relative to panel
            CGPoint(x: 1 - panel.y, y: panel.x)
        case .half:
            CGPoint(x: 1 - panel.x, y: 1 - panel.y)
        case .threeQuarter:
            CGPoint(x: panel.y, y: 1 - panel.x)
        }
    }

    /// Normalized window point → concrete point in a window of `size`.
    public static func toPoint(_ normalized: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
    }
}
