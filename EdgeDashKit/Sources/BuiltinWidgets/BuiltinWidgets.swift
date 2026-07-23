import EdgeCore
import WidgetEngine

public enum BuiltinWidgets {
    @MainActor public static func registerAll(in registry: WidgetRegistry) {
        registry.register(ClockWidget.self)
        registry.register(CPUWidget.self)
        registry.register(MemoryWidget.self)
        registry.register(GPUWidget.self)
        registry.register(NetworkWidget.self)
        registry.register(DiskWidget.self)
        registry.register(TemperatureWidget.self)
        registry.register(FanWidget.self)
    }

    /// Starter layout for a fresh install (landscape 8×2 grid).
    /// Page 1: overview. Page 2: sensors.
    public static func starterPages() -> [DashboardPage] {
        let overview = DashboardPage(name: "Overview", placements: [
            WidgetPlacement(
                type: ClockWidget.typeID,
                frame: GridRect(col: 0, row: 0, size: GridSize(cols: 2, rows: 1))
            ),
            WidgetPlacement(
                type: NetworkWidget.typeID,
                frame: GridRect(col: 0, row: 1, size: GridSize(cols: 2, rows: 1))
            ),
            WidgetPlacement(
                type: CPUWidget.typeID,
                frame: GridRect(col: 2, row: 0, size: GridSize(cols: 2, rows: 2))
            ),
            WidgetPlacement(
                type: MemoryWidget.typeID,
                frame: GridRect(col: 4, row: 0, size: GridSize(cols: 2, rows: 2))
            ),
            WidgetPlacement(
                type: GPUWidget.typeID,
                frame: GridRect(col: 6, row: 0, size: GridSize(cols: 2, rows: 1))
            ),
            WidgetPlacement(
                type: DiskWidget.typeID,
                frame: GridRect(col: 6, row: 1, size: GridSize(cols: 2, rows: 1))
            ),
        ])
        let sensors = DashboardPage(name: "Sensors", placements: [
            WidgetPlacement(
                type: TemperatureWidget.typeID,
                frame: GridRect(col: 0, row: 0, size: GridSize(cols: 4, rows: 2))
            ),
            WidgetPlacement(
                type: FanWidget.typeID,
                frame: GridRect(col: 4, row: 0, size: GridSize(cols: 2, rows: 2))
            ),
            WidgetPlacement(
                type: CPUWidget.typeID,
                frame: GridRect(col: 6, row: 0, size: GridSize(cols: 2, rows: 2))
            ),
        ])
        return [overview, sensors]
    }
}
