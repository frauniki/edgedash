import WidgetEngine
import Testing

@Suite struct WidgetEngineTests {
    @Test func categoriesAreStableForPersistence() {
        // Raw values end up in config files — changing them is a schema migration.
        #expect(WidgetCategory.monitoring.rawValue == "monitoring")
        #expect(WidgetCategory.allCases.count == 5)
    }
}
