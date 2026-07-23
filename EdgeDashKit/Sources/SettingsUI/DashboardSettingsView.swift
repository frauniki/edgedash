import EdgeCore
import SwiftUI
import WidgetEngine

/// Pages editor: list of pages, a live to-scale miniature of the selected
/// page, an add-widget gallery, and a per-placement inspector. All edits go
/// through ConfigStore.update → the EDGE reflects them live.
public struct DashboardSettingsView: View {
    private let configStore: ConfigStore
    private let registry: WidgetRegistry
    private let hub: MetricHub
    private let services: WidgetServices?

    @State private var selectedPageID: UUID?
    @State private var selectedPlacementID: UUID?

    public init(configStore: ConfigStore, registry: WidgetRegistry, hub: MetricHub, services: WidgetServices? = nil) {
        self.configStore = configStore
        self.registry = registry
        self.hub = hub
        self.services = services
    }

    private var config: DashboardConfig { configStore.config }

    private var selectedPage: DashboardPage? {
        config.pages.first { $0.id == selectedPageID } ?? config.pages.first
    }

    public var body: some View {
        HSplitView {
            pageList
                .frame(minWidth: 150, maxWidth: 200)
            VStack(spacing: 12) {
                if let page = selectedPage {
                    miniature(page: page)
                    editor(page: page)
                } else {
                    ContentUnavailableView("No pages", systemImage: "rectangle.dashed")
                }
            }
            .padding(12)
            // .top, not the default .center — centering opened a dead band
            // above the miniature whenever the editor didn't claim all height.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // Selection is per-page; a stale id from another page kept the
        // remove button disabled in a confusing way.
        .onChange(of: selectedPageID) { _, _ in selectedPlacementID = nil }
    }

    // MARK: - Page list

    private var pageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selectedPageID) {
                ForEach(config.pages) { page in
                    HStack {
                        Text(page.name)
                        Spacer()
                        if page.id == (config.activePageID ?? config.pages.first?.id) {
                            Image(systemName: "eye.fill")
                                .foregroundStyle(.tint)
                                .help("Currently on the display")
                        }
                    }
                    .tag(page.id)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Button {
                    addPage()
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    removeSelectedPage()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(config.pages.count <= 1)
                Spacer()
                Button("Show") {
                    if let page = selectedPage {
                        configStore.update { $0.activePageID = page.id }
                    }
                }
                .disabled(selectedPage == nil)
                .help("Show this page on the display now")
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func addPage() {
        let page = DashboardPage(name: "Page \(config.pages.count + 1)")
        configStore.update { $0.pages.append(page) }
        selectedPageID = page.id
    }

    private func removeSelectedPage() {
        guard let page = selectedPage, config.pages.count > 1 else { return }
        configStore.update { config in
            config.pages.removeAll { $0.id == page.id }
            if config.activePageID == page.id {
                config.activePageID = config.pages.first?.id
            }
        }
        selectedPageID = nil
    }

    // MARK: - Miniature (live, to scale, drag-to-rearrange)

    private func miniature(page: DashboardPage) -> some View {
        InteractiveMiniature(
            page: page,
            registry: registry,
            hub: hub,
            services: services,
            themeID: config.themeID,
            selectedPlacementID: $selectedPlacementID,
            commitMove: { placementID, newFrame in
                configStore.update { config in
                    guard let pageIndex = config.pages.firstIndex(where: { $0.id == page.id }),
                          let index = config.pages[pageIndex].placements.firstIndex(where: { $0.id == placementID })
                    else { return } // placement vanished mid-drag (hand edit)
                    config.pages[pageIndex].placements[index].frame = newFrame
                }
            }
        )
        .aspectRatio(2560.0 / 720.0, contentMode: .fit)
        .frame(maxHeight: 180)
    }

    // MARK: - Placement editor

    private func editor(page: DashboardPage) -> some View {
        HSplitView {
            placementList(page: page)
                .frame(minWidth: 180, maxWidth: 240)
            inspector(page: page)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func placementList(page: DashboardPage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selectedPlacementID) {
                ForEach(page.placements) { placement in
                    HStack {
                        Text(registry.definition(for: placement.type)?.displayName ?? placement.type.rawValue)
                        Spacer()
                        Text("\(placement.frame.size.cols)×\(placement.frame.size.rows)")
                            .foregroundStyle(.secondary)
                            .font(.caption.monospaced())
                    }
                    .tag(placement.id)
                }
            }
            Divider()
            HStack(spacing: 8) {
                addWidgetMenu(page: page)
                Button {
                    removeSelectedPlacement(page: page)
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selectedPlacement(in: page) == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    private func addWidgetMenu(page: DashboardPage) -> some View {
        Menu {
            ForEach(WidgetCategory.allCases, id: \.self) { category in
                let widgets = registry.all.filter { $0.category == category }
                if !widgets.isEmpty {
                    Section(category.rawValue.capitalized) {
                        ForEach(widgets) { definition in
                            Button(definition.displayName) {
                                addWidget(definition, to: page)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden) // match the plain +/− buttons beside it
        .fixedSize()
    }

    private func addWidget(_ definition: AnyWidgetDefinition, to page: DashboardPage) {
        let grid = GridDimensions.landscape
        let occupied = page.placements.map(\.frame)
        // Prefer the widget's smallest size that still has a free slot.
        let sizes = definition.supportedSizes.sorted { $0.cols * $0.rows < $1.cols * $1.rows }
        for size in sizes {
            if let slot = LayoutEngine.firstFreeSlot(for: size, among: occupied, in: grid) {
                let placement = WidgetPlacement(
                    type: definition.typeID,
                    frame: slot,
                    configData: definition.defaultConfigData()
                )
                configStore.update { config in
                    guard let index = config.pages.firstIndex(where: { $0.id == page.id }) else { return }
                    config.pages[index].placements.append(placement)
                }
                selectedPlacementID = placement.id
                return
            }
        }
        NSSound.beep() // page is full
    }

    private func removeSelectedPlacement(page: DashboardPage) {
        guard let placement = selectedPlacement(in: page) else { return }
        configStore.update { config in
            guard let index = config.pages.firstIndex(where: { $0.id == page.id }) else { return }
            config.pages[index].placements.removeAll { $0.id == placement.id }
        }
        selectedPlacementID = nil
    }

    private func selectedPlacement(in page: DashboardPage) -> WidgetPlacement? {
        page.placements.first { $0.id == selectedPlacementID }
    }

    // MARK: - Inspector

    @ViewBuilder
    private func inspector(page: DashboardPage) -> some View {
        if let placement = selectedPlacement(in: page),
           let definition = registry.definition(for: placement.type) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(definition.displayName)
                        .font(.headline)
                    PlacementGeometryEditor(
                        placement: placement,
                        definition: definition,
                        siblings: page.placements.filter { $0.id != placement.id }.map(\.frame)
                    ) { newFrame in
                        updatePlacement(placement.id, in: page) { $0.frame = newFrame }
                    }
                    Toggle("Card background", isOn: Binding(
                        get: {
                            selectedPlacement(in: configStore.config.pages.first { $0.id == page.id } ?? page)?
                                .chrome ?? true
                        },
                        set: { on in updatePlacement(placement.id, in: page) { $0.chrome = on } }
                    ))
                    Divider()
                    definition.makeConfigView(
                        configData: Binding(
                            get: {
                                selectedPlacement(in: configStore.config.pages.first { $0.id == page.id } ?? page)?.configData
                            },
                            set: { newData in
                                updatePlacement(placement.id, in: page) { $0.configData = newData }
                            }
                        ),
                        context: WidgetContext(hub: hub, size: placement.frame.size, services: services)
                    )
                }
                .padding(12)
            }
        } else {
            ContentUnavailableView("Select a widget", systemImage: "slider.horizontal.3")
        }
    }

    private func updatePlacement(_ id: UUID, in page: DashboardPage, _ mutate: (inout WidgetPlacement) -> Void) {
        configStore.update { config in
            guard let pageIndex = config.pages.firstIndex(where: { $0.id == page.id }),
                  let placementIndex = config.pages[pageIndex].placements.firstIndex(where: { $0.id == id }) else { return }
            mutate(&config.pages[pageIndex].placements[placementIndex])
        }
    }
}

/// Live to-scale preview that is also the layout editor: click a widget to
/// select it, drag to move it with grid snapping. All geometry math happens
/// in the 2560×720 reference space (the same pure functions the renderer
/// uses); only the final rects are scaled down for display.
private struct InteractiveMiniature: View {
    let page: DashboardPage
    let registry: WidgetRegistry
    let hub: MetricHub
    let services: WidgetServices?
    let themeID: ThemeID
    @Binding var selectedPlacementID: UUID?
    let commitMove: (UUID, GridRect) -> Void

    private static let reference = CGSize(width: 2560, height: 720)
    private static let grid = GridDimensions.landscape

    @State private var dragID: UUID?
    @State private var dragTranslation: CGSize = .zero // miniature (scaled) space

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / Self.reference.width, proxy.size.height / Self.reference.height)
            let theme = BuiltinThemes.theme(for: themeID)
            ZStack(alignment: .topLeading) {
                ZStack {
                    theme.pageBackground.color
                    DashboardPageView(page: page, registry: registry, hub: hub, services: services)
                        .environment(\.colorScheme, .dark)
                        .environment(\.theme, theme)
                }
                .frame(width: Self.reference.width, height: Self.reference.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(
                    width: Self.reference.width * scale,
                    height: Self.reference.height * scale,
                    alignment: .topLeading
                )
                .allowsHitTesting(false) // widgets must not eat the editor's mouse

                ForEach(page.placements) { placement in
                    placementOverlay(placement, scale: scale)
                }

                if let ghost = ghostGeometry(scale: scale) {
                    let target = DashboardPageView
                        .cellRect(for: ghost.candidate, in: Self.reference, grid: Self.grid)
                        .scaled(by: scale)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(ghost.color, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: target.width, height: target.height)
                        .offset(x: target.minX, y: target.minY)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(ghost.color.opacity(0.16))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ghost.color, lineWidth: 1.5))
                        .frame(width: ghost.floating.width, height: ghost.floating.height)
                        .offset(x: ghost.floating.minX, y: ghost.floating.minY)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 1))
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func placementOverlay(_ placement: WidgetPlacement, scale: CGFloat) -> some View {
        let rect = DashboardPageView
            .cellRect(for: placement.frame, in: Self.reference, grid: Self.grid)
            .scaled(by: scale)
        let isSelected = placement.id == selectedPlacementID
        return RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Color.accentColor.opacity(isSelected ? 0.9 : 0), lineWidth: 1.5)
            .contentShape(Rectangle())
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .onTapGesture { selectedPlacementID = placement.id }
            .gesture(dragGesture(placement, scale: scale))
    }

    private func dragGesture(_ placement: WidgetPlacement, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragID != placement.id {
                    dragID = placement.id
                    selectedPlacementID = placement.id // grabbing selects too
                }
                dragTranslation = value.translation
            }
            .onEnded { value in
                defer {
                    dragID = nil
                    dragTranslation = .zero
                }
                guard let candidate = candidateFrame(for: placement, translation: value.translation, scale: scale),
                      candidate != placement.frame // same slot: silent no-op
                else { return }
                if LayoutEngine.validate(candidate, among: siblings(of: placement), in: Self.grid) {
                    commitMove(placement.id, candidate)
                } else {
                    NSSound.beep() // ghost vanishes; the widget never moved
                }
            }
    }

    /// Snapped drop frame for a drag: translation is in miniature space, so
    /// divide by scale exactly once, here.
    private func candidateFrame(for placement: WidgetPlacement, translation: CGSize, scale: CGFloat) -> GridRect? {
        guard scale > 0 else { return nil }
        let refRect = DashboardPageView.cellRect(for: placement.frame, in: Self.reference, grid: Self.grid)
        let proposed = CGPoint(
            x: refRect.minX + translation.width / scale,
            y: refRect.minY + translation.height / scale
        )
        let origin = DashboardPageView.gridOrigin(
            at: proposed, size: placement.frame.size, in: Self.reference, grid: Self.grid
        )
        var frame = placement.frame
        frame.col = origin.col
        frame.row = origin.row
        return frame
    }

    private func siblings(of placement: WidgetPlacement) -> [GridRect] {
        page.placements.filter { $0.id != placement.id }.map(\.frame)
    }

    private func ghostGeometry(scale: CGFloat) -> (candidate: GridRect, color: Color, floating: CGRect)? {
        guard let dragID,
              let placement = page.placements.first(where: { $0.id == dragID }),
              let candidate = candidateFrame(for: placement, translation: dragTranslation, scale: scale)
        else { return nil }
        let valid = LayoutEngine.validate(candidate, among: siblings(of: placement), in: Self.grid)
        let refRect = DashboardPageView.cellRect(for: placement.frame, in: Self.reference, grid: Self.grid)
        let floating = refRect
            .offsetBy(dx: dragTranslation.width / scale, dy: dragTranslation.height / scale)
            .scaled(by: scale)
        return (candidate, valid ? .green : .red, floating)
    }
}

private extension CGRect {
    func scaled(by scale: CGFloat) -> CGRect {
        CGRect(x: minX * scale, y: minY * scale, width: width * scale, height: height * scale)
    }
}

/// Position/size steppers constrained to valid, non-overlapping layouts.
private struct PlacementGeometryEditor: View {
    let placement: WidgetPlacement
    let definition: AnyWidgetDefinition
    let siblings: [GridRect]
    let onChange: (GridRect) -> Void

    private let grid = GridDimensions.landscape

    var body: some View {
        Grid(alignment: .leading, verticalSpacing: 6) {
            GridRow {
                Text("Position").foregroundStyle(.secondary).gridColumnAlignment(.leading)
                stepper("Col", value: placement.frame.col, range: 0...(grid.cols - placement.frame.size.cols)) {
                    var frame = placement.frame; frame.col = $0; apply(frame)
                }
                stepper("Row", value: placement.frame.row, range: 0...(grid.rows - placement.frame.size.rows)) {
                    var frame = placement.frame; frame.row = $0; apply(frame)
                }
            }
            GridRow {
                Text("Size").foregroundStyle(.secondary)
                sizePicker
            }
        }
        .font(.callout)
    }

    private var sizePicker: some View {
        Picker("", selection: Binding(
            get: { placement.frame.size },
            set: { newSize in
                var frame = placement.frame
                frame.size = newSize
                frame.col = min(frame.col, max(0, grid.cols - newSize.cols))
                frame.row = min(frame.row, max(0, grid.rows - newSize.rows))
                apply(frame)
            }
        )) {
            ForEach(definition.supportedSizes, id: \.self) { size in
                Text("\(size.cols)×\(size.rows)").tag(size)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .gridCellColumns(2)
    }

    private func stepper(_ label: String, value: Int, range: ClosedRange<Int>, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.tertiary).font(.caption)
            Stepper("\(value)", value: Binding(get: { value }, set: set), in: range)
                .fixedSize()
        }
    }

    private func apply(_ frame: GridRect) {
        if LayoutEngine.validate(frame, among: siblings, in: grid) {
            onChange(frame)
        } else {
            NSSound.beep()
        }
    }
}
