import WidgetEngine

public enum WeatherWidgets {
    @MainActor public static func registerAll(in registry: WidgetRegistry) {
        registry.register(WeatherWidget.self)
    }
}
