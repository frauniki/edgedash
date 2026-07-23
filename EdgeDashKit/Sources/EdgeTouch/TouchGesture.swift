import CoreGraphics

/// What a touch target can receive. Targets declare what they accept so the
/// router can arbitrate (button takes the tap, page surface takes the swipe).
public enum GestureKind: Sendable, Hashable {
    case tap
    case longPress
    case swipe
    case pan
}

public enum SwipeDirection: Sendable, Equatable {
    case left
    case right
    case up
    case down
}

/// Events delivered to a touch target. `.down`/`.up`/`.cancelled` bracket
/// every gesture for pressed-state visuals; exactly one classified event
/// (tap/longPress/swipe/pan sequence) arrives in between.
public enum TouchEvent: Sendable, Equatable {
    case down(CGPoint)
    case up
    case cancelled
    case tap(CGPoint)
    case longPress(CGPoint)
    case swipe(SwipeDirection)
    case panBegan(CGPoint)
    case panChanged(location: CGPoint, translation: CGSize, velocity: CGSize)
    case panEnded(velocity: CGSize)
}
