import AppKit
import CoreServices
import Foundation
import ScriptingBridge

/// Minimal slice of Music.app's scripting interface (verified present in its
/// sdef on macOS 26.5). Selector names must match the sdef's cocoa keys.
@objc private protocol MusicApplicationSB {
    @objc optional var playerState: UInt32 { get }
    @objc optional var playerPosition: Double { get }
    @objc optional var soundVolume: Int { get }
    @objc optional var shuffleEnabled: Bool { get }
    @objc optional var songRepeat: UInt32 { get }
    @objc optional var currentTrack: MusicTrackSB { get }
    @objc optional func playpause()
    @objc optional func nextTrack()
    @objc optional func previousTrack()
    @objc optional func backTrack()
    @objc optional func setPlayerPosition(_ position: Double)
    @objc optional func setSoundVolume(_ volume: Int)
    @objc optional func setShuffleEnabled(_ enabled: Bool)
    @objc optional func setSongRepeat(_ mode: UInt32)
}

@objc private protocol MusicTrackSB {
    @objc optional var name: String { get }
    @objc optional var artist: String { get }
    @objc optional var album: String { get }
    @objc optional var duration: Double { get }
    @objc optional var persistentID: String { get }
    @objc optional func artworks() -> SBElementArray
}

/// Artwork payload types are messy: sdef says `data` is a "picture" (NSImage)
/// and `raw data`'s value-type is commented out — SB may hand back NSImage,
/// NSData, or NSAppleEventDescriptor. Declaring Swift `Data` here made the
/// bridge throw doesNotRecognizeSelector (crash), so take `Any` and convert.
@objc private protocol MusicArtworkSB {
    @objc optional var rawData: Any { get }
    @objc optional var data: Any { get }
}

extension SBApplication: MusicApplicationSB {}
extension SBObject: MusicTrackSB, MusicArtworkSB {}

/// Music.app four-char codes.
private enum FourCC {
    static let statePlaying: UInt32 = 0x6B50_5350 // 'kPSP'
    static let statePaused: UInt32 = 0x6B50_5370 // 'kPSp'
    static let repeatOff: UInt32 = 0x6B52_704F // 'kRpO'
    static let repeatOne: UInt32 = 0x6B52_7031 // 'kRp1'
    static let repeatAll: UInt32 = 0x6B52_7041 // 'kRpA'
}

/// AppleEvents transport to Music.app. Every ScriptingBridge round-trip runs
/// on a private serial queue — a busy Music.app blocks the call, and that
/// must never block the main thread. SB objects are neither Sendable nor
/// thread-safe, so they live and die on that queue only.
public final class AppleMusicTransport: MusicTransport, @unchecked Sendable {
    private static let bundleID = "com.apple.Music"
    private let queue = DispatchQueue(label: "jp.sinoa.edgedash.music-transport", qos: .userInitiated)
    private var app: SBApplication? // queue-confined

    public init() {}

    public func isRunning() async -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    public func fetchNowPlaying() async throws -> NowPlayingState {
        try await onQueue {
            try self.checkAutomationConsent(askIfNeeded: true)
            guard let music = self.application() else { throw TransportError.appleEventFailed(-600) }

            let stateCode = music.playerState ?? 0
            let playerState: PlayerState = switch stateCode {
            case FourCC.statePlaying: .playing
            case FourCC.statePaused: .paused
            default: .stopped
            }
            let repeatMode: RepeatMode = switch music.songRepeat ?? FourCC.repeatOff {
            case FourCC.repeatOne: .one
            case FourCC.repeatAll: .all
            default: .off
            }
            let track = music.currentTrack
            let persistentID = track?.persistentID
            return NowPlayingState(
                playerState: playerState,
                title: track?.name ?? "",
                artist: track?.artist ?? "",
                album: track?.album ?? "",
                duration: track?.duration ?? 0,
                position: music.playerPosition ?? 0,
                volume: Double(music.soundVolume ?? 100) / 100,
                shuffle: music.shuffleEnabled ?? false,
                repeatMode: repeatMode,
                persistentID: (persistentID?.isEmpty ?? true) ? nil : persistentID
            )
        }
    }

    public func fetchArtworkData(persistentID: String?) async -> Data? {
        try? await onQueue {
            guard let music = self.application(),
                  let artworks = music.currentTrack?.artworks?(),
                  let first = artworks.firstObject as? SBObject else { return nil }
            // Verify the track didn't change while this fetch was queued.
            if let persistentID, music.currentTrack?.persistentID != persistentID { return nil }
            let artwork = first as MusicArtworkSB
            return Self.imageData(from: artwork.rawData) ?? Self.imageData(from: artwork.data)
        }
    }

    private static func imageData(from value: Any?) -> Data? {
        switch value {
        case let data as Data:
            data
        case let image as NSImage:
            image.tiffRepresentation
        case let descriptor as NSAppleEventDescriptor:
            descriptor.data.isEmpty ? nil : descriptor.data
        default:
            nil
        }
    }

    public func send(_ command: MusicCommand) async throws {
        try await onQueue {
            try self.checkAutomationConsent(askIfNeeded: true)
            guard let music = self.application() else { throw TransportError.appleEventFailed(-600) }
            switch command {
            case .playPause: music.playpause?()
            case .nextTrack: music.nextTrack?()
            case .previousTrack: music.backTrack?() // restarts, double-tap skips — Music.app semantics
            case .seek(let seconds): music.setPlayerPosition?(seconds)
            case .setVolume(let volume): music.setSoundVolume?(Int((volume * 100).rounded()))
            case .setShuffle(let enabled): music.setShuffleEnabled?(enabled)
            case .setRepeat(let mode):
                let code: UInt32 = switch mode {
                case .off: FourCC.repeatOff
                case .one: FourCC.repeatOne
                case .all: FourCC.repeatAll
                }
                music.setSongRepeat?(code)
            }
        }
    }

    // MARK: - Queue plumbing

    private func onQueue<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// @objc optional members dispatch through the protocol existential, not
    /// the SBApplication class type — hence the return type.
    private func application() -> MusicApplicationSB? {
        if app == nil {
            app = SBApplication(bundleIdentifier: Self.bundleID)
        }
        return app
    }

    /// Distinguishes "denied" from transient failures BEFORE ScriptingBridge
    /// swallows the error. First call with askIfNeeded triggers the TCC
    /// consent prompt (blocking this queue, never the UI).
    private func checkAutomationConsent(askIfNeeded: Bool) throws {
        var target = AEAddressDesc()
        let bundleData = Data(Self.bundleID.utf8)
        let creation = bundleData.withUnsafeBytes { bytes in
            AECreateDesc(typeApplicationBundleID, bytes.baseAddress, bytes.count, &target)
        }
        guard creation == noErr else { throw TransportError.appleEventFailed(Int(creation)) }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, askIfNeeded)
        switch status {
        case noErr:
            return
        case OSStatus(errAEEventNotPermitted):
            throw TransportError.notPermitted
        case OSStatus(procNotFound):
            throw TransportError.appleEventFailed(Int(procNotFound))
        default:
            throw TransportError.appleEventFailed(Int(status))
        }
    }
}
