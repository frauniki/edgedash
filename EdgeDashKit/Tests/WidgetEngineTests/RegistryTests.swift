import EdgeCore
import Foundation
import SwiftUI
import Testing
@testable import WidgetEngine

private struct FakeWidget: WidgetDefinition {
    struct Config: Codable, DefaultInitializable {
        var flavor = "default"
        var extra = false
    }

    static let typeID = WidgetTypeID("test.fake")
    static let displayName = "Fake"
    static let category = WidgetCategory.utility
    static let supportedSizes = [GridSize(cols: 1, rows: 1)]

    static func requiredMetrics(for config: Config) -> Set<MetricID> {
        config.extra ? [MetricID("test.a"), MetricID("test.b")] : [MetricID("test.a")]
    }

    @MainActor static func makeView(config: Config, context: WidgetContext) -> AnyView {
        AnyView(Text(config.flavor))
    }

    @MainActor static func makeConfigView(config: Binding<Config>, context: WidgetContext) -> AnyView {
        AnyView(EmptyView())
    }
}

@MainActor struct RegistryTests {
    @Test func registerAndLookup() {
        let registry = WidgetRegistry()
        registry.register(FakeWidget.self)
        #expect(registry.definition(for: FakeWidget.typeID) != nil)
        #expect(registry.definition(for: WidgetTypeID("nope")) == nil)
        #expect(registry.all.count == 1)
    }

    @Test func erasedConfigDecodingIsGraceful() throws {
        let definition = AnyWidgetDefinition(FakeWidget.self)

        // Valid config round-trips.
        let valid = try JSONEncoder().encode(["flavor": "custom", "extra": "x"])
        _ = valid // (heterogeneous dict won't decode — that's the corrupt case below)

        var config = FakeWidget.Config()
        config.extra = true
        let good = try JSONEncoder().encode(config)
        #expect(definition.requiredMetrics(configData: good).count == 2)

        // Corrupt blob and nil both fall back to defaults, never crash.
        let corrupt = Data("not json at all".utf8)
        #expect(definition.requiredMetrics(configData: corrupt).count == 1)
        #expect(definition.requiredMetrics(configData: nil).count == 1)
    }

    @Test func servicesResolveByType() {
        final class ServiceA { let value = 1 }
        final class ServiceB {}
        let services = WidgetServices()
        services.register(ServiceA())
        #expect(services.resolve(ServiceA.self)?.value == 1)
        #expect(services.resolve(ServiceB.self) == nil)
    }

    @Test func pageMetricsUnionSkipsUnknownTypes() {
        let registry = WidgetRegistry()
        registry.register(FakeWidget.self)
        let page = DashboardPage(name: "P", placements: [
            WidgetPlacement(type: FakeWidget.typeID, frame: GridRect(col: 0, row: 0, size: GridSize(cols: 1, rows: 1))),
            WidgetPlacement(type: WidgetTypeID("gone.widget"), frame: GridRect(col: 1, row: 0, size: GridSize(cols: 1, rows: 1))),
        ])
        #expect(registry.requiredMetrics(for: page) == [MetricID("test.a")])
    }
}
