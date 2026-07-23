import WidgetEngine

public enum MediaWidgets {
    @MainActor public static func registerAll(in registry: WidgetRegistry) {
        registry.register(NowPlayingWidget.self)
    }
}
