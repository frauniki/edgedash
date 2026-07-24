import EdgeCore
import Foundation
import Testing

@MainActor struct ConfigStoreTests {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("edgedash-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func freshInstallWritesDefaultConfig() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let page = DashboardPage(name: "Starter")
        let store = ConfigStore(directory: dir, defaultConfig: DashboardConfig(pages: [page]))
        #expect(store.config.pages.first?.name == "Starter")

        let onDisk = try Data(contentsOf: dir.appendingPathComponent("config.json"))
        let decoded = try JSONDecoder().decode(DashboardConfig.self, from: onDisk)
        #expect(decoded.pages.first?.name == "Starter")
    }

    @Test func loadsExistingConfigOverDefault() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var existing = DashboardConfig(pages: [DashboardPage(name: "Mine")])
        existing.schemaVersion = 0 // older schema migrates forward
        let data = try JSONEncoder().encode(existing)
        try data.write(to: dir.appendingPathComponent("config.json"))

        let store = ConfigStore(directory: dir, defaultConfig: DashboardConfig(pages: [DashboardPage(name: "Default")]))
        #expect(store.config.pages.first?.name == "Mine")
        #expect(store.config.schemaVersion == DashboardConfig.currentSchemaVersion)
    }

    @Test func corruptFileFallsBackToDefault() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("{broken json!".utf8).write(to: dir.appendingPathComponent("config.json"))
        let store = ConfigStore(directory: dir, defaultConfig: DashboardConfig(pages: [DashboardPage(name: "Default")]))
        #expect(store.config.pages.first?.name == "Default")
    }

    @Test func updateMutatesAndSaveNowPersists() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ConfigStore(directory: dir, defaultConfig: DashboardConfig(pages: []))
        store.update { $0.pages.append(DashboardPage(name: "Added")) }
        store.saveNow()

        let onDisk = try Data(contentsOf: dir.appendingPathComponent("config.json"))
        let decoded = try JSONDecoder().decode(DashboardConfig.self, from: onDisk)
        #expect(decoded.pages.map(\.name) == ["Added"])
    }
}
