import CoreGraphics
@testable import EdgeTouch
import Testing

struct GestureRecognizerTests {
    @Test func quickTouchIsTap() {
        var recognizer = GestureRecognizer()
        _ = recognizer.began(at: CGPoint(x: 100, y: 100), time: 0)
        let out = recognizer.ended(at: CGPoint(x: 103, y: 102), time: 0.15)
        #expect(out.events.contains(.tap(CGPoint(x: 100, y: 100))))
        #expect(out.events.last == .up)
    }

    @Test func heldTouchIsLongPress() {
        var recognizer = GestureRecognizer()
        _ = recognizer.began(at: CGPoint(x: 50, y: 50), time: 0)
        let out = recognizer.ended(at: CGPoint(x: 52, y: 50), time: 0.8)
        #expect(out.events.contains(.longPress(CGPoint(x: 50, y: 50))))
        #expect(!out.events.contains { if case .tap = $0 { true } else { false } })
    }

    @Test func movementBecomesPanSequence() {
        var recognizer = GestureRecognizer()
        _ = recognizer.began(at: CGPoint(x: 100, y: 100), time: 0)
        let move1 = recognizer.moved(to: CGPoint(x: 130, y: 100), time: 0.05)
        #expect(move1.events.first == .panBegan(CGPoint(x: 100, y: 100)))
        #expect(move1.events.contains {
            if case .panChanged(_, let translation, _) = $0 { translation.width == 30 } else { false }
        })
        let end = recognizer.ended(at: CGPoint(x: 200, y: 100), time: 0.15)
        #expect(end.events.contains { if case .panEnded = $0 { true } else { false } })
    }

    @Test func fastHorizontalPanIsAlsoSwipe() {
        var recognizer = GestureRecognizer()
        _ = recognizer.began(at: CGPoint(x: 300, y: 100), time: 0)
        _ = recognizer.moved(to: CGPoint(x: 200, y: 105), time: 0.08)
        let out = recognizer.ended(at: CGPoint(x: 100, y: 110), time: 0.16)
        #expect(out.events.contains(.swipe(.left)))
    }

    @Test func slowDragIsNotSwipe() {
        var recognizer = GestureRecognizer()
        _ = recognizer.began(at: CGPoint(x: 300, y: 100), time: 0)
        var t = 0.0
        for x in stride(from: 295.0, through: 200.0, by: -5) {
            t += 0.2 // 25 px/s — far below swipe velocity
            _ = recognizer.moved(to: CGPoint(x: x, y: 100), time: t)
        }
        let out = recognizer.ended(at: CGPoint(x: 200, y: 100), time: t + 0.2)
        #expect(!out.events.contains { if case .swipe = $0 { true } else { false } })
    }

    @Test func smallJitterStaysTap() {
        var recognizer = GestureRecognizer()
        _ = recognizer.began(at: CGPoint(x: 100, y: 100), time: 0)
        _ = recognizer.moved(to: CGPoint(x: 104, y: 103), time: 0.05)
        let out = recognizer.ended(at: CGPoint(x: 102, y: 101), time: 0.1)
        #expect(out.events.contains { if case .tap = $0 { true } else { false } })
        #expect(!out.events.contains { if case .panBegan = $0 { true } else { false } })
    }
}
