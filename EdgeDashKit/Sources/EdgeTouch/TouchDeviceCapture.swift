import CoreGraphics
import EdgeCore
import Foundation
import IOKit.hid
import Observation
import os

private let log = Logger(subsystem: "jp.sinoa.edgedash", category: "touch")

/// Captures a touch controller over IOKit HID.
///
/// Matches by VID/PID only and seizes EVERY interface the device exposes —
/// the XENEON EDGE presents digitizer + boot mouse + vendor interfaces, and
/// macOS drives the mouse one natively (moving the cursor) unless it is
/// seized too. Verified on hardware: seize succeeds non-root with only the
/// Input Monitoring permission (M0.5 spike).
///
/// Axis ranges come from the digitizer elements' logical min/max, so any
/// HID-compliant touchscreen normalizes correctly — nothing device-specific
/// beyond the VID/PID match.
@MainActor @Observable public final class TouchDeviceCapture {
    public enum CaptureState: Sendable, Equatable {
        case idle
        case noPermission
        case searching
        /// All interfaces seized — cursor immune, full functionality.
        case seized(interfaces: Int)
        /// Another process holds the device; we can listen but the OS cursor
        /// may still move. Settings surfaces this as a conflict warning.
        case sharedListen(interfaces: Int)
        case deviceNotFound
    }

    public private(set) var state: CaptureState = .idle

    /// Emits normalized panel-space touches on the main actor.
    public var onTouch: (@MainActor (RawTouch) -> Void)?

    private var manager: IOHIDManager?
    private let match: TouchDeviceMatch

    // Values are matched by usage page/usage AT DELIVERY TIME (the approach
    // proven by the M0.5 spike) with normalization ranges read from the
    // firing element itself. The seized boot-mouse interface also emits
    // GD_X/GD_Y (relative deltas), so values are accepted only from the
    // digitizer interface(s).
    private var digitizerDevices: Set<IOHIDDevice> = []

    private var currentX: Double = 0
    private var currentY: Double = 0
    private var tipDown = false

    public init(match: TouchDeviceMatch) {
        self.match = match
    }

    // MARK: - Permission

    public static func permissionGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Triggers the TCC prompt (or returns current status).
    @discardableResult
    public static func requestPermission() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: - Lifecycle

    public func start() {
        guard Self.permissionGranted() else {
            state = .noPermission
            return
        }
        stop()
        state = .searching

        // Order mirrors the hardware-verified M0.5 spike exactly:
        // create → match → register callback → schedule → open(seize) →
        // per-device open(seize).
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDOptionsType(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: match.vendorID,
            kIOHIDProductIDKey: match.productID,
        ] as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let capture = Unmanaged<TouchDeviceCapture>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                capture.handle(value: value)
            }
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let seizeStatus = IOHIDManagerOpen(manager, IOHIDOptionsType(kIOHIDOptionsTypeSeizeDevice))
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            log.error("no devices matched VID 0x\(UInt32(self.match.vendorID), format: .hex) PID 0x\(UInt32(self.match.productID), format: .hex)")
            IOHIDManagerClose(manager, IOHIDOptionsType(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            state = .deviceNotFound
            return
        }

        // Belt-and-suspenders per-device seize, exactly like the spike.
        for device in devices {
            let rc = IOHIDDeviceOpen(device, IOHIDOptionsType(kIOHIDOptionsTypeSeizeDevice))
            log.info("device open(seize) rc=0x\(UInt32(bitPattern: rc), format: .hex)")
        }

        if seizeStatus != kIOReturnSuccess {
            // Conflict (e.g. another touch driver). Reopen shared so touches
            // still flow; the OS cursor may fight us — surfaced in Settings.
            IOHIDManagerClose(manager, IOHIDOptionsType(kIOHIDOptionsTypeNone))
            let listenStatus = IOHIDManagerOpen(manager, IOHIDOptionsType(kIOHIDOptionsTypeNone))
            guard listenStatus == kIOReturnSuccess else {
                IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
                state = .deviceNotFound
                return
            }
            state = .sharedListen(interfaces: devices.count)
        } else {
            state = .seized(interfaces: devices.count)
        }

        digitizerDevices = devices.filter { device in
            let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int
            let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int
            return usagePage == kHIDPage_Digitizer && usage == kHIDUsage_Dig_TouchScreen
        }
        log.info("capture started: \(devices.count) interfaces, \(self.digitizerDevices.count) digitizer, seize=0x\(UInt32(bitPattern: seizeStatus), format: .hex)")

        self.manager = manager
    }

    public func stop() {
        if let manager {
            IOHIDManagerRegisterInputValueCallback(manager, nil, nil)
            IOHIDManagerClose(manager, IOHIDOptionsType(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        manager = nil
        if state != .noPermission { state = .idle }
    }

    // MARK: - Input

    // Hardware-verified (2026-07): with all interfaces seized, the EDGE's
    // digitizer interface stays silent — touches arrive on the boot-pointer
    // interface as ABSOLUTE X/Y (full digitizer range) plus a primary
    // button for contact. So values are accepted from any seized interface:
    // absolute-axis X/Y for position (relative mouse deltas are filtered by
    // their logical range) and tip switch OR primary button for contact.
    private func handle(value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let intValue = IOHIDValueGetIntegerValue(value)

        switch (page, usage) {
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_X) where isAbsoluteAxis(element):
            currentX = normalize(Double(intValue), element: element)
            if tipDown { emit(.moved) }
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_Y) where isAbsoluteAxis(element):
            currentY = normalize(Double(intValue), element: element)
            if tipDown { emit(.moved) }
        case (kHIDPage_Digitizer, kHIDUsage_Dig_TipSwitch), (kHIDPage_Button, 1):
            let down = intValue != 0
            guard down != tipDown else { break }
            tipDown = down
            emit(down ? .began : .ended)
        default:
            break
        }
    }

    /// Absolute position axes span the panel's full logical range; relative
    /// pointer deltas are small (and signed).
    private func isAbsoluteAxis(_ element: IOHIDElement) -> Bool {
        IOHIDElementGetLogicalMin(element) >= 0 && IOHIDElementGetLogicalMax(element) >= 1024
    }

    private func normalize(_ value: Double, element: IOHIDElement) -> Double {
        let lower = Double(IOHIDElementGetLogicalMin(element))
        let upper = Double(IOHIDElementGetLogicalMax(element))
        guard upper > lower else { return 0 }
        return min(max((value - lower) / (upper - lower), 0), 1)
    }

    private func emit(_ phase: RawTouch.Phase) {
        onTouch?(RawTouch(phase: phase, normalized: CGPoint(x: currentX, y: currentY)))
    }
}
