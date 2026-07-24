// Device support is profile-driven, not hardcoded to the XENEON EDGE:
// a profile pairs a display identity with its touch controller. Known
// devices auto-detect; anything else works via manual display selection
// (and, later, generic HID digitizer discovery for touch).

public struct DisplayIdentity: Hashable, Sendable, Codable {
    public let vendor: UInt32
    public let model: UInt32

    public init(vendor: UInt32, model: UInt32) {
        self.vendor = vendor
        self.model = model
    }
}

public struct PixelSize: Hashable, Sendable, Codable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// USB identity of a touch controller. Axis ranges are NOT part of the
/// profile — they are read from the HID elements' logical min/max at runtime,
/// so any HID-compliant digitizer maps correctly.
public struct TouchDeviceMatch: Hashable, Sendable, Codable {
    public let vendorID: Int
    public let productID: Int

    public init(vendorID: Int, productID: Int) {
        self.vendorID = vendorID
        self.productID = productID
    }
}

public struct DeviceProfile: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let identities: [DisplayIdentity]
    /// Native panel sizes that identify this device when vendor/model is
    /// unknown (e.g. a hardware revision). Orientation-insensitive.
    public let nativePixelSizes: [PixelSize]
    public let touch: TouchDeviceMatch?

    public init(
        id: String,
        name: String,
        identities: [DisplayIdentity],
        nativePixelSizes: [PixelSize],
        touch: TouchDeviceMatch?
    ) {
        self.id = id
        self.name = name
        self.identities = identities
        self.nativePixelSizes = nativePixelSizes
        self.touch = touch
    }

    public func matchesDisplay(
        vendor: UInt32,
        model: UInt32,
        modePixelSizes: [PixelSize]
    ) -> Bool {
        if identities.contains(DisplayIdentity(vendor: vendor, model: model)) {
            return true
        }
        return nativePixelSizes.contains { native in
            modePixelSizes.contains {
                ($0.width == native.width && $0.height == native.height)
                    || ($0.width == native.height && $0.height == native.width)
            }
        }
    }
}

public enum DeviceCatalog {
    /// Verified on real hardware (2026-07).
    public static let xeneonEdge = DeviceProfile(
        id: "corsair.xeneon-edge",
        name: "CORSAIR XENEON EDGE",
        identities: [DisplayIdentity(vendor: 0x0E58, model: 0xED00)],
        nativePixelSizes: [PixelSize(width: 2560, height: 720)],
        touch: TouchDeviceMatch(vendorID: 0x27C0, productID: 0x0859)
    )

    /// New similar devices (other touch strips / companion displays) are one
    /// profile entry here — no code changes elsewhere.
    public static let known: [DeviceProfile] = [xeneonEdge]

    public static func match(
        vendor: UInt32,
        model: UInt32,
        modePixelSizes: [PixelSize]
    ) -> DeviceProfile? {
        known.first {
            $0.matchesDisplay(vendor: vendor, model: model, modePixelSizes: modePixelSizes)
        }
    }
}
