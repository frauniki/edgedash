import Darwin
import EdgeCore
import Foundation
import SystemConfiguration

public extension MetricID {
    static let networkThroughput = MetricID("net.throughput") // duplex bytes/s: down(in)/up(out)
}

/// Primary-interface throughput from getifaddrs byte-counter deltas.
public final class NetworkReader: MetricReader, @unchecked Sendable {
    private var counter = RateCounter() // engine calls read() serially

    public init() {}

    public var provides: [MetricID] {
        [.networkThroughput]
    }

    public var cadence: MetricCadence {
        .everyTick
    }

    public func read() throws -> [MetricSample] {
        let primary = Self.primaryInterface()
        let (rx, tx) = Self.byteCounts(interface: primary)
        guard let rates = counter.rates(in: rx, out: tx) else { return [] }
        return [MetricSample(id: .networkThroughput, value: .duplex(in: rates.in, out: rates.out))]
    }

    /// Routing-table primary interface (e.g. "en0"), from SCDynamicStore.
    public static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "EdgeDash" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else {
            return nil
        }
        return value["PrimaryInterface"] as? String
    }

    /// Current IPv4 address of an interface, for display purposes.
    public static func ipv4Address(interface: String) -> String? {
        address(interface: interface, family: UInt8(AF_INET))
    }

    /// First global (non-link-local) IPv6 address of an interface.
    public static func ipv6Address(interface: String) -> String? {
        address(interface: interface, family: UInt8(AF_INET6))
    }

    private static func address(interface: String, family: UInt8) -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return nil }
        defer { freeifaddrs(addrs) }
        var cursor = addrs
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard String(cString: ifa.pointee.ifa_name) == interface,
                  let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == family else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: host)
                if family == UInt8(AF_INET6), text.hasPrefix("fe80") { continue } // skip link-local
                return text
            }
        }
        return nil
    }

    /// Sums rx/tx bytes for the given interface, or all non-loopback
    /// interfaces when none is specified.
    static func byteCounts(interface: String?) -> (rx: UInt64, tx: UInt64) {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return (0, 0) }
        defer { freeifaddrs(addrs) }

        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var cursor = addrs
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
                  let dataPtr = ifa.pointee.ifa_data else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            if let interface {
                guard name == interface else { continue }
            } else {
                guard !name.hasPrefix("lo") else { continue }
            }
            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            rx &+= UInt64(data.ifi_ibytes)
            tx &+= UInt64(data.ifi_obytes)
        }
        return (rx, tx)
    }
}
