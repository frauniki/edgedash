import Foundation

public enum PlayerState: String, Sendable, Equatable {
    case playing
    case paused
    case stopped
}

public enum RepeatMode: String, Sendable, Equatable, CaseIterable {
    case off
    case one
    case all
}

/// One full snapshot of the Music app's playback state — everything a single
/// transport round-trip returns.
public struct NowPlayingState: Sendable, Equatable {
    public var playerState: PlayerState
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds; 0 for streams with unknown length.
    public var duration: Double
    /// Seconds into the track.
    public var position: Double
    /// Music.app volume 0…1.
    public var volume: Double
    public var shuffle: Bool
    public var repeatMode: RepeatMode
    /// Stable per-track key for artwork caching; nil for radio streams.
    public var persistentID: String?

    public init(
        playerState: PlayerState = .stopped,
        title: String = "",
        artist: String = "",
        album: String = "",
        duration: Double = 0,
        position: Double = 0,
        volume: Double = 1,
        shuffle: Bool = false,
        repeatMode: RepeatMode = .off,
        persistentID: String? = nil
    ) {
        self.playerState = playerState
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.position = position
        self.volume = volume
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.persistentID = persistentID
    }

    public var progress: Double {
        duration > 0 ? min(max(position / duration, 0), 1) : 0
    }
}

public enum TransportError: Error, Sendable, Equatable {
    /// Automation consent missing or revoked (errAEEventNotPermitted).
    case notPermitted
    case appleEventFailed(Int)
}

public enum MusicCommand: Sendable, Equatable {
    case playPause
    case nextTrack
    case previousTrack
    case seek(to: Double)
    case setVolume(Double)   // 0…1
    case setShuffle(Bool)
    case setRepeat(RepeatMode)
}

/// Player backend. The real implementation talks AppleEvents to Music.app on
/// a private serial queue; tests use a fake. Also the seam for other sources
/// (Spotify, …) later.
public protocol MusicTransport: Sendable {
    /// Whether the player app is running — checked without launching it.
    func isRunning() async -> Bool
    func fetchNowPlaying() async throws -> NowPlayingState
    func fetchArtworkData(persistentID: String?) async -> Data?
    func send(_ command: MusicCommand) async throws
}
