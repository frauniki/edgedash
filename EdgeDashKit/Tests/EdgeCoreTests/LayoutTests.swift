import EdgeCore
import Foundation
import Testing

@Suite struct LayoutTests {
    @Test func overlapDetection() {
        let a = GridRect(col: 0, row: 0, size: GridSize(cols: 2, rows: 1))
        let adjacent = GridRect(col: 2, row: 0, size: GridSize(cols: 1, rows: 1))
        let overlapping = GridRect(col: 1, row: 0, size: GridSize(cols: 2, rows: 2))
        #expect(!a.overlaps(adjacent))
        #expect(a.overlaps(overlapping))
        #expect(overlapping.overlaps(a))
    }

    @Test func fitsRespectsGridBounds() {
        let grid = GridDimensions.landscape // 8×2
        #expect(GridRect(col: 6, row: 0, size: GridSize(cols: 2, rows: 2)).fits(cols: grid.cols, rows: grid.rows))
        #expect(!GridRect(col: 7, row: 0, size: GridSize(cols: 2, rows: 1)).fits(cols: grid.cols, rows: grid.rows))
        #expect(!GridRect(col: 0, row: 1, size: GridSize(cols: 1, rows: 2)).fits(cols: grid.cols, rows: grid.rows))
        #expect(!GridRect(col: -1, row: 0, size: GridSize(cols: 1, rows: 1)).fits(cols: grid.cols, rows: grid.rows))
    }

    @Test func firstFreeSlotScansRowMajor() {
        let occupied = [GridRect(col: 0, row: 0, size: GridSize(cols: 2, rows: 2))]
        let slot = LayoutEngine.firstFreeSlot(
            for: GridSize(cols: 2, rows: 1), among: occupied, in: .landscape
        )
        #expect(slot == GridRect(col: 2, row: 0, size: GridSize(cols: 2, rows: 1)))
    }

    @Test func firstFreeSlotReturnsNilWhenFull() {
        let occupied = [GridRect(col: 0, row: 0, size: GridSize(cols: 8, rows: 2))]
        let slot = LayoutEngine.firstFreeSlot(
            for: GridSize(cols: 1, rows: 1), among: occupied, in: .landscape
        )
        #expect(slot == nil)
    }

    @Test func aspectPicksGridOrientation() {
        #expect(GridDimensions.forAspect(width: 2560, height: 720) == .landscape)
        #expect(GridDimensions.forAspect(width: 720, height: 2560) == .portrait)
    }

    @Test func configRoundTripsThroughJSON() throws {
        var config = DashboardConfig()
        config.pages = [
            DashboardPage(name: "Main", placements: [
                WidgetPlacement(
                    type: WidgetTypeID("edgedash.cpu"),
                    frame: GridRect(col: 0, row: 0, size: GridSize(cols: 2, rows: 2)),
                    configData: Data("{}".utf8)
                )
            ])
        ]
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(DashboardConfig.self, from: data)
        #expect(decoded.schemaVersion == DashboardConfig.currentSchemaVersion)
        #expect(decoded.pages.count == 1)
        #expect(decoded.pages[0].placements[0].type == WidgetTypeID("edgedash.cpu"))
    }
}
