import Foundation
import Observation

/// Owns the persisted DashboardConfig. JSON on disk, human-editable:
/// ~/Library/Application Support/EdgeDash/config.json. Atomic, debounced
/// writes; external edits are picked up via a file watcher so hand-editing
/// the file live-updates the dashboard.
@Observable @MainActor public final class ConfigStore {
    public private(set) var config: DashboardConfig

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?
    private var watcher: DispatchSourceFileSystemObject?
    /// Snapshot of what we last wrote, to ignore our own file events.
    private var lastWrittenData: Data?

    public init(directory: URL? = nil, defaultConfig: @autoclosure () -> DashboardConfig) {
        let dir = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EdgeDash", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("config.json")

        if let loaded = Self.load(from: fileURL) {
            config = Self.migrate(loaded)
        } else {
            config = defaultConfig()
            saveNow()
        }
        startWatching()
    }

    public func update(_ mutate: (inout DashboardConfig) -> Void) {
        mutate(&config)
        scheduleSave()
    }

    // MARK: - Persistence

    public func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard let data = try? Self.encoder.encode(config) else { return }
        lastWrittenData = data
        try? data.write(to: fileURL, options: .atomic)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    static func load(from url: URL) -> DashboardConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DashboardConfig.self, from: data)
    }

    /// Explicit schema migration chain; currently at version 1.
    static func migrate(_ config: DashboardConfig) -> DashboardConfig {
        var config = config
        config.schemaVersion = DashboardConfig.currentSchemaVersion
        return config
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    // MARK: - External edits

    private func startWatching() {
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.handleFileEvent() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func handleFileEvent() {
        // Atomic writes replace the file: re-arm the watcher on the new inode.
        watcher?.cancel()
        watcher = nil

        if let data = try? Data(contentsOf: fileURL),
           data != lastWrittenData,
           let loaded = try? JSONDecoder().decode(DashboardConfig.self, from: data) {
            config = Self.migrate(loaded)
        }
        startWatching()
    }
}
