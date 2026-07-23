import EdgeCore
import SwiftUI

public enum WidgetCategory: String, Codable, Sendable, CaseIterable {
    case monitoring
    case media
    case shortcut
    case agent
    case utility
}

public protocol DefaultInitializable {
    init()
}

/// The extensibility contract: every widget — built-in now, media/shortcut/
/// agent/plugin later — is a WidgetDefinition registered with WidgetRegistry.
public protocol WidgetDefinition {
    associatedtype Config: Codable & Sendable & DefaultInitializable

    static var typeID: WidgetTypeID { get }
    static var displayName: String { get }
    static var category: WidgetCategory { get }
    static var supportedSizes: [GridSize] { get }
    /// Metric subscriptions this widget needs for a given config; drives
    /// refcounted sampling of only-visible metrics.
    static func requiredMetrics(for config: Config) -> Set<MetricID>

    @MainActor static func makeView(config: Config, context: WidgetContext) -> AnyView
    /// Context gives config UIs access to live data (e.g. discovered sensor
    /// names for a picker), not just static options.
    @MainActor static func makeConfigView(config: Binding<Config>, context: WidgetContext) -> AnyView
}

/// Non-metric data sources for widgets (media controllers, agent feeds, …),
/// keyed by type. Metrics flow through MetricHub; anything that can't be a
/// MetricValue is registered here by the app and resolved by widget views.
@MainActor public final class WidgetServices {
    private var storage: [ObjectIdentifier: Any] = [:]

    public init() {}

    public func register<T>(_ service: T) {
        storage[ObjectIdentifier(T.self)] = service
    }

    public func resolve<T>(_ type: T.Type) -> T? {
        storage[ObjectIdentifier(type)] as? T
    }
}

/// Per-instance environment handed to widget views.
public struct WidgetContext {
    public let hub: MetricHub
    public let size: GridSize
    public let services: WidgetServices

    @MainActor public init(hub: MetricHub, size: GridSize, services: WidgetServices? = nil) {
        self.hub = hub
        self.size = size
        self.services = services ?? WidgetServices()
    }
}

/// Type-erased widget definition. Placements carry an opaque config blob;
/// this wrapper is the only place that decodes it. A corrupt or missing blob
/// decodes to the widget's default config — never an error.
public struct AnyWidgetDefinition: Identifiable, Sendable {
    public let typeID: WidgetTypeID
    public let displayName: String
    public let category: WidgetCategory
    public let supportedSizes: [GridSize]

    private let _requiredMetrics: @Sendable (Data?) -> Set<MetricID>
    private let _makeView: @MainActor @Sendable (Data?, WidgetContext) -> AnyView
    private let _makeConfigView: @MainActor @Sendable (Binding<Data?>, WidgetContext) -> AnyView
    private let _defaultConfigData: @Sendable () -> Data?

    public var id: WidgetTypeID { typeID }

    public init<W: WidgetDefinition>(_ widget: W.Type) {
        typeID = W.typeID
        displayName = W.displayName
        category = W.category
        supportedSizes = W.supportedSizes
        _requiredMetrics = { W.requiredMetrics(for: Self.decodeConfig(W.self, from: $0)) }
        _makeView = { W.makeView(config: Self.decodeConfig(W.self, from: $0), context: $1) }
        _makeConfigView = { dataBinding, context in
            // Bridge the opaque blob to the widget's typed config: decode on
            // read, re-encode on every write so edits persist immediately.
            let typed = Binding<W.Config>(
                get: { Self.decodeConfig(W.self, from: dataBinding.wrappedValue) },
                set: { dataBinding.wrappedValue = try? JSONEncoder().encode($0) }
            )
            return W.makeConfigView(config: typed, context: context)
        }
        _defaultConfigData = { try? JSONEncoder().encode(W.Config()) }
    }

    @MainActor public func makeConfigView(configData: Binding<Data?>, context: WidgetContext) -> AnyView {
        _makeConfigView(configData, context)
    }

    public func requiredMetrics(configData: Data?) -> Set<MetricID> {
        _requiredMetrics(configData)
    }

    @MainActor public func makeView(configData: Data?, context: WidgetContext) -> AnyView {
        _makeView(configData, context)
    }

    public func defaultConfigData() -> Data? {
        _defaultConfigData()
    }

    static func decodeConfig<W: WidgetDefinition>(_ widget: W.Type, from data: Data?) -> W.Config {
        guard let data else { return W.Config() }
        return (try? JSONDecoder().decode(W.Config.self, from: data)) ?? W.Config()
    }
}

@MainActor public final class WidgetRegistry {
    private var definitions: [WidgetTypeID: AnyWidgetDefinition] = [:]

    public init() {}

    public func register<W: WidgetDefinition>(_ widget: W.Type) {
        definitions[W.typeID] = AnyWidgetDefinition(widget)
    }

    public func definition(for id: WidgetTypeID) -> AnyWidgetDefinition? {
        definitions[id]
    }

    /// Powers the settings gallery, grouped by category.
    public var all: [AnyWidgetDefinition] {
        definitions.values.sorted { $0.typeID.rawValue < $1.typeID.rawValue }
    }

    /// Union of metric needs for a page — what the engine should sample.
    public func requiredMetrics(for page: DashboardPage) -> Set<MetricID> {
        page.placements.reduce(into: []) { result, placement in
            if let definition = definitions[placement.type] {
                result.formUnion(definition.requiredMetrics(configData: placement.configData))
            }
        }
    }
}
