import EdgeCore
import Testing

@Suite struct DeviceCatalogTests {
    // Real values captured from hardware on 2026-07-23.
    let edgeModes = [
        PixelSize(width: 2560, height: 720), PixelSize(width: 1920, height: 1080),
        PixelSize(width: 1280, height: 720), PixelSize(width: 640, height: 480),
    ]
    let dellModes = [
        PixelSize(width: 5120, height: 2160), PixelSize(width: 2560, height: 1440),
        PixelSize(width: 1920, height: 1080),
    ]

    @Test func edgeMatchesByIdentity() {
        let profile = DeviceCatalog.match(vendor: 0x0E58, model: 0xED00, modePixelSizes: [])
        #expect(profile?.id == "corsair.xeneon-edge")
    }

    @Test func unknownRevisionMatchesByNativeMode() {
        // Future hardware revision: unknown vendor/model, same panel.
        let profile = DeviceCatalog.match(vendor: 0xFFFF, model: 0x0001, modePixelSizes: edgeModes)
        #expect(profile?.id == "corsair.xeneon-edge")
    }

    @Test func rotatedNativeModeStillMatches() {
        let rotated = [PixelSize(width: 720, height: 2560)]
        let profile = DeviceCatalog.match(vendor: 0xFFFF, model: 0x0001, modePixelSizes: rotated)
        #expect(profile?.id == "corsair.xeneon-edge")
    }

    @Test func ordinaryMonitorDoesNotMatch() {
        let profile = DeviceCatalog.match(vendor: 0x10AC, model: 0x4308, modePixelSizes: dellModes)
        #expect(profile == nil)
    }

    @Test func edgeProfileCarriesTouchPairing() {
        #expect(DeviceCatalog.xeneonEdge.touch == TouchDeviceMatch(vendorID: 0x27C0, productID: 0x0859))
    }
}
