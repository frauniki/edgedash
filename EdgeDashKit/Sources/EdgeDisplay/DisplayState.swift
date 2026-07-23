import CoreGraphics
import EdgeCore

/// Hot-plug state machine states for the dashboard display.
public enum DisplayAttachment: Sendable, Equatable {
    case searching
    case attached(displayID: CGDirectDisplayID)
    case lost
}
