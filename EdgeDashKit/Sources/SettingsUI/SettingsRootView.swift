import EdgeCore
import EdgeTouch
import SwiftUI
import WidgetEngine

/// Everything the settings window needs from the app layer.
@MainActor public struct SettingsDependencies {
    public let configStore: ConfigStore
    public let registry: WidgetRegistry
    public let hub: MetricHub
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
        case debug = "Debug"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .dashboard: "rectangle.grid.2x2"
            case .display: "display"
            case .touch: "hand.tap"
            case .debug: "waveform.path.ecg"
            }
        }
    }

    @State private var pane: Pane = .dashboard

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
            switch pane {
            case .dashboard:
                DashboardSettingsView(configStore: deps.configStore, registry: deps.registry, hub: deps.hub)
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
            case .debug:
                DebugMetricsView(hub: deps.hub, ids: deps.debugMetricIDs)
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear { deps.onVisibilityChange(true) }
        .onDisappear { deps.onVisibilityChange(false) }
    }
}
