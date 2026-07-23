import AppKit
import Foundation
import Observation

public enum AutomationPermission: Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    /// Target app not running — cannot be determined yet.
    case unknown
}

/// What the widget should render.
public enum PlayerAvailability: Sendable, Equatable {
    case ready
    case musicNotRunning
    case permissionDenied
}

/// Now-playing state machine. The transport (AppleEvents) is the single
/// source of truth: while active and playing we re-fetch every second; the
/// `com.apple.Music.playerInfo` distributed notification is used only as a
/// poke to re-fetch immediately (its payload is never trusted — fields go
/// missing for streams/radio).
@MainActor @Observable public final class MusicPlayerController {
    public private(set) var availability: PlayerAvailability = .musicNotRunning
    public private(set) var now: NowPlayingState?
    public private(set) var artwork: NSImage?

    private let transport: any MusicTransport
    private let pollInterval: Duration
    private var active = false
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var notificationObserver: (any NSObjectProtocol)?
    private var artworkCache: [String: NSImage] = [:]
    private var artworkFetchID: String? // in-flight or cached key
    var isPolling: Bool { pollTask != nil } // test hook

    public init(transport: any MusicTransport, pollInterval: Duration = .seconds(1)) {
        self.transport = transport
        self.pollInterval = pollInterval
    }

    /// Driven by the app layer: true while a page containing a media widget
    /// is on screen (or settings is open). Everything stops when inactive.
    public func setActive(_ newActive: Bool) {
        guard newActive != active else { return }
        active = newActive
        if active {
            subscribeToPlayerInfo()
            refresh() // seed — tracks may have changed while we were away
        } else {
            unsubscribeFromPlayerInfo()
            stopPolling()
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    /// Re-runs the consent flow after the user re-granted in System Settings
    /// (or to trigger the initial prompt from the widget's error state).
    public func retry() {
        refresh()
    }

    // MARK: - Commands

    public func playPause() { send(.playPause) }
    public func nextTrack() { send(.nextTrack) }
    public func previousTrack() { send(.previousTrack) }
    public func seek(to seconds: Double) { send(.seek(to: seconds)) }
    public func setVolume(_ volume: Double) { send(.setVolume(min(max(volume, 0), 1))) }

    public func toggleShuffle() {
        send(.setShuffle(!(now?.shuffle ?? false)))
    }

    public func cycleRepeatMode() {
        let next: RepeatMode = switch now?.repeatMode ?? .off {
        case .off: .all
        case .all: .one
        case .one: .off
        }
        send(.setRepeat(next))
    }

    public func openMusicApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // Chained so rapid taps arrive at Music.app in order (independent Tasks
    // would race on the hop to the transport queue).
    private var commandChain: Task<Void, Never>?

    private func send(_ command: MusicCommand) {
        let previous = commandChain
        commandChain = Task { [transport] in
            await previous?.value
            do {
                try await transport.send(command)
                self.refresh()
            } catch {
                self.handle(error: error)
            }
        }
    }

    // MARK: - Refresh loop

    private func refresh() {
        guard active, refreshTask == nil else { return } // coalesce bursts
        refreshTask = Task { [transport] in
            defer { refreshTask = nil }
            guard await transport.isRunning() else {
                availability = .musicNotRunning
                now = nil
                stopPolling()
                return
            }
            do {
                let state = try await transport.fetchNowPlaying()
                guard !Task.isCancelled else { return }
                availability = .ready
                now = state
                updateArtwork(for: state)
                state.playerState == .playing ? startPolling() : stopPolling()
            } catch {
                handle(error: error)
            }
        }
    }

    private func handle(error: Error) {
        if case TransportError.notPermitted = error {
            availability = .permissionDenied
        } else {
            // Transient AppleEvents failure (Music quitting, timeout): keep
            // the last state; polling stops so we don't hammer a dying app.
            availability = now == nil ? .musicNotRunning : availability
        }
        stopPolling()
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled else { return }
                refresh()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - playerInfo poke

    private func subscribeToPlayerInfo() {
        guard notificationObserver == nil else { return }
        notificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func unsubscribeFromPlayerInfo() {
        if let observer = notificationObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            notificationObserver = nil
        }
    }

    // MARK: - Artwork

    private func updateArtwork(for state: NowPlayingState) {
        guard let id = state.persistentID else {
            artwork = nil // radio/stream: placeholder in the view
            artworkFetchID = nil
            return
        }
        guard id != artworkFetchID else { return }
        artworkFetchID = id
        if let cached = artworkCache[id] {
            artwork = cached
            return
        }
        artwork = nil
        Task { [transport] in
            guard let data = await transport.fetchArtworkData(persistentID: id),
                  let image = NSImage(data: data) else { return }
            guard artworkFetchID == id else { return } // track changed meanwhile
            if artworkCache.count > 8 { artworkCache.removeAll() }
            artworkCache[id] = image
            artwork = image
        }
    }
}
