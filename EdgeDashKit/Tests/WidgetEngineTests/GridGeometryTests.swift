import EdgeCore
import Foundation
import Testing
@testable import WidgetEngine

// @MainActor: the geometry helpers live on DashboardPageView, whose View
// conformance makes them MainActor-isolated.
@MainActor @Suite struct GridGeometryTests {
    private let canvas = CGSize(width: 2560, height: 720)
    private let grid = GridDimensions.landscape

    @Test func cellRectRoundTripsThroughGridOrigin() {
        for cols in 1...2 {
            for rows in 1...2 {
                let size = GridSize(cols: cols, rows: rows)
                for col in 0...(grid.cols - cols) {
                    for row in 0...(grid.rows - rows) {
                        let frame = GridRect(col: col, row: row, size: size)
                        let rect = DashboardPageView.cellRect(for: frame, in: canvas, grid: grid)
                        let origin = DashboardPageView.gridOrigin(at: rect.origin, size: size, in: canvas, grid: grid)
                        #expect(origin.col == col)
                        #expect(origin.row == row)
                    }
                }
            }
        }
    }

    @Test func nearbyPointsSnapToSameCell() {
        let size = GridSize(cols: 2, rows: 1)
        let frame = GridRect(col: 3, row: 1, size: size)
        let rect = DashboardPageView.cellRect(for: frame, in: canvas, grid: grid)
        let cell = DashboardPageView.cellSize(in: canvas, grid: grid)
        // Anywhere within just under half a cell of the true origin snaps back.
        let jitter = CGPoint(x: rect.minX + cell.width * 0.4, y: rect.minY - cell.height * 0.4)
        let origin = DashboardPageView.gridOrigin(at: jitter, size: size, in: canvas, grid: grid)
        #expect(origin.col == 3)
        #expect(origin.row == 1)
    }

    @Test func gridOriginClampsToBounds() {
        let size = GridSize(cols: 2, rows: 2)
        let farOut = DashboardPageView.gridOrigin(
            at: CGPoint(x: 99999, y: 99999), size: size, in: canvas, grid: grid
        )
        #expect(farOut.col == grid.cols - 2)
        #expect(farOut.row == 0) // rows: 2-row widget in a 2-row grid → row 0
        let negative = DashboardPageView.gridOrigin(
            at: CGPoint(x: -500, y: -500), size: size, in: canvas, grid: grid
        )
        #expect(negative.col == 0)
        #expect(negative.row == 0)
    }

    @Test func cellRectMatchesRendererMath() {
        // 8×2 landscape on 2560×720: inner 2528×688, cell 316×344.
        let rect = DashboardPageView.cellRect(
            for: GridRect(col: 1, row: 1, size: GridSize(cols: 2, rows: 1)),
            in: canvas, grid: grid
        )
        func approx(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }
        #expect(approx(rect.minX, 338))   // inset + 1 cell + gutter/2
        #expect(approx(rect.minY, 366))
        #expect(approx(rect.width, 620))  // 2 cells minus gutter
        #expect(approx(rect.height, 332))
    }
}
