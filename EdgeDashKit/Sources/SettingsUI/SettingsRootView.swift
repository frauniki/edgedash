import EdgeCore
import EdgeTouch
import SwiftUI
import WidgetEngine

/// Everything the settings window needs from the app layer.
@MainActor public struct SettingsDependencies {
    public let configStore: ConfigStore
    public let registry: WidgetRegistry
    public let hub: MetricHub
    public let services: WidgetServices?
    public let debugMetricIDs: [MetricID]
    public let touchCapture: () -> TouchDeviceCapture?
    public let touchRouter: TouchRouter
    public let statusText: () -> String
    public let displayChoices: @MainActor () -> [DisplayChoice]
    public let onTouchRefresh: @MainActor () -> Void
    public let onVisibilityChange: @MainActor (Bool) -> Void

    public init(
        configStore: ConfigStore,
        registry: WidgetRegistry,
        hub: MetricHub,
        services: WidgetServices? = nil,
        debugMetricIDs: [MetricID],
        touchCapture: @escaping () -> TouchDeviceCapture?,
        touchRouter: TouchRouter,
        statusText: @escaping () -> String,
        displayChoices: @escaping @MainActor () -> [DisplayChoice],
        onTouchRefresh: @escaping @MainActor () -> Void,
        onVisibilityChange: @escaping @MainActor (Bool) -> Void
    ) {
        self.configStore = configStore
        self.registry = registry
        self.hub = hub
        self.services = services
        self.debugMetricIDs = debugMetricIDs
        self.touchCapture = touchCapture
        self.touchRouter = touchRouter
        self.statusText = statusText
        self.displayChoices = displayChoices
        self.onTouchRefresh = onTouchRefresh
        self.onVisibilityChange = onVisibilityChange
    }
}

public struct SettingsRootView: View {
    private let deps: SettingsDependencies

    private enum Pane: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard"
        case display = "Display"
        case touch = "Touch"
        case appearance = "Appearance"
        case debug = "Debug"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .dashboard: "rectangle.grid.2x2"
            case .display: "display"
            case .touch: "hand.tap"
            case .appearance: "paintpalette"
            case .debug: "waveform.path.ecg"
            }
        }
    }

    // Initial pane can be forced with `--pane <Name>` (dev hook for
    // scripted UI screenshots alongside `--settings`).
    @State private var pane: Pane = {
        if let flag = CommandLine.arguments.firstIndex(of: "--pane"),
           CommandLine.arguments.indices.contains(flag + 1),
           let forced = Pane(rawValue: CommandLine.arguments[flag + 1]) {
            return forced
        }
        return .dashboard
    }()

    public init(deps: SettingsDependencies) {
        self.deps = deps
    }

    public var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: Binding(get: { pane }, set: { pane = $0 ?? .dashboard })) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(160)
        } detail: {
            detailView
                // Fills the otherwise-empty toolbar band above every pane.
                .navigationTitle(pane.rawValue)
        }
        // Dashboard is the widest pane: sidebar + page list + placement list
        // + inspector minimums ≈ 880. A smaller window would force the
        // inspector's geometry rows to clip.
        .frame(minWidth: 880, minHeight: 500)
        .onAppear { deps.onVisibilityChange(true) }
        .onDisappear { deps.onVisibilityChange(false) }
    }

    @ViewBuilder private var detailView: some View {
        switch pane {
        case .dashboard:
            DashboardSettingsView(
                configStore: deps.configStore,
                registry: deps.registry,
                hub: deps.hub,
                services: deps.services
            )
        case .display:
            DisplaySettingsView(
                configStore: deps.configStore,
                statusText: deps.statusText(),
                displayChoices: deps.displayChoices
            )
        case .touch:
            TouchSettingsView(
                capture: deps.touchCapture(),
                router: deps.touchRouter,
                onRefresh: deps.onTouchRefresh
            )
        case .appearance:
            AppearanceSettingsView(configStore: deps.configStore)
        case .debug:
            DebugMetricsView(hub: deps.hub, ids: deps.debugMetricIDs)
        }
    }
}
