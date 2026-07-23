import EdgeTouch
import SwiftUI

/// Touch tab: permission onboarding, capture status (incl. conflicts with
/// other touch drivers), and a live touch test area.
public struct TouchSettingsView: View {
    private let capture: TouchDeviceCapture?
    private let router: TouchRouter
    private let onRefresh: @MainActor () -> Void

    public init(capture: TouchDeviceCapture?, router: TouchRouter, onRefresh: @escaping @MainActor () -> Void) {
        self.capture = capture
        self.router = router
        self.onRefresh = onRefresh
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusSection
            testSection
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            // Poll while visible: picks up TCC grants and hot-plugs live.
            while !Task.isCancelled {
                onRefresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder private var statusSection: some View {
        GroupBox("Touch input") {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText)
                Spacer()
                if capture?.state == .noPermission {
                    Button("Grant Input Monitoring…") {
                        TouchDeviceCapture.requestPermission()
                        openInputMonitoringSettings()
                    }
                }
            }
            .padding(6)
        }
    }

    private var statusColor: Color {
        switch capture?.state {
        case .seized: .green
        case .sharedListen: .yellow
        case .noPermission, .deviceNotFound: .red
        default: .gray
        }
    }

    private var statusText: String {
        switch capture?.state {
        case nil: "No touch-capable display profile active"
        case .idle: "Idle"
        case .searching: "Searching for touch controller…"
        case .noPermission: "Input Monitoring permission required"
        case .seized(let n): "Active — \(n) interfaces captured exclusively"
        case .sharedListen(let n):
            "Shared mode (\(n) interfaces) — another touch driver is running (Touchscreen Gestures? iCUE?); the cursor may move on touch. Quit it for full capture."
        case .deviceNotFound: "Touch controller not found — is the EDGE's USB cable connected?"
        }
    }

    @ViewBuilder private var testSection: some View {
        GroupBox("Touch test") {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.85))
                // 32:9 mini-panel mirroring the strip.
                if let touch = router.lastTouch, let panel = router.lastWindowSize {
                    GeometryReader { proxy in
                        Circle()
                            .fill(router.isTouching ? Color.cyan : Color.gray)
                            .frame(width: 14, height: 14)
                            .position(
                                x: touch.x / panel.width * proxy.size.width,
                                y: touch.y / panel.height * proxy.size.height
                            )
                            .animation(.linear(duration: 0.03), value: touch)
                    }
                    Text(String(format: "%.0f, %.0f", touch.x, touch.y))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(6)
                } else {
                    Text("Touch the panel…")
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(32.0 / 9.0, contentMode: .fit)
        }
    }

    private func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}
