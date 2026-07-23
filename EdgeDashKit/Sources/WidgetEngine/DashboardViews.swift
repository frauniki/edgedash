import EdgeCore
import SwiftUI

/// Root view for the dashboard surface: renders the active page of a config.
/// Resolution-independent — cell size derives from the available space.
public struct DashboardRootView: View {
    private let config: DashboardConfig
    private let registry: WidgetRegistry
    private let hub: MetricHub
    private let services: WidgetServices?

    public init(config: DashboardConfig, registry: WidgetRegistry, hub: MetricHub, services: WidgetServices? = nil) {
        self.config = config
        self.registry = registry
        self.hub = hub
        self.services = services
    }

    private var activePage: DashboardPage? {
        config.pages.first { $0.id == config.activePageID } ?? config.pages.first
    }

    public var body: some View {
        let theme = BuiltinThemes.theme(for: config.themeID)
        ZStack {
            if config.options.backgroundBlur {
                BehindWindowBlur()
            }
            theme.pageBackground.color.opacity(config.options.backgroundOpacity)
            if let page = activePage {
                DashboardPageView(page: page, registry: registry, hub: hub, services: services)
                    .id(page.id)
                    .transition(.opacity)
                if config.pages.count > 1 {
                    PageDots(count: config.pages.count, active: pageIndex(of: page))
                }
            } else {
                Text("No pages configured")
                    .font(.title3)
                    .foregroundStyle(theme.textSecondary.color)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: activePage?.id)
        .ignoresSafeArea()
        .colorScheme(.dark)
        .environment(\.theme, theme)
    }

    private func pageIndex(of page: DashboardPage) -> Int {
        config.pages.firstIndex { $0.id == page.id } ?? 0
    }
}

public struct DashboardPageView: View {
    static let pageInset: CGFloat = 16
    static let gutter: CGFloat = 12

    let page: DashboardPage
    let registry: WidgetRegistry
    let hub: MetricHub
    let services: WidgetServices?

    public init(page: DashboardPage, registry: WidgetRegistry, hub: MetricHub, services: WidgetServices? = nil) {
        self.page = page
        self.registry = registry
        self.hub = hub
        self.services = services
    }

    public var body: some View {
        GeometryReader { proxy in
            let grid = GridDimensions.forAspect(
                width: proxy.size.width - Self.pageInset * 2,
                height: proxy.size.height - Self.pageInset * 2
            )
            ForEach(page.placements) { placement in
                let rect = Self.cellRect(for: placement.frame, in: proxy.size, grid: grid)
                widgetBody(for: placement)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    // MARK: - Grid geometry (shared with the settings miniature editor)

    /// Cell pitch for a canvas; the widget rect is a span of cells minus the
    /// gutter.
    public static func cellSize(in canvas: CGSize, grid: GridDimensions) -> CGSize {
        CGSize(
            width: (canvas.width - pageInset * 2) / CGFloat(grid.cols),
            height: (canvas.height - pageInset * 2) / CGFloat(grid.rows)
        )
    }

    /// The exact rect the renderer gives a grid frame (canvas space).
    public static func cellRect(for frame: GridRect, in canvas: CGSize, grid: GridDimensions) -> CGRect {
        let cell = cellSize(in: canvas, grid: grid)
        return CGRect(
            x: pageInset + cell.width * CGFloat(frame.col) + gutter / 2,
            y: pageInset + cell.height * CGFloat(frame.row) + gutter / 2,
            width: cell.width * CGFloat(frame.size.cols) - gutter,
            height: cell.height * CGFloat(frame.size.rows) - gutter
        )
    }

    /// Nearest grid origin for a widget whose top-left corner is at `point`
    /// (canvas space), clamped so `size` stays inside the grid. Inverse of
    /// `cellRect`'s origin — used to snap drags.
    public static func gridOrigin(
        at point: CGPoint,
        size: GridSize,
        in canvas: CGSize,
        grid: GridDimensions
    ) -> (col: Int, row: Int) {
        let cell = cellSize(in: canvas, grid: grid)
        let col = Int((Double(point.x - pageInset - gutter / 2) / cell.width).rounded())
        let row = Int((Double(point.y - pageInset - gutter / 2) / cell.height).rounded())
        return (
            col: min(max(col, 0), max(0, grid.cols - size.cols)),
            row: min(max(row, 0), max(0, grid.rows - size.rows))
        )
    }

    @ViewBuilder
    private func widgetBody(for placement: WidgetPlacement) -> some View {
        if placement.chrome {
            WidgetChrome { widgetContent(for: placement) }
        } else {
            widgetContent(for: placement)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func widgetContent(for placement: WidgetPlacement) -> some View {
        if let definition = registry.definition(for: placement.type) {
            definition.makeView(
                configData: placement.configData,
                context: WidgetContext(hub: hub, size: placement.frame.size, services: services)
            )
        } else {
            UnknownWidgetView(type: placement.type)
        }
    }
}

/// Frosted-glass blur of whatever sits behind the dashboard window — on the
/// EDGE that's the desktop wallpaper.
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active // never dim: the dashboard window is never key
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Shared widget frame: gradient surface with a top-lit hairline stroke.
public struct WidgetChrome<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(theme.surfaceGradient))
            .overlay(shape.strokeBorder(theme.strokeGradient, lineWidth: 1))
            .clipShape(shape)
    }
}

/// Placeholder for removed/unavailable widget types — never fails the page.
struct UnknownWidgetView: View {
    @Environment(\.theme) private var theme
    let type: WidgetTypeID

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "questionmark.square.dashed")
                .font(.title2)
            Text(type.rawValue)
                .font(.caption.monospaced())
        }
        .foregroundStyle(theme.textSecondary.color)
    }
}

struct PageDots: View {
    @Environment(\.theme) private var theme
    let count: Int
    let active: Int

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { index in
                    Circle()
                        .fill(index == active ? theme.accent.color : theme.textSecondary.color.opacity(0.4))
                        .frame(width: 5, height: 5)
                        .shadow(color: index == active ? theme.accent.color.opacity(0.8) : .clear, radius: 3)
                }
            }
            .padding(.bottom, 5)
        }
    }
}
