import CoreGraphics
import Foundation
import Observation

/// A rectangular touch-receiving region in window coordinates.
public struct TouchTarget: Identifiable {
    public let id: UUID
    public var frame: CGRect
    public var zIndex: Int
    public var accepts: Set<GestureKind>
    public var handler: @MainActor (TouchEvent) -> Void

    public init(
        id: UUID = UUID(),
        frame: CGRect,
        zIndex: Int,
        accepts: Set<GestureKind>,
        handler: @escaping @MainActor (TouchEvent) -> Void
    ) {
        self.id = id
        self.frame = frame
        self.zIndex = zIndex
        self.accepts = accepts
        self.handler = handler
    }
}

/// Spatial hit-test registry + gesture arbitration. No OS events involved:
/// digitizer input becomes in-app gesture callbacks, the cursor never moves,
/// focus is never stolen.
///
/// Arbitration: at touch-down the containing targets (z-descending) form the
/// candidate stack. `.down`/`.up`/`.cancelled` go to the top tap-accepting
/// candidate (pressed visuals). Each classified event goes to the topmost
/// candidate accepting that kind — a button over a scroll surface takes taps
/// while pans fall through to the scroller, and swipes to the page surface.
@MainActor @Observable public final class TouchRouter {
    private var targets: [UUID: TouchTarget] = [:]
    private var recognizer = GestureRecognizer()
    private var candidates: [TouchTarget] = []
    private var visualTarget: TouchTarget?
    private var panOwner: TouchTarget?

    /// Most recent touch in window coordinates — drives the settings test view.
    public private(set) var lastTouch: CGPoint?
    public private(set) var lastWindowSize: CGSize?
    public private(set) var isTouching = false

    public init() {}

    // MARK: - Registry

    public func register(_ target: TouchTarget) {
        targets[target.id] = target
    }

    public func updateFrame(id: UUID, frame: CGRect) {
        targets[id]?.frame = frame
    }

    public func unregister(id: UUID) {
        targets.removeValue(forKey: id)
        candidates.removeAll { $0.id == id }
    }

    // MARK: - Dispatch

    public func dispatch(_ touch: RawTouch, in windowSize: CGSize, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let point = TouchTransform.toPoint(touch.normalized, in: windowSize)
        lastTouch = point
        lastWindowSize = windowSize

        let output: GestureRecognizer.Output
        switch touch.phase {
        case .began:
            isTouching = true
            candidates = targets.values
                .filter { $0.frame.contains(point) }
                .sorted { $0.zIndex > $1.zIndex }
            visualTarget = candidates.first { $0.accepts.contains(.tap) || $0.accepts.contains(.longPress) }
            panOwner = nil
            output = recognizer.began(at: point, time: time)
        case .moved:
            output = recognizer.moved(to: point, time: time)
        case .ended:
            isTouching = false
            output = recognizer.ended(at: point, time: time)
        }

        for event in output.events {
            deliver(event)
        }
        if touch.phase == .ended {
            candidates = []
            visualTarget = nil
            panOwner = nil
        }
    }

    private func deliver(_ event: TouchEvent) {
        switch event {
        case .down, .up, .cancelled:
            visualTarget.flatMap { current($0) }?.handler(event)
        case .tap:
            firstCandidate(accepting: .tap)?.handler(event)
        case .longPress:
            firstCandidate(accepting: .longPress)?.handler(event)
        case .swipe:
            firstCandidate(accepting: .swipe)?.handler(event)
        case .panBegan:
            panOwner = firstCandidate(accepting: .pan)
            // A pan taking over means the pressed visual was a misprediction.
            if let visualTarget, visualTarget.id != panOwner?.id {
                current(visualTarget)?.handler(.cancelled)
                self.visualTarget = nil
            }
            panOwner.flatMap { current($0) }?.handler(event)
        case .panChanged, .panEnded:
            panOwner.flatMap { current($0) }?.handler(event)
        }
    }

    private func firstCandidate(accepting kind: GestureKind) -> TouchTarget? {
        candidates.first { $0.accepts.contains(kind) }.flatMap { current($0) }
    }

    /// Re-resolve through the registry so frame/handler updates since
    /// touch-down are honored (and unregistered targets are dropped).
    private func current(_ target: TouchTarget) -> TouchTarget? {
        targets[target.id]
    }
}
