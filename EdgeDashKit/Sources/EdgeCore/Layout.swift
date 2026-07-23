import Foundation

/// Identifies a widget implementation, e.g. "edgedash.cpu".
public struct WidgetTypeID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Size in grid units. The grid is resolution-independent: cell point size is
/// derived from the screen at render time, never stored.
public struct GridSize: Codable, Hashable, Sendable {
    public var cols: Int
    public var rows: Int
    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

public struct GridRect: Codable, Hashable, Sendable {
    public var col: Int
    public var row: Int
    public var size: GridSize

    public init(col: Int, row: Int, size: GridSize) {
        self.col = col
        self.row = row
        self.size = size
    }

    public var maxCol: Int { col + size.cols }
    public var maxRow: Int { row + size.rows }

    public func overlaps(_ other: GridRect) -> Bool {
        col < other.maxCol && other.col < maxCol && row < other.maxRow && other.row < maxRow
    }

    public func fits(cols: Int, rows: Int) -> Bool {
        col >= 0 && row >= 0 && size.cols > 0 && size.rows > 0 && maxCol <= cols && maxRow <= rows
    }
}

/// Grid dimensions for a dashboard surface. Landscape is 8×2; portrait
/// (rotated mount) transposes to 2×8.
public struct GridDimensions: Codable, Hashable, Sendable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }

    public static let landscape = GridDimensions(cols: 8, rows: 2)
    public static let portrait = GridDimensions(cols: 2, rows: 8)

    public static func forAspect(width: Double, height: Double) -> GridDimensions {
        width >= height ? .landscape : .portrait
    }
}

public struct WidgetPlacement: Codable, Identifiable, Sendable {
    public var id: UUID
    public var type: WidgetTypeID
    public var frame: GridRect
    /// Widget-private configuration, encoded by the owning widget definition.
    /// Opaque here so unknown widget types survive decoding.
    public var configData: Data?
    /// Draw the card surface behind the widget; false floats the content
    /// directly on the page background.
    public var chrome: Bool

    public init(id: UUID = UUID(), type: WidgetTypeID, frame: GridRect, configData: Data? = nil, chrome: Bool = true) {
        self.id = id
        self.type = type
        self.frame = frame
        self.configData = configData
        self.chrome = chrome
    }

    // Manual decoding so configs written before `chrome` existed stay valid.
    private enum CodingKeys: String, CodingKey {
        case id, type, frame, configData, chrome
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(WidgetTypeID.self, forKey: .type)
        frame = try container.decode(GridRect.self, forKey: .frame)
        configData = try container.decodeIfPresent(Data.self, forKey: .configData)
        chrome = try container.decodeIfPresent(Bool.self, forKey: .chrome) ?? true
    }
}

public struct DashboardPage: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var placements: [WidgetPlacement]

    public init(id: UUID = UUID(), name: String, placements: [WidgetPlacement] = []) {
        self.id = id
        self.name = name
        self.placements = placements
    }
}

public enum DisplaySelection: Codable, Sendable, Equatable {
    /// Scan for any known device profile in DeviceCatalog.
    case autoDetect
    /// Persisted CGDisplay UUID strings — any display works, not just known
    /// devices. A list so multi-display stays cheap later.
    case byUUIDs([String])
}

public struct GlobalOptions: Codable, Sendable, Equatable {
    /// Prevent display sleep while the dashboard is visible. Affects ALL
    /// displays — macOS has no per-display sleep.
    public var keepAwake: Bool
    /// Page background opacity 0…1; below 1 the desktop wallpaper behind the
    /// dashboard window shows through.
    public var backgroundOpacity: Double
    /// Frosted-glass blur of whatever is behind the window (the wallpaper).
    public var backgroundBlur: Bool

    public init(keepAwake: Bool = false, backgroundOpacity: Double = 1, backgroundBlur: Bool = false) {
        self.keepAwake = keepAwake
        self.backgroundOpacity = backgroundOpacity
        self.backgroundBlur = backgroundBlur
    }

    // Manual decoding so configs written before these knobs existed stay valid.
    private enum CodingKeys: String, CodingKey {
        case keepAwake, backgroundOpacity, backgroundBlur
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keepAwake = try container.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? false
        backgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 1
        backgroundBlur = try container.decodeIfPresent(Bool.self, forKey: .backgroundBlur) ?? false
    }
}

public struct ThemeID: Hashable, Codable, Sendable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    public static let graphite = ThemeID("graphite")
}

public struct DashboardConfig: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var pages: [DashboardPage]
    public var activePageID: UUID?
    public var themeID: ThemeID
    public var display: DisplaySelection
    public var options: GlobalOptions

    public init(
        schemaVersion: Int = DashboardConfig.currentSchemaVersion,
        pages: [DashboardPage] = [],
        activePageID: UUID? = nil,
        themeID: ThemeID = .graphite,
        display: DisplaySelection = .autoDetect,
        options: GlobalOptions = GlobalOptions()
    ) {
        self.schemaVersion = schemaVersion
        self.pages = pages
        self.activePageID = activePageID
        self.themeID = themeID
        self.display = display
        self.options = options
    }
}

/// Pure layout math over grid rects — no UI dependencies, fully unit-testable.
public enum LayoutEngine {
    /// A placement is valid when it fits the grid and overlaps no sibling.
    public static func validate(_ frame: GridRect, among others: [GridRect], in grid: GridDimensions) -> Bool {
        frame.fits(cols: grid.cols, rows: grid.rows) && !others.contains { $0.overlaps(frame) }
    }

    /// First free origin (row-major scan) where `size` fits, or nil if the page is full.
    public static func firstFreeSlot(for size: GridSize, among others: [GridRect], in grid: GridDimensions) -> GridRect? {
        for row in 0...(Swift.max(0, grid.rows - size.rows)) {
            for col in 0...(Swift.max(0, grid.cols - size.cols)) {
                let candidate = GridRect(col: col, row: row, size: size)
                if validate(candidate, among: others, in: grid) {
                    return candidate
                }
            }
        }
        return nil
    }
}
