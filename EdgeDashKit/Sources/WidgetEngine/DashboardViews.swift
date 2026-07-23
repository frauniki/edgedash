import EdgeCore
import SwiftUI

/// Root view for the dashboard surface: renders the active page of a config.
/// Resolution-independent — cell size derives from the available space.
public struct DashboardRootView: View {
    private let config: DashboardConfig
    private let registry: WidgetRegistry
    private let hub: MetricHub

    public init(config: DashboardConfig, registry: WidgetRegistry, hub: MetricHub) {
        self.config = config
        self.registry = registry
        self.hub = hub
    }

    private var activePage: DashboardPage? {
        config.pages.first { $0.id == config.activePageID } ?? config.pages.first
    }

    public var body: some View {
        let theme = BuiltinThemes.theme(for: config.themeID)
        ZStack {
            theme.pageBackground.color
            if let page = activePage {
                DashboardPageView(page: page, registry: registry, hub: hub)
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

    public init(page: DashboardPage, registry: WidgetRegistry, hub: MetricHub) {
        self.page = page
        self.registry = registry
        self.hub = hub
    }

    public var body: some View {
        GeometryReader { proxy in
            let inner = CGSize(
                width: proxy.size.width - Self.pageInset * 2,
                height: proxy.size.height - Self.pageInset * 2
            )
            let grid = GridDimensions.forAspect(width: inner.width, height: inner.height)
            let cellW = inner.width / CGFloat(grid.cols)
            let cellH = inner.height / CGFloat(grid.rows)

            ForEach(page.placements) { placement in
                let frame = placement.frame
                let width = cellW * CGFloat(frame.size.cols) - Self.gutter
                let height = cellH * CGFloat(frame.size.rows) - Self.gutter
                widgetBody(for: placement)
                    .frame(width: width, height: height)
                    .position(
                        x: Self.pageInset + cellW * (CGFloat(frame.col) + CGFloat(frame.size.cols) / 2),
                        y: Self.pageInset + cellH * (CGFloat(frame.row) + CGFloat(frame.size.rows) / 2)
                    )
            }
        }
    }

    @ViewBuilder
    private func widgetBody(for placement: WidgetPlacement) -> some View {
        WidgetChrome {
            if let definition = registry.definition(for: placement.type) {
                definition.makeView(
                    configData: placement.configData,
                    context: WidgetContext(hub: hub, size: placement.frame.size)
                )
            } else {
                UnknownWidgetView(type: placement.type)
            }
        }
    }
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
