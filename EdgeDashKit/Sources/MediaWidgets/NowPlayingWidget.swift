import EdgeCore
import EdgeTouch
import SwiftUI
import WidgetEngine

public struct NowPlayingWidget: WidgetDefinition {
    public struct Config: Codable, Sendable, DefaultInitializable {
        public var showArtwork = true
        public var showAlbum = true
        public var showSeekBar = true
        public var showVolume = true
        public var showShuffleRepeat = true
        public init() {}
    }

    public static let typeID = WidgetTypeID("edgedash.nowplaying")
    public static var displayName: String {
        loc("Now Playing")
    }

    public static let category = WidgetCategory.media
    public static let supportedSizes = [
        GridSize(cols: 1, rows: 1), GridSize(cols: 2, rows: 1),
        GridSize(cols: 2, rows: 2), GridSize(cols: 4, rows: 2),
    ]

    public static func requiredMetrics(for config: Config) -> Set<MetricID> {
        []
    }

    @MainActor public static func makeView(config: Config, context: WidgetContext) -> AnyView {
        guard let player = context.services.resolve(MusicPlayerController.self) else {
            return AnyView(ServiceMissingView())
        }
        return AnyView(NowPlayingView(config: config, player: player, size: context.size))
    }

    @MainActor public static func makeConfigView(config: Binding<Config>, context: WidgetContext) -> AnyView {
        AnyView(NowPlayingConfigView(config: config))
    }
}

// MARK: - View

private struct NowPlayingView: View {
    @Environment(\.theme) private var theme
    let config: NowPlayingWidget.Config
    let player: MusicPlayerController
    let size: GridSize

    private var now: NowPlayingState? {
        player.now
    }

    private var isPlaying: Bool {
        now?.playerState == .playing
    }

    private var dimmed: Bool {
        now?.playerState != .playing
    }

    var body: some View {
        Group {
            switch player.availability {
            case .musicNotRunning:
                statusView(
                    icon: "music.note",
                    message: "Music is not running",
                    buttonTitle: "Open Music",
                    action: { player.openMusicApp() }
                )
            case .permissionDenied:
                statusView(
                    icon: "lock.shield",
                    message: "Automation permission needed",
                    buttonTitle: "System Settings…",
                    action: openAutomationSettings
                )
            case .ready:
                if let now, !now.title.isEmpty || now.playerState != .stopped {
                    playerBody(now)
                } else {
                    statusView(icon: "music.note", message: "Nothing playing", buttonTitle: nil, action: nil)
                }
            }
        }
        .padding(size.cols == 1 ? 10 : 14)
    }

    @ViewBuilder private func playerBody(_ now: NowPlayingState) -> some View {
        if size.rows >= 2, size.cols >= 4 {
            wideLayout(now)
        } else if size.rows >= 2 {
            fullLayout(now)
        } else if size.cols >= 2 {
            compactLayout(now)
        } else {
            miniLayout(now)
        }
    }

    /// 2×2: artwork on top, info + all controls stacked beneath.
    private func fullLayout(_ now: NowPlayingState) -> some View {
        VStack(spacing: 10) {
            header
            if config.showArtwork {
                artwork.frame(maxHeight: .infinity)
            }
            trackInfo(now, titleSize: 16, center: true)
            if config.showSeekBar { seekBar(now) }
            transportRow(now, iconSize: 22)
            if config.showVolume { volumeRow(now) }
        }
    }

    /// 4×2: artwork fills the left, everything else in a right column.
    private func wideLayout(_ now: NowPlayingState) -> some View {
        HStack(spacing: 18) {
            if config.showArtwork {
                artwork.aspectRatio(1, contentMode: .fit)
            }
            VStack(alignment: .leading, spacing: 12) {
                header
                Spacer(minLength: 0)
                trackInfo(now, titleSize: 20, center: false)
                if config.showSeekBar { seekBar(now) }
                transportRow(now, iconSize: 24)
                if config.showVolume { volumeRow(now) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 2×1: artwork left, info/seek/transport right.
    private func compactLayout(_ now: NowPlayingState) -> some View {
        HStack(spacing: 14) {
            if config.showArtwork {
                artwork.aspectRatio(1, contentMode: .fit)
            }
            VStack(alignment: .leading, spacing: 7) {
                trackInfo(now, titleSize: 15, center: false)
                if config.showSeekBar { seekBar(now) }
                transportRow(now, iconSize: 18)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// 1×1: artwork with a play/pause overlay.
    private func miniLayout(_ now: NowPlayingState) -> some View {
        VStack(spacing: 6) {
            ZStack {
                artwork
                TouchButton(action: { player.playPause() }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.7), radius: 5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Text(now.title.isEmpty ? "—" : now.title)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("MUSIC")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textSecondary.color)
                .kerning(1.5)
            Spacer()
            if config.showShuffleRepeat { shuffleRepeatButtons }
        }
    }

    private var shuffleRepeatButtons: some View {
        HStack(spacing: 14) {
            TouchButton(action: { player.toggleShuffle() }) {
                Image(systemName: "shuffle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle((now?.shuffle ?? false) ? theme.accent.color : theme.textSecondary.color)
                    .frame(width: 26, height: 22)
            }
            TouchButton(action: { player.cycleRepeatMode() }) {
                Image(systemName: (now?.repeatMode == .one) ? "repeat.1" : "repeat")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle((now?.repeatMode ?? .off) != .off ? theme.accent.color : theme.textSecondary.color)
                    .frame(width: 26, height: 22)
            }
        }
    }

    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: theme.cornerRadius * 0.6, style: .continuous)
        return Group {
            if let image = player.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                shape
                    .fill(theme.track.color)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 26))
                            .foregroundStyle(theme.textSecondary.color)
                    }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(shape)
        .opacity(dimmed ? 0.65 : 1)
    }

    private func trackInfo(_ now: NowPlayingState, titleSize: CGFloat, center: Bool) -> some View {
        VStack(alignment: center ? .center : .leading, spacing: 2) {
            Text(now.title.isEmpty ? "—" : now.title)
                .font(.system(size: titleSize, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary.color)
                .lineLimit(1)
            Text(subtitle(now))
                .font(.system(size: titleSize - 4, design: .rounded))
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: center ? .center : .leading)
        .opacity(dimmed ? 0.75 : 1)
    }

    private func subtitle(_ now: NowPlayingState) -> String {
        var parts = [now.artist]
        if config.showAlbum, !now.album.isEmpty { parts.append(now.album) }
        let text = parts.filter { !$0.isEmpty }.joined(separator: " — ")
        return text.isEmpty ? " " : text
    }

    private func seekBar(_ now: NowPlayingState) -> some View {
        VStack(spacing: 3) {
            TouchSlider(
                fraction: now.progress,
                color: theme.accent.color,
                enabled: now.duration > 0,
                onCommit: { fraction in player.seek(to: fraction * now.duration) }
            )
            HStack {
                Text(Self.timeText(now.position))
                Spacer()
                Text(now.duration > 0 ? "-" + Self.timeText(max(0, now.duration - now.position)) : "")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(theme.textSecondary.color)
        }
    }

    private func transportRow(_ now: NowPlayingState, iconSize: CGFloat) -> some View {
        HStack(spacing: 0) {
            transportButton("backward.fill", size: iconSize - 4) { player.previousTrack() }
            transportButton(isPlaying ? "pause.fill" : "play.fill", size: iconSize) { player.playPause() }
            transportButton("forward.fill", size: iconSize - 4) { player.nextTrack() }
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(_ symbol: String, size: CGFloat, action: @escaping @MainActor () -> Void) -> some View {
        TouchButton(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(theme.textPrimary.color)
                .frame(maxWidth: .infinity, minHeight: size + 16)
        }
    }

    private func volumeRow(_ now: NowPlayingState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary.color)
            TouchSlider(
                fraction: now.volume,
                color: theme.accentAlt.color,
                enabled: true,
                onCommit: { player.setVolume($0) },
                onDrag: { player.setVolume($0) },
                dragThrottle: .milliseconds(100)
            )
        }
    }

    private func statusView(
        icon: String,
        message: String,
        buttonTitle: String?,
        action: (@MainActor () -> Void)?
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: size.rows >= 2 ? 30 : 20))
                .foregroundStyle(theme.textSecondary.color)
            Text(message)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.textSecondary.color)
                .multilineTextAlignment(.center)
            if let buttonTitle, let action {
                TouchButton(action: { action(); retrySoon() }) {
                    Text(buttonTitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.accent.color)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(theme.track.color))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Poll a few times after "Open Music" / settings round-trips so the
    /// widget recovers without waiting for the next external poke.
    private func retrySoon() {
        Task { @MainActor in
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(2))
                player.retry()
            }
        }
    }

    static func timeText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Placeholder when no MusicPlayerController service is registered.
private struct ServiceMissingView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text("Music service unavailable")
            .font(.system(size: 12, design: .rounded))
            .foregroundStyle(theme.textSecondary.color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Slider

/// Horizontal slider driven by panel touches (tap to jump, pan to scrub) and
/// mouse drags (windowed preview). Reports in 0…1 fractions.
struct TouchSlider: View {
    @Environment(\.theme) private var theme
    let fraction: Double
    let color: Color
    var enabled = true
    let onCommit: @MainActor (Double) -> Void
    var onDrag: (@MainActor (Double) -> Void)?
    /// Minimum interval between onDrag calls (AppleEvents are not free).
    var dragThrottle: Duration = .zero

    @State private var dragFraction: Double?
    @State private var globalFrame: CGRect = .zero
    @State private var lastDragSent = ContinuousClock.now - .seconds(1)

    private var shown: Double {
        dragFraction ?? fraction
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track.color).frame(height: 5)
                Capsule()
                    .fill(LinearGradient(
                        colors: [color.opacity(0.65), color],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: max(5, width * shown), height: 5)
                Circle()
                    .fill(Color.white)
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: max(0, width * shown - 5.5))
                    .opacity(enabled ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 22)
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.4)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { globalFrame = $0 }
        .touchTarget(accepts: [.tap, .pan], zIndex: 250) { event in
            guard enabled else { return }
            switch event {
            case .tap(let location):
                onCommit(map(location))
            case .panBegan(let location):
                dragFraction = map(location)
            case .panChanged(let location, _, _):
                dragFraction = map(location)
                sendDrag()
            case .panEnded:
                if let dragFraction { onCommit(dragFraction) }
                dragFraction = nil
            case .cancelled:
                dragFraction = nil
            default:
                break
            }
        }
        .gesture( // mouse path for the windowed preview
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard enabled else { return }
                    dragFraction = clamp(value.location.x / max(globalFrame.width, 1))
                    sendDrag()
                }
                .onEnded { _ in
                    if let dragFraction { onCommit(dragFraction) }
                    dragFraction = nil
                }
        )
    }

    /// Window-space touch location → 0…1 along the slider.
    private func map(_ location: CGPoint) -> Double {
        clamp((location.x - globalFrame.minX) / max(globalFrame.width, 1))
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func sendDrag() {
        guard let onDrag, let dragFraction else { return }
        let now = ContinuousClock.now
        guard now - lastDragSent >= dragThrottle else { return }
        lastDragSent = now
        onDrag(dragFraction)
    }
}

// MARK: - Config

private struct NowPlayingConfigView: View {
    @Binding var config: NowPlayingWidget.Config

    var body: some View {
        ConfigForm {
            Toggle(loc("Artwork"), isOn: $config.showArtwork)
            Toggle(loc("Album name"), isOn: $config.showAlbum)
            Toggle(loc("Seek bar"), isOn: $config.showSeekBar)
            Toggle(loc("Volume slider"), isOn: $config.showVolume)
            Toggle(loc("Shuffle & repeat buttons"), isOn: $config.showShuffleRepeat)
            Text("Volume controls the Music app's own volume, not the system output volume.", bundle: Bundle.module)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
