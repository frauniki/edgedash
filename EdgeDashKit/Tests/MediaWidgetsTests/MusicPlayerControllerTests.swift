import AppKit
import Foundation
@testable import MediaWidgets
import Testing

/// Scriptable in-memory transport: tests drive the state Music.app would
/// report and observe the commands the controller sends.
final class FakeTransport: MusicTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _running = true
    private var _state = NowPlayingState()
    private var _error: TransportError?
    private var _commands: [MusicCommand] = []
    private var _artworkFetches: [String?] = []
    private var _artworkData: Data?
    private var _fetchDelay: Duration?

    var running: Bool {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }

    var state: NowPlayingState {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    var error: TransportError? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    var commands: [MusicCommand] {
        lock.withLock { _commands }
    }

    var artworkFetches: [String?] {
        lock.withLock { _artworkFetches }
    }

    var artworkData: Data? {
        get { lock.withLock { _artworkData } }
        set { lock.withLock { _artworkData = newValue } }
    }

    /// Simulates a slow AppleEvents round-trip: the state is captured when
    /// the fetch starts, so it can return stale data if `state` changes
    /// while the fetch is in flight.
    var fetchDelay: Duration? {
        get { lock.withLock { _fetchDelay } }
        set { lock.withLock { _fetchDelay = newValue } }
    }

    func isRunning() async -> Bool {
        running
    }

    func fetchNowPlaying() async throws -> NowPlayingState {
        if let error { throw error }
        let snapshot = state
        if let fetchDelay { try? await Task.sleep(for: fetchDelay) }
        return snapshot
    }

    func fetchArtworkData(persistentID: String?) async -> Data? {
        lock.withLock { _artworkFetches.append(persistentID) }
        return artworkData
    }

    func send(_ command: MusicCommand) async throws {
        if let error { throw error }
        lock.withLock { _commands.append(command) }
    }
}

/// 1×1 PNG for artwork round-trips.
private func tinyPNG() -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    return rep.representation(using: .png, properties: [:])!
}

/// Spin until `condition` holds (controller work is async Tasks).
@MainActor private func eventually(
    _ comment: Comment? = nil,
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition(), comment)
}

@MainActor struct MusicPlayerControllerTests {
    private func makeController(
        _ transport: FakeTransport
    ) -> MusicPlayerController {
        MusicPlayerController(
            transport: transport,
            pollInterval: .milliseconds(20),
            settleDelay: .milliseconds(50)
        )
    }

    @Test func musicNotRunning() async {
        let transport = FakeTransport()
        transport.running = false
        let controller = makeController(transport)
        controller.setActive(true)
        await eventually { controller.availability == .musicNotRunning }
        #expect(controller.now == nil)
        #expect(!controller.isPolling)
        controller.setActive(false)
    }

    @Test func playingStartsPollingAndPausedStopsIt() async {
        let transport = FakeTransport()
        transport.state = NowPlayingState(playerState: .playing, title: "Song A", artist: "Artist")
        let controller = makeController(transport)
        controller.setActive(true)

        await eventually { controller.availability == .ready && controller.now?.title == "Song A" }
        await eventually { controller.isPolling }

        // Track changes propagate through the poll loop without any poke.
        transport.state = NowPlayingState(playerState: .playing, title: "Song B", artist: "Artist")
        await eventually { controller.now?.title == "Song B" }

        transport.state.playerState = .paused
        await eventually { !controller.isPolling }
        #expect(controller.now?.playerState == .paused)
        controller.setActive(false)
    }

    @Test func permissionDeniedStopsPollingAndRecovers() async {
        let transport = FakeTransport()
        transport.state = NowPlayingState(playerState: .playing, title: "Song")
        let controller = makeController(transport)
        controller.setActive(true)
        await eventually { controller.isPolling }

        transport.error = .notPermitted
        await eventually { controller.availability == .permissionDenied }
        await eventually { !controller.isPolling }

        // User re-grants in System Settings → retry restores everything.
        transport.error = nil
        controller.retry()
        await eventually { controller.availability == .ready }
        await eventually { controller.isPolling }
        controller.setActive(false)
    }

    @Test func inactiveStopsEverything() async {
        let transport = FakeTransport()
        transport.state = NowPlayingState(playerState: .playing, title: "Song")
        let controller = makeController(transport)
        controller.setActive(true)
        await eventually { controller.isPolling }

        controller.setActive(false)
        await eventually { !controller.isPolling }

        // No spontaneous refreshes while inactive.
        transport.state = NowPlayingState(playerState: .playing, title: "Other")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(controller.now?.title == "Song")
    }

    @Test func commandsReachTransport() async {
        let transport = FakeTransport()
        transport.state = NowPlayingState(playerState: .playing, shuffle: false, repeatMode: .off)
        let controller = makeController(transport)
        controller.setActive(true)
        await eventually { controller.now != nil }

        controller.playPause()
        controller.nextTrack()
        controller.toggleShuffle()
        controller.cycleRepeatMode()
        controller.seek(to: 42)
        controller.setVolume(0.5)
        await eventually { transport.commands.count == 6 }
        #expect(transport.commands[0] == .playPause)
        #expect(transport.commands[1] == .nextTrack)
        #expect(transport.commands[2] == .setShuffle(true))
        #expect(transport.commands[3] == .setRepeat(.all))
        #expect(transport.commands[4] == .seek(to: 42))
        #expect(transport.commands[5] == .setVolume(0.5))
        controller.setActive(false)
    }

    @Test func pokeDuringInFlightRefreshIsNotLost() async {
        let transport = FakeTransport()
        transport.state = NowPlayingState(playerState: .paused, title: "Song")
        let controller = makeController(transport)
        controller.setActive(true)
        await eventually { controller.now?.playerState == .paused }

        // A slow fetch holding the old state is mid-flight when the poke
        // (playerInfo notification after play) arrives.
        transport.fetchDelay = .milliseconds(80)
        controller.retry()
        transport.state.playerState = .playing
        controller.retry()
        transport.fetchDelay = nil

        await eventually { controller.now?.playerState == .playing }
        await eventually { controller.isPolling }
        controller.setActive(false)
    }

    @Test func commandSettleRefreshCatchesLaggedStateChange() async {
        let transport = FakeTransport()
        transport.state = NowPlayingState(playerState: .paused, title: "Song")
        let controller = makeController(transport)
        controller.setActive(true)
        await eventually { controller.now?.playerState == .paused }

        // Music flips its reported state only after the command's immediate
        // re-read; the delayed settle refresh must still pick it up.
        controller.playPause()
        await eventually { transport.commands.contains(.playPause) }
        transport.state.playerState = .playing
        await eventually { controller.now?.playerState == .playing }
        await eventually { controller.isPolling }
        controller.setActive(false)
    }

    @Test func transientErrorKeepsPollingAndRecovers() async {
        let transport = FakeTransport()
        transport.state = NowPlayingState(playerState: .playing, title: "Song A")
        let controller = makeController(transport)
        controller.setActive(true)
        await eventually { controller.isPolling }

        // One AppleEvents hiccup: last state stays on screen, polling
        // survives, and the next successful fetch updates the display.
        transport.error = .appleEventFailed(-609)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(controller.isPolling)
        #expect(controller.now?.title == "Song A")

        transport.error = nil
        transport.state = NowPlayingState(playerState: .playing, title: "Song B")
        await eventually { controller.now?.title == "Song B" }
        controller.setActive(false)
    }

    @Test func artworkFetchedOncePerTrack() async {
        let transport = FakeTransport()
        transport.artworkData = tinyPNG()
        transport.state = NowPlayingState(playerState: .playing, title: "Song", persistentID: "AAA")
        let controller = makeController(transport)
        controller.setActive(true)

        await eventually { controller.artwork != nil }
        // Several poll cycles later the artwork was still fetched only once.
        try? await Task.sleep(for: .milliseconds(100))
        #expect(controller.artwork != nil)
        #expect(transport.artworkFetches == ["AAA"])

        // Same track cached; new track fetches again.
        transport.state = NowPlayingState(playerState: .playing, title: "Next", persistentID: "BBB")
        await eventually { transport.artworkFetches == ["AAA", "BBB"] }
        controller.setActive(false)
    }

    @Test func radioWithoutPersistentIDShowsPlaceholder() async {
        let transport = FakeTransport()
        transport.artworkData = tinyPNG()
        transport.state = NowPlayingState(playerState: .playing, title: "Radio", persistentID: nil)
        let controller = makeController(transport)
        controller.setActive(true)
        await eventually { controller.now?.title == "Radio" }
        try? await Task.sleep(for: .milliseconds(60))
        #expect(controller.artwork == nil)
        #expect(transport.artworkFetches.isEmpty)
        controller.setActive(false)
    }
}

struct NowPlayingStateTests {
    @Test func progressClamps() {
        #expect(NowPlayingState(duration: 100, position: 25).progress == 0.25)
        #expect(NowPlayingState(duration: 100, position: 150).progress == 1)
        #expect(NowPlayingState(duration: 0, position: 10).progress == 0)
    }
}
