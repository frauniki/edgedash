import WidgetEngine

public enum AgentWidgets {
    @MainActor public static func registerAll(in registry: WidgetRegistry) {
        registry.register(ClaudeCodeWidget.self)
    }
}
