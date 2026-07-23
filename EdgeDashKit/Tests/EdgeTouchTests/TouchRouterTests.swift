import CoreGraphics
@testable import EdgeTouch
import Testing

@Suite @MainActor struct TouchRouterTests {
    private final class Recorder {
        var events: [TouchEvent] = []
    }

    private func makeTarget(
        frame: CGRect, z: Int, accepts: Set<GestureKind>, into recorder: Recorder
    ) -> TouchTarget {
        TouchTarget(frame: frame, zIndex: z, accepts: accepts) { recorder.events.append($0) }
    }

    private let windowSize = CGSize(width: 1000, height: 500)

    private func touch(_ phase: RawTouch.Phase, x: CGFloat, y: CGFloat) -> RawTouch {
        RawTouch(phase: phase, normalized: CGPoint(x: x / 1000, y: y / 500))
    }

    @Test func tapRoutesToTopmostButton() {
        let router = TouchRouter()
        let button = Recorder()
        let surface = Recorder()
        router.register(makeTarget(frame: CGRect(x: 100, y: 100, width: 200, height: 100), z: 200, accepts: [.tap], into: button))
        router.register(makeTarget(frame: CGRect(x: 0, y: 0, width: 1000, height: 500), z: 0, accepts: [.tap, .swipe], into: surface))

        router.dispatch(touch(.began, x: 150, y: 150), in: windowSize, at: 0)
        router.dispatch(touch(.ended, x: 152, y: 151), in: windowSize, at: 0.1)

        #expect(button.events.contains { if case .tap = $0 { true } else { false } })
        #expect(surface.events.isEmpty)
    }

    @Test func swipeFallsThroughButtonToSurface() {
        let router = TouchRouter()
        let button = Recorder()
        let surface = Recorder()
        router.register(makeTarget(frame: CGRect(x: 100, y: 100, width: 200, height: 100), z: 200, accepts: [.tap], into: button))
        router.register(makeTarget(frame: CGRect(x: 0, y: 0, width: 1000, height: 500), z: 0, accepts: [.swipe], into: surface))

        router.dispatch(touch(.began, x: 150, y: 150), in: windowSize, at: 0)
        router.dispatch(touch(.moved, x: 300, y: 150), in: windowSize, at: 0.08)
        router.dispatch(touch(.ended, x: 450, y: 150), in: windowSize, at: 0.16)

        #expect(surface.events.contains(.swipe(.right)))
        // Button saw the press visual, then a cancel when the pan took over.
        #expect(button.events.first == .down(CGPoint(x: 150, y: 150)))
        #expect(button.events.contains(.cancelled))
        #expect(!button.events.contains { if case .tap = $0 { true } else { false } })
    }

    @Test func panPrefersScrollerOverSurface() {
        let router = TouchRouter()
        let scroller = Recorder()
        let surface = Recorder()
        router.register(makeTarget(frame: CGRect(x: 0, y: 0, width: 500, height: 500), z: 150, accepts: [.pan], into: scroller))
        router.register(makeTarget(frame: CGRect(x: 0, y: 0, width: 1000, height: 500), z: 0, accepts: [.swipe, .pan], into: surface))

        router.dispatch(touch(.began, x: 250, y: 100), in: windowSize, at: 0)
        router.dispatch(touch(.moved, x: 250, y: 300), in: windowSize, at: 0.1)
        router.dispatch(touch(.ended, x: 250, y: 400), in: windowSize, at: 0.2)

        #expect(scroller.events.contains { if case .panBegan = $0 { true } else { false } })
        #expect(surface.events.allSatisfy { if case .swipe = $0 { true } else { false } })
    }

    @Test func missesEveryTargetSafely() {
        let router = TouchRouter()
        let button = Recorder()
        router.register(makeTarget(frame: CGRect(x: 0, y: 0, width: 10, height: 10), z: 100, accepts: [.tap], into: button))
        router.dispatch(touch(.began, x: 900, y: 400), in: windowSize, at: 0)
        router.dispatch(touch(.ended, x: 900, y: 400), in: windowSize, at: 0.1)
        #expect(button.events.isEmpty)
        #expect(router.lastTouch != nil)
    }

    @Test func unregisteredTargetStopsReceiving() {
        let router = TouchRouter()
        let recorder = Recorder()
        let target = makeTarget(frame: CGRect(x: 0, y: 0, width: 1000, height: 500), z: 10, accepts: [.tap], into: recorder)
        router.register(target)
        router.dispatch(touch(.began, x: 100, y: 100), in: windowSize, at: 0)
        router.unregister(id: target.id)
        router.dispatch(touch(.ended, x: 100, y: 100), in: windowSize, at: 0.1)
        #expect(!recorder.events.contains { if case .tap = $0 { true } else { false } })
    }
}
