import AppKit
import SwiftUI
import WidgetEngine

/// Resolves app icons for process names (matched against running apps),
/// falling back to a generic executable icon for CLI tools. Cached — lookups
/// happen at most once per process name.
@MainActor final class ProcessIconCache {
    static let shared = ProcessIconCache()
    private var cache: [String: NSImage] = [:]
    private lazy var genericIcon: NSImage = NSWorkspace.shared.icon(for: .unixExecutable)

    func icon(for processName: String) -> NSImage {
        if let cached = cache[processName] { return cached }
        let icon = NSWorkspace.shared.runningApplications.first {
            $0.localizedName == processName
                || $0.bundleURL?.deletingPathExtension().lastPathComponent == processName
        }?.icon ?? genericIcon
        cache[processName] = icon
        return icon
    }
}

/// "⬚ name .... value" process row with app icon, shared by CPU and memory
/// widgets.
struct ProcessRow: View {
    @Environment(\.theme) private var theme
    let name: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: ProcessIconCache.shared.icon(for: name))
                .resizable()
                .frame(width: 15, height: 15)
            Text(name)
                .foregroundStyle(theme.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary.color)
        }
        .font(.system(size: 12, design: .rounded))
    }
}
