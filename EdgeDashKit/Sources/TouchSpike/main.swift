// M0.5 spike: prove that all HID interfaces of the XENEON EDGE touch
// controller (VID 0x27C0 / PID 0x0859 — digitizer + boot mouse + vendor) can
// be seized by a non-root process holding only Input Monitoring, and that the
// system cursor stays still while raw digitizer reports arrive.
//
// Run:  swift run --package-path EdgeDashKit touch-spike
// Then touch the EDGE panel. PASS criteria are printed at exit (Ctrl+C).

import CoreGraphics
import Foundation
import IOKit.hid

let kVendorID = 0x27C0
let kProductID = 0x0859

// MARK: - State (globals: C callbacks cannot capture context)

// Single-threaded run-loop CLI: all callbacks fire on the main run loop, so
// unsynchronized globals are safe despite what strict concurrency can prove.
nonisolated(unsafe) var seizedCount = 0
nonisolated(unsafe) var listenOnlyCount = 0
nonisolated(unsafe) var deviceCount = 0
nonisolated(unsafe) var reportCount = 0
nonisolated(unsafe) var sawDigitizerXY = false
nonisolated(unsafe) var cursorAtStart = CGPoint.zero
nonisolated(unsafe) var maxCursorDrift = 0.0

nonisolated func cursorPosition() -> CGPoint {
    CGEvent(source: nil)?.location ?? .zero
}

nonisolated func sampleCursorDrift() {
    let now = cursorPosition()
    let drift = hypot(now.x - cursorAtStart.x, now.y - cursorAtStart.y)
    maxCursorDrift = max(maxCursorDrift, drift)
}

func describe(_ device: IOHIDDevice) -> String {
    func intProp(_ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? Int) ?? -1
    }
    let page = intProp(kIOHIDPrimaryUsagePageKey)
    let usage = intProp(kIOHIDPrimaryUsageKey)
    let name: String
    switch (page, usage) {
    case (0x0D, 0x04): name = "digitizer/touchscreen"
    case (0x01, 0x02): name = "boot mouse  ← the cursor-mover"
    default: name = String(format: "vendor/other (page 0x%02X usage 0x%02X)", page, usage)
    }
    return name
}

// MARK: - Permission

print("=== EdgeDash touch seize spike (M0.5) ===")
print("euid: \(geteuid()) (must NOT need 0)")

let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
switch access {
case kIOHIDAccessTypeGranted:
    print("Input Monitoring: granted")
case kIOHIDAccessTypeDenied:
    print("Input Monitoring: DENIED — grant it in System Settings → Privacy & Security → Input Monitoring, then rerun")
    exit(1)
default:
    print("Input Monitoring: not determined — requesting…")
    if !IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
        print("Request rejected or pending. Grant Input Monitoring to your terminal app and rerun.")
        exit(1)
    }
    print("Input Monitoring: granted")
}

// MARK: - Seize every interface of the touch controller

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDOptionsType(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(
    manager,
    [kIOHIDVendorIDKey: kVendorID, kIOHIDProductIDKey: kProductID] as CFDictionary
)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let openStatus = IOHIDManagerOpen(manager, IOHIDOptionsType(kIOHIDOptionsTypeSeizeDevice))
print(String(format: "IOHIDManagerOpen(seize): 0x%08X %@", openStatus, openStatus == kIOReturnSuccess ? "(success)" : "(FAILED)"))

guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !deviceSet.isEmpty else {
    print("No devices matched VID 0x27C0 / PID 0x0859 — is the EDGE's USB (touch) cable connected?")
    exit(1)
}

deviceCount = deviceSet.count
print("\nMatched \(deviceCount) HID interface(s):")
for device in deviceSet {
    // Per-interface seize so we can report exactly which interface resists.
    // 0xE00002C5 (kIOReturnExclusiveAccess) usually means another touch
    // driver (e.g. "Touchscreen Gestures") already holds it — quit it first.
    let rc = IOHIDDeviceOpen(device, IOHIDOptionsType(kIOHIDOptionsTypeSeizeDevice))
    let name = describe(device).padding(toLength: 45, withPad: " ", startingAt: 0)
    if rc == kIOReturnSuccess {
        seizedCount += 1
        print("  - \(name) seize: OK")
    } else {
        // Fall back to shared listen so digitizer reports still stream and
        // the conflict/permission situation stays observable.
        let listenRC = IOHIDDeviceOpen(device, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        if listenRC == kIOReturnSuccess { listenOnlyCount += 1 }
        print("  - \(name) seize: \(String(format: "0x%08X", rc)) FAILED, shared listen: \(listenRC == kIOReturnSuccess ? "OK" : String(format: "0x%08X", listenRC))")
    }
}

// MARK: - Stream digitizer values

IOHIDManagerRegisterInputValueCallback(manager, { _, _, _, value in
    let element = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let intValue = IOHIDValueGetIntegerValue(value)
    reportCount += 1

    // Generic Desktop X/Y inside the digitizer report, and tip switch.
    switch (page, usage) {
    case (0x01, 0x30):
        sawDigitizerXY = true
        print("  touch X=\(intValue)  (cursor drift so far: \(String(format: "%.1f", maxCursorDrift))px)")
    case (0x01, 0x31):
        sawDigitizerXY = true
        print("  touch Y=\(intValue)")
    case (0x0D, 0x42):
        print("  tip \(intValue == 1 ? "DOWN" : "UP")")
    default:
        break // contact count / IDs / vendor pages — irrelevant to the spike
    }
}, nil)

cursorAtStart = cursorPosition()

// Cursor drift is sampled on a timer, independent of HID callbacks — the
// boot-mouse interface moves the cursor whether or not we see its reports.
let driftTimer = CFRunLoopTimerCreateWithHandler(
    kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 0.1, 0.1, 0, 0
) { _ in sampleCursorDrift() }
CFRunLoopAddTimer(CFRunLoopGetCurrent(), driftTimer, .defaultMode)

print("""

Cursor parked at \(cursorAtStart). Touch and drag on the EDGE panel now.
PASS = all interfaces seized AND X/Y values stream AND cursor never drifts.
(Don't move the mouse yourself during the test.) Ctrl+C to finish.

""")

signal(SIGINT) { _ in
    print("\n=== Result ===")
    print("interfaces matched: \(deviceCount), seized: \(seizedCount), listen-only: \(listenOnlyCount)")
    print("input reports: \(reportCount), digitizer X/Y seen: \(sawDigitizerXY)")
    print(String(format: "max cursor drift: %.1fpx", maxCursorDrift))
    let pass = seizedCount == deviceCount && sawDigitizerXY && maxCursorDrift < 2.0
    if pass {
        print("PASS — TouchRouter architecture is viable with Input Monitoring only.")
    } else if seizedCount < deviceCount {
        print("FAIL (seize) — another process may hold the device (Touchscreen Gestures? iCUE?). Quit it and rerun; if it still fails, seize may need root → architecture rework.")
    } else {
        print("FAIL — see which criterion above broke; architecture needs rework.")
    }
    exit(pass ? 0 : 2)
}

CFRunLoopRun()
