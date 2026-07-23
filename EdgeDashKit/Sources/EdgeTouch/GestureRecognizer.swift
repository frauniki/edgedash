import CoreGraphics
import Foundation

/// Classifies a touch sequence (window points + timestamps) into gestures.
/// Pure state machine — driven identically by hardware and synthetic tests.
///
/// Rules:
/// - Movement under `tapSlop` and release under `longPressDelay` → tap.
/// - Held past `longPressDelay` without moving → longPress (on release).
/// - Movement past `panThreshold` → pan sequence (began/changed/ended).
/// - Pan that ends fast and mostly straight → swipe *instead of* panEnded's
///   caller deciding — both are emitted (panEnded carries velocity; swipe is
///   a convenience classification for targets that only care about paging).
public struct GestureRecognizer: Sendable {
    public struct Output: Sendable, Equatable {
        public var events: [TouchEvent] = []
    }

    public var tapSlop: CGFloat = 12
    public var panThreshold: CGFloat = 10
    public var longPressDelay: TimeInterval = 0.6
    public var swipeMinDistance: CGFloat = 60
    public var swipeMinVelocity: CGFloat = 300

    private var startPoint: CGPoint = .zero
    private var startTime: TimeInterval = 0
    private var lastPoint: CGPoint = .zero
    private var lastTime: TimeInterval = 0
    private var velocity: CGSize = .zero
    private var isPanning = false
    private var isTracking = false

    public init() {}

    public mutating func began(at point: CGPoint, time: TimeInterval) -> Output {
        startPoint = point
        lastPoint = point
        startTime = time
        lastTime = time
        velocity = .zero
        isPanning = false
        isTracking = true
        return Output(events: [.down(point)])
    }

    public mutating func moved(to point: CGPoint, time: TimeInterval) -> Output {
        guard isTracking else { return Output() }
        var events: [TouchEvent] = []

        let dt = time - lastTime
        if dt > 0 {
            velocity = CGSize(
                width: (point.x - lastPoint.x) / dt,
                height: (point.y - lastPoint.y) / dt
            )
        }

        let travel = hypot(point.x - startPoint.x, point.y - startPoint.y)
        if !isPanning, travel > panThreshold {
            isPanning = true
            events.append(.panBegan(startPoint))
        }
        if isPanning {
            events.append(.panChanged(
                location: point,
                translation: CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y),
                velocity: velocity
            ))
        }

        lastPoint = point
        lastTime = time
        return Output(events: events)
    }

    public mutating func ended(at point: CGPoint, time: TimeInterval) -> Output {
        guard isTracking else { return Output() }
        isTracking = false
        var events: [TouchEvent] = []

        if isPanning {
            events.append(.panEnded(velocity: velocity))
            if let direction = Self.swipeDirection(
                from: startPoint, to: point, velocity: velocity,
                minDistance: swipeMinDistance, minVelocity: swipeMinVelocity
            ) {
                events.append(.swipe(direction))
            }
        } else if time - startTime >= longPressDelay {
            events.append(.longPress(startPoint))
        } else {
            events.append(.tap(startPoint))
        }

        events.append(.up)
        return Output(events: events)
    }

    static func swipeDirection(
        from start: CGPoint, to end: CGPoint, velocity: CGSize,
        minDistance: CGFloat, minVelocity: CGFloat
    ) -> SwipeDirection? {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let speed = hypot(velocity.width, velocity.height)
        guard speed >= minVelocity else { return nil }
        if abs(dx) >= abs(dy) {
            guard abs(dx) >= minDistance else { return nil }
            return dx > 0 ? .right : .left
        } else {
            guard abs(dy) >= minDistance else { return nil }
            return dy > 0 ? .down : .up
        }
    }
}
