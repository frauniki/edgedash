import Darwin
import EdgeCore
import Foundation
import IOKit

public extension MetricID {
    static let diskCapacity = MetricID("disk.capacity") // composite bytes: used/free/total (root volume)
    static let diskIO = MetricID("disk.io") // duplex bytes/s: read(in)/write(out)

    /// Per-volume capacity; the root volume keeps the legacy plain id so
    /// existing configs stay valid.
    static func diskCapacity(volume path: String) -> MetricID {
        path == "/" ? .diskCapacity : MetricID("disk.capacity.\(path)")
    }
}

/// Capacity for every mounted user-visible volume, via documented URL
/// resource values. Slow-changing → 30 s.
public struct DiskCapacityReader: MetricReader {
    private let volumePaths: [String]

    public init() {
        volumePaths = Self.mountedVolumes().map(\.path)
    }

    public var provides: [MetricID] {
        volumePaths.map { .diskCapacity(volume: $0) }
    }

    public var cadence: MetricCadence {
        .every(30)
    }

    public func read() throws -> [MetricSample] {
        volumePaths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            ]),
                let total = values.volumeTotalCapacity,
                let free = values.volumeAvailableCapacityForImportantUsage
            else {
                return nil
            }
            return MetricSample(id: .diskCapacity(volume: path), value: .composite([
                "total": Double(total),
                "free": Double(free),
                "used": Double(max(0, Int64(total) - free)),
            ]))
        }
    }

    /// User-visible mounted volumes, for the widget's volume picker.
    public static func mountedVolumes() -> [(path: String, name: String)] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? [URL(fileURLWithPath: "/")]
        return urls.map { url in
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
            return (path: url.path, name: name ?? url.lastPathComponent)
        }
    }
}

/// Whole-system disk I/O from IOBlockStorageDriver statistics deltas.
public final class DiskIOReader: MetricReader, @unchecked Sendable {
    private var counter = RateCounter() // engine calls read() serially

    public init() {}

    public var provides: [MetricID] {
        [.diskIO]
    }

    public var cadence: MetricCadence {
        .everyTick
    }

    public func read() throws -> [MetricSample] {
        let (read, written) = Self.totalBytes()
        guard let rates = counter.rates(in: read, out: written) else { return [] }
        return [MetricSample(id: .diskIO, value: .duplex(in: rates.in, out: rates.out))]
    }

    static func totalBytes() -> (read: UInt64, written: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOBlockStorageDriver"),
            &iterator
        ) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var written: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = propsRef?.takeRetainedValue() as? [String: Any],
                  let stats = props["Statistics"] as? [String: Any] else { continue }
            read &+= (stats["Bytes (Read)"] as? UInt64) ?? 0
            written &+= (stats["Bytes (Write)"] as? UInt64) ?? 0
        }
        return (read, written)
    }
}
