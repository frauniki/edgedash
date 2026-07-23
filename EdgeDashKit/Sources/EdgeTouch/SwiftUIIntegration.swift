import SwiftUI

public extension EnvironmentValues {
    /// The router for the dashboard surface this view lives on (nil when the
    /// surface has no touch hardware — touch modifiers become no-ops).
    @Entry var touchRouter: TouchRouter?
}

/// Registers this view's frame as a touch target. Frames are reported in the
/// window's coordinate space (`.global` in SwiftUI == window space on macOS).
public struct TouchTargetModifier: ViewModifier {
    @Environment(\.touchRouter) private var router
    @State private var id = UUID()

    let accepts: Set<GestureKind>
    let zIndex: Int
    let handler: @MainActor (TouchEvent) -> Void

    public func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                guard let router else { return }
                router.register(TouchTarget(id: id, frame: frame, zIndex: zIndex, accepts: accepts, handler: handler))
            }
            .onDisappear {
                router?.unregister(id: id)
            }
    }
}

public extension View {
    func touchTarget(
        accepts: Set<GestureKind>,
        zIndex: Int = 100,
        handler: @escaping @MainActor (TouchEvent) -> Void
    ) -> some View {
        modifier(TouchTargetModifier(accepts: accepts, zIndex: zIndex, handler: handler))
    }
}

/// A button that responds to panel touches (and normal mouse clicks, so the
/// windowed preview works identically).
public struct TouchButton<Label: View>: View {
    let action: @MainActor () -> Void
    @ViewBuilder let label: Label
    @State private var pressed = false

    public init(action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    public var body: some View {
        label
            .contentShape(Rectangle())
            .opacity(pressed ? 0.55 : 1)
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.1), value: pressed)
            .touchTarget(accepts: [.tap], zIndex: 200) { event in
                switch event {
                case .down: pressed = true
                case .up, .cancelled: pressed = false
                case .tap: action()
                default: break
                }
            }
            .onTapGesture { action() } // mouse path for windowed preview
    }
}

/// Vertically scrollable container driven by panel pans with decay, for
/// content taller than its widget cell (sensor lists etc.). Mouse scroll
/// works via the native ScrollView it wraps.
public struct TouchScrollView<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var offset: CGFloat = 0
    @State private var panStartOffset: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var decayTask: Task<Void, Never>?

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var maxOffset: CGFloat { max(0, contentHeight - viewportHeight) }

    public var body: some View {
        GeometryReader { viewport in
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                .offset(y: -offset)
                .frame(maxWidth: .infinity, alignment: .top)
                .onAppear { viewportHeight = viewport.size.height }
                .onChange(of: viewport.size.height) { _, height in viewportHeight = height }
        }
        .clipped()
        .touchTarget(accepts: [.pan], zIndex: 150) { event in
            switch event {
            case .panBegan:
                decayTask?.cancel()
                panStartOffset = offset
            case .panChanged(_, let translation, _):
                offset = min(max(panStartOffset - translation.height, 0), maxOffset)
            case .panEnded(let velocity):
                decay(initialVelocity: -velocity.height)
            default:
                break
            }
        }
    }

    private func decay(initialVelocity: CGFloat) {
        decayTask?.cancel()
        decayTask = Task { @MainActor in
            var velocity = initialVelocity
            while abs(velocity) > 10, !Task.isCancelled {
                offset = min(max(offset + velocity / 60, 0), maxOffset)
                velocity *= 0.94
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
}
