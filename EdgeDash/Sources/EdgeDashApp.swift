import SettingsUI
import SwiftUI

@main
struct EdgeDashApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("EdgeDash", systemImage: "gauge.with.dots.needle.50percent") {
            MenuBarContent(model: model)
        }

        Settings {
            SettingsRootView(deps: model.settingsDependencies)
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
