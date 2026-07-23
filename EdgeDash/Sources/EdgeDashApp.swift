import SettingsUI
import SwiftUI

@main
struct EdgeDashApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            // The label is the only view alive at launch, so the dev hook
            // for `--settings` (open the settings window headlessly, used by
            // scripted UI screenshots) lives here.
            MenuBarLabel()
        }

        Settings {
            SettingsRootView(deps: model.settingsDependencies)
        }
    }
}

private struct MenuBarLabel: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Image(systemName: "gauge.with.dots.needle.50percent")
            .onAppear {
                guard CommandLine.arguments.contains("--settings") else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    NSApp.activate()
                    openSettings()
                }
            }
    }
}

private struct MenuBarContent: View {
    var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(model.statusText)
        Divider()
        Button("Windowed Preview") { model.openWindowedPreview() }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit EdgeDash") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
