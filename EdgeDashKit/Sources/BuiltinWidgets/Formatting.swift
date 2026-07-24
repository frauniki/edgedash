import Foundation

/// Shared value formatting for monitoring widgets.
enum ByteRate {
    static func text(_ bytesPerSecond: Double) -> String {
        switch bytesPerSecond {
        case ..<1000: String(format: "%.0f B/s", bytesPerSecond)
        case ..<1_000_000: String(format: "%.0f KB/s", bytesPerSecond / 1000)
        case ..<1_000_000_000: String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        default: String(format: "%.2f GB/s", bytesPerSecond / 1_000_000_000)
        }
    }
}
