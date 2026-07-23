import Darwin
import Foundation

/// Thin typed wrappers over sysctlbyname.
enum Sysctl {
    static func value<T: BitwiseCopyable>(_ name: String, default defaultValue: T) -> T {
        var result = defaultValue
        var size = MemoryLayout<T>.stride
        guard sysctlbyname(name, &result, &size, nil, 0) == 0 else { return defaultValue }
        return result
    }

    static func swapUsage() -> xsw_usage {
        value("vm.swapusage", default: xsw_usage())
    }

    /// 1 = normal, 2 = warning, 4 = critical (kern.memorystatus_vm_pressure_level).
    static func memoryPressureLevel() -> Int32 {
        value("kern.memorystatus_vm_pressure_level", default: 1)
    }
}
