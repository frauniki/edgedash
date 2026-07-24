import CoreGraphics
import EdgeCore
@testable import EdgeTouch
import Testing

struct TouchTransformTests {
    /// A touch near the panel's physical top-left corner, slightly inset.
    let p = CGPoint(x: 0.1, y: 0.2)

    @Test func identityAtZeroRotation() {
        #expect(TouchTransform.toWindowSpace(p, rotation: .none) == p)
    }

    @Test func quarterRotation() {
        let mapped = TouchTransform.toWindowSpace(p, rotation: .quarter)
        #expect(abs(mapped.x - 0.8) < 0.0001)
        #expect(abs(mapped.y - 0.1) < 0.0001)
    }

    @Test func halfRotation() {
        let mapped = TouchTransform.toWindowSpace(p, rotation: .half)
        #expect(abs(mapped.x - 0.9) < 0.0001)
        #expect(abs(mapped.y - 0.8) < 0.0001)
    }

    @Test func threeQuarterRotation() {
        let mapped = TouchTransform.toWindowSpace(p, rotation: .threeQuarter)
        #expect(abs(mapped.x - 0.2) < 0.0001)
        #expect(abs(mapped.y - 0.9) < 0.0001)
    }

    @Test func rotationRoundTripsThroughOpposite() {
        // 90° then 270° mapping of the mapped point returns the original.
        let once = TouchTransform.toWindowSpace(p, rotation: .quarter)
        let back = TouchTransform.toWindowSpace(once, rotation: .threeQuarter)
        #expect(abs(back.x - p.x) < 0.0001)
        #expect(abs(back.y - p.y) < 0.0001)
    }

    @Test func pointScaling() {
        let point = TouchTransform.toPoint(CGPoint(x: 0.5, y: 0.25), in: CGSize(width: 2560, height: 720))
        #expect(point == CGPoint(x: 1280, y: 180))
    }
}
