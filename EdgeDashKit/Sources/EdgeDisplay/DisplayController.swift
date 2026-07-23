import AppKit
import EdgeCore
import Observation

/// Watches display topology and resolves which screen the dashboard owns.
/// State machine: searching → attached(id) → lost → attached(id) …
/// Detection is profile-driven (DeviceCatalog): known companion displays
/// auto-detect; any other display works via explicit UUID selection.
@MainActor @Observable public final class DisplayController {
    public private(set) var attachment: DisplayAttachment = .searching
    public private(set) var rotation: DisplayRotation = .none
    public private(set) var screen: NSScreen?
    /// Which known device matched, if any — pairs the display with its touch
    /// controller. Nil for manually selected generic displays.
    public private(set) var profile: DeviceProfile?

    /// Auto-detect by default; Settings can pin explicit display UUIDs.
    public var selection: DisplaySelection = .autoDetect {
        didSet { rescan() }
    }

    /// Fires after every state transition; the app layer syncs the window.
    public var onStateChange: (@MainActor () -> Void)?

    private var observer: (any NSObjectProtocol)?

    public init() {}

    public func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        rescan()
    }

    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    public func rescan() {
        let previous = attachment

        guard let target = resolveTargetDisplay() else {
            screen = nil
            rotation = .none
            profile = nil
            attachment = (previous == .searching) ? .searching : .lost
            if previous != attachment { onStateChange?() }
            return
        }

        screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == target.id
        }
        rotation = DisplayRotation(degrees: CGDisplayRotation(target.id))
        profile = target.profile
        attachment = .attached(displayID: target.id)

        // Re-notify even when the same display stays attached: its frame,
        // resolution, or rotation may have changed and the window must re-assert.
        onStateChange?()
    }

    private func resolveTargetDisplay() -> (id: CGDirectDisplayID, profile: DeviceProfile?)? {
        let online = Self.onlineDisplays()
        switch selection {
        case .autoDetect:
            for displayID in online {
                if let matched = Self.matchProfile(displayID) {
                    return (displayID, matched)
                }
            }
            return nil
        case .byUUIDs(let uuids):
            guard let displayID = online.first(where: { uuids.contains(Self.uuidString(for: $0) ?? "") }) else {
                return nil
            }
            return (displayID, Self.matchProfile(displayID))
        }
    }

    // MARK: - CoreGraphics queries

    public static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    public static func matchProfile(_ displayID: CGDirectDisplayID) -> DeviceProfile? {
        DeviceCatalog.match(
            vendor: CGDisplayVendorNumber(displayID),
            model: CGDisplayModelNumber(displayID),
            modePixelSizes: modePixelSizes(for: displayID)
        )
    }

    public static func modePixelSizes(for displayID: CGDirectDisplayID) -> [PixelSize] {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            return []
        }
        return modes.map { PixelSize(width: $0.pixelWidth, height: $0.pixelHeight) }
    }

    public static func uuidString(for displayID: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
