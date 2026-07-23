// Temperature sensors via the private IOHIDEventSystemClient API — the
// standard community approach on Apple Silicon (see exelban/stats, macmon;
// MIT attribution in NOTICE). Everything feature-detects at runtime: on any
// future macOS where these symbols/services change, readers return no
// samples and the widgets show "unavailable" — nothing crashes.

import CoreFoundation
import Foundation

// MARK: - Private IOKit HID symbols

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> OpaquePointer?

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: OpaquePointer?, _ matching: CFDictionary?)

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: OpaquePointer?) -> OpaquePointer?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: OpaquePointer?, _ key: CFString?) -> OpaquePointer?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: OpaquePointer?, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> OpaquePointer?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: OpaquePointer?, _ field: Int32) -> Double

private let kIOHIDEventTypeTemperature: Int64 = 15
private let kAppleVendorUsagePage = 0xFF00
private let kTemperatureSensorUsage = 5

/// Reads every AppleVendor temperature sensor the HID event system exposes.
enum HIDTemperatureSensors {
    /// name → °C. Empty when the private API is unavailable.
    static func readAll() -> [String: Double] {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return [:] }
        defer { release(client) }

        let matching = [
            "PrimaryUsagePage": kAppleVendorUsagePage,
            "PrimaryUsage": kTemperatureSensorUsage,
        ] as CFDictionary
        IOHIDEventSystemClientSetMatching(client, matching)

        guard let servicesPtr = IOHIDEventSystemClientCopyServices(client) else { return [:] }
        let services = Unmanaged<CFArray>.fromOpaque(UnsafeRawPointer(servicesPtr)).takeRetainedValue()

        var result: [String: Double] = [:]
        for index in 0..<CFArrayGetCount(services) {
            guard let raw = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = OpaquePointer(raw)

            guard let namePtr = IOHIDServiceClientCopyProperty(service, "Product" as CFString) else { continue }
            let name = Unmanaged<CFString>.fromOpaque(UnsafeRawPointer(namePtr)).takeRetainedValue() as String

            guard let event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0) else { continue }
            defer { release(event) }
            // IOHIDEventFieldBase(type) == type << 16
            let celsius = IOHIDEventGetFloatValue(event, Int32(kIOHIDEventTypeTemperature << 16))
            if celsius > -40, celsius < 150 {
                result[name] = celsius
            }
        }
        return result
    }

    private static func release(_ object: OpaquePointer) {
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(object)).release()
    }
}
