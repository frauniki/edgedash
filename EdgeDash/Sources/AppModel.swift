import AgentWidgets
import BuiltinWidgets
import EdgeCore
import MediaWidgets
import EdgeDisplay
import EdgeMetrics
import EdgeTouch
import Observation
import SettingsUI
import SMCBridge
import SwiftUI
import WidgetEngine

@MainActor @Observable final class AppModel {
    let display = DisplayController()
    let dashboardWindow = DashboardWindowController()
    let hub = MetricHub()
    let engine = MetricsEngine()
    let registry = WidgetRegistry()
    let touchRouter = TouchRouter()
    let widgetServices = WidgetServices()
    let musicPlayer = MusicPlayerController(transport: AppleMusicTransport())
    let claudeMonitor = ClaudeCodeMonitor()
    private(set) var touchCapture: TouchDeviceCapture?
    private let keepAwake = KeepAwakeController()
    let configStore = ConfigStore(defaultConfig: DashboardConfig(pages: BuiltinWidgets.starterPages()))
    private(set) var statusText = "Searching for a supported display…"

    /// Metrics listed in the settings Debug tab.
    let debugMetricIDs: [MetricID] = [
        .cpuUsage, .cpuPerCore, .cpuLoadAverage,
        .memoryUsage, .memoryBreakdown, .memoryPressure,
        .gpuUsage, .gpuMemory, .networkThroughput,
        .diskCapacity, .diskIO, .temperatures, .fans,
        .systemPower, .cpuBreakdown, .systemUptime,
        .topProcessesCPU, .topProcessesMemory,
    ]

    private var dashboardVisible = false
    private var settingsVisible = false

    init() {
        BuiltinWidgets.registerAll(in: registry)
        MediaWidgets.registerAll(in: registry)
        AgentWidgets.registerAll(in: registry)
        widgetServices.register(musicPlayer)
        widgetServices.register(claudeMonitor)

        display.onStateChange = { [weak self] in self?.sync() }
        display.selection = configStore.config.display // manual pick persists
        display.start()

        Task {
            await engine.register(CPUReader())
            await engine.register(MemoryReader())
            await engine.register(GPUReader())
            await engine.register(NetworkReader())
            await engine.register(DiskCapacityReader())
            await engine.register(DiskIOReader())
            await engine.register(SMCTemperatureReader())
            await engine.register(SMCFanReader())
            await engine.register(SMCPowerReader())
            await engine.register(ProcessReader())
            await engine.start(publishingTo: hub)
        }
        refreshActiveMetrics()
        observeConfig()

        if CommandLine.arguments.contains("--windowed") {
            openWindowedPreview()
        }
    }

    func sync() {
        switch display.attachment {
        case .attached:
            guard let screen = display.screen else { return }
            let deviceName = display.profile?.name ?? "External display"
            statusText = "\(deviceName): \(Int(screen.frame.width))×\(Int(screen.frame.height)) pt, rotation \(display.rotation.rawValue)°"
            dashboardWindow.show(on: screen, content: DashboardHost(model: self))
            dashboardVisible = true
        case .searching:
            statusText = "Searching for a supported display…"
            dashboardWindow.hide()
            dashboardVisible = false
        case .lost:
            statusText = "Display disconnected"
            dashboardWindow.hide()
            dashboardVisible = false
        }
        refreshTouch()
        updateEngineState()
        keepAwake.setActive(configStore.config.options.keepAwake && dashboardVisible)
    }

    // MARK: - Touch

    /// (Re)starts touch capture to match the current display/profile state.
    /// Called on display changes and polled by the settings Touch tab so
    /// permission grants and hot-plugs recover live.
    func refreshTouch() {
        guard dashboardVisible, let match = display.profile?.touch else {
            touchCapture?.stop()
            return
        }

        if touchCapture == nil {
            let capture = TouchDeviceCapture(match: match)
            capture.onTouch = { [weak self] touch in self?.routeTouch(touch) }
            touchCapture = capture
        }

        switch touchCapture!.state {
        case .idle, .noPermission, .deviceNotFound:
            touchCapture!.start()
        case .searching, .seized, .sharedListen:
            break
        }
    }

    private func routeTouch(_ touch: RawTouch) {
        guard let screen = display.screen else { return }
        let windowNormalized = TouchTransform.toWindowSpace(touch.normalized, rotation: display.rotation)
        touchRouter.dispatch(
            RawTouch(phase: touch.phase, normalized: windowNormalized),
            in: screen.frame.size
        )
    }

    func switchPage(_ delta: Int) {
        configStore.update { config in
            guard config.pages.count > 1 else { return }
            let currentIndex = config.pages.firstIndex { $0.id == config.activePageID } ?? 0
            let next = (currentIndex + delta + config.pages.count) % config.pages.count
            config.activePageID = config.pages[next].id
        }
    }

    func setSettingsVisible(_ visible: Bool) {
        settingsVisible = visible
        updateEngineState()
    }

    func openWindowedPreview() {
        NSApp.activate()
        dashboardWindow.showWindowed(content: DashboardHost(model: self))
        dashboardVisible = true
        updateEngineState()
    }

    // MARK: - Engine subscription management

    /// Re-arm Observation tracking on the config so widget/page edits (UI or
    /// hand-edited JSON) retarget the sampled metric set.
    private func observeConfig() {
        withObservationTracking {
            _ = configStore.config
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshActiveMetrics()
                self?.applyConfigSideEffects()
                self?.observeConfig()
            }
        }
    }

    /// Config knobs that reach outside the render tree.
    private func applyConfigSideEffects() {
        keepAwake.setActive(configStore.config.options.keepAwake && dashboardVisible)
        display.selection = configStore.config.display
    }

    var settingsDependencies: SettingsDependencies {
        SettingsDependencies(
            configStore: configStore,
            registry: registry,
            hub: hub,
            services: widgetServices,
            debugMetricIDs: debugMetricIDs,
            touchCapture: { [weak self] in self?.touchCapture },
            touchRouter: touchRouter,
            statusText: { [weak self] in self?.statusText ?? "" },
            displayChoices: { Self.displayChoices() },
            onTouchRefresh: { [weak self] in self?.refreshTouch() },
            onVisibilityChange: { [weak self] in self?.setSettingsVisible($0) }
        )
    }

    static func displayChoices() -> [DisplayChoice] {
        DisplayController.onlineDisplays().compactMap { displayID in
            guard let uuid = DisplayController.uuidString(for: displayID) else { return nil }
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
            }
            return DisplayChoice(
                id: uuid,
                name: screen?.localizedName ?? "Display \(displayID)",
                isProfileMatch: DisplayController.matchProfile(displayID) != nil
            )
        }
    }

    private func refreshActiveMetrics() {
        let config = configStore.config
        let page = config.pages.first { $0.id == config.activePageID } ?? config.pages.first
        var wanted = page.map { registry.requiredMetrics(for: $0) } ?? []
        if settingsVisible {
            wanted.formUnion(debugMetricIDs) // Debug tab shows everything
        }
        Task { await engine.setActiveMetrics(wanted) }
        refreshServiceActivation(activePage: page)
    }

    /// Service-backed widgets (media, agents) mirror the metric gating: their
    /// pollers run only while a page showing them can actually be seen — the
    /// visible dashboard's active page, or any page while settings is open.
    private func refreshServiceActivation(activePage: DashboardPage?) {
        func shouldRun(_ typeID: WidgetTypeID) -> Bool {
            let hasWidget = { (page: DashboardPage) in
                page.placements.contains { $0.type == typeID }
            }
            let onDashboard = dashboardVisible && (activePage.map(hasWidget) ?? false)
            let inSettings = settingsVisible && configStore.config.pages.contains(where: hasWidget)
            return onDashboard || inSettings
        }
        musicPlayer.setActive(shouldRun(NowPlayingWidget.typeID))
        claudeMonitor.setActive(shouldRun(ClaudeCodeWidget.typeID))
    }

    /// Sample only while someone is looking: dashboard on a screen or the
    /// settings window open.
    private func updateEngineState() {
        let shouldRun = dashboardVisible || settingsVisible
        refreshActiveMetrics()
        Task { await engine.setPaused(!shouldRun) }
    }
}

/// Observable bridge: re-renders when the config (or metric stores read by
/// widgets) change, without recreating the hosting window. Also carries the
/// touch environment and the page-swipe surface (lowest z — every widget
/// target sits above it).
struct DashboardHost: View {
    var model: AppModel

    var body: some View {
        DashboardRootView(
            config: model.configStore.config,
            registry: model.registry,
            hub: model.hub,
            services: model.widgetServices,
            screen: model.display.screen
        )
        // Order matters: .environment only flows inward, so the swipe
        // target must sit INSIDE the router environment to see it.
        .touchTarget(accepts: [.swipe], zIndex: 0) { event in
            if case .swipe(let direction) = event {
                switch direction {
                case .left: model.switchPage(1)
                case .right: model.switchPage(-1)
                default: break
                }
            }
        }
        .environment(\.touchRouter, model.touchRouter)
    }
}
