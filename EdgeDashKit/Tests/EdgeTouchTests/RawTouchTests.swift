import EdgeTouch
import Testing

@Suite struct RawTouchTests {
    @Test func touchEquality() {
        let a = RawTouch(phase: .began, normalized: .init(x: 0.5, y: 0.25))
        let b = RawTouch(phase: .began, normalized: .init(x: 0.5, y: 0.25))
        #expect(a == b)
        #expect(RawTouch(phase: .ended, normalized: .zero) != a)
    }
}
