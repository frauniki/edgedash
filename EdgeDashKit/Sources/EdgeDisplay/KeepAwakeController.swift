import Foundation
import IOKit.pwr_mgt

/// Prevents display sleep while the dashboard is visible and the user opted
/// in. macOS has no per-display sleep: this keeps EVERY display awake, which
/// the settings UI states explicitly.
@MainActor public final class KeepAwakeController {
    private var assertionID: IOPMAssertionID = 0
    private var held = false

    public init() {}

    public func setActive(_ active: Bool) {
        guard active != held else { return }
        if active {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "EdgeDash dashboard is visible" as CFString,
                &assertionID
            )
            held = (result == kIOReturnSuccess)
        } else {
            IOPMAssertionRelease(assertionID)
            held = false
        }
    }
}
