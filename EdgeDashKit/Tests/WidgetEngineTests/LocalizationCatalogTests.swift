import Foundation
import Testing

/// Validates the hand-authored String Catalogs. `swift test` copies the raw
/// .xcstrings into bundles without compiling them (only xcodebuild does), so
/// runtime lookup can't be tested here — instead the catalogs are checked at
/// the source level: parseable JSON, every key fully translated to Japanese,
/// and printf-style specifiers matching between key and translation (a
/// mismatched specifier silently breaks the lookup or the substitution).
struct LocalizationCatalogTests {
    private struct Catalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                // Mirrors the xcstrings shape.
                // swiftlint:disable:next nesting
                struct Unit: Decodable {
                    let state: String
                    let value: String
                }

                let stringUnit: Unit?
            }

            let localizations: [String: Localization]?
        }

        let sourceLanguage: String
        let strings: [String: Entry]
    }

    /// Repo root, derived from this file's location in EdgeDashKit/Tests/….
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // WidgetEngineTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // EdgeDashKit
        .deletingLastPathComponent() // repo root

    private static let catalogPaths = [
        "EdgeDashKit/Sources/SettingsUI/Localizable.xcstrings",
        "EdgeDashKit/Sources/BuiltinWidgets/Localizable.xcstrings",
        "EdgeDashKit/Sources/MediaWidgets/Localizable.xcstrings",
        "EdgeDashKit/Sources/AgentWidgets/Localizable.xcstrings",
        "EdgeDashKit/Sources/WeatherWidgets/Localizable.xcstrings",
        "EdgeDash/Sources/Localizable.xcstrings",
    ]

    @Test(arguments: catalogPaths) func everyKeyIsTranslatedToJapanese(path: String) throws {
        let url = Self.repoRoot.appendingPathComponent(path)
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        #expect(catalog.sourceLanguage == "en")
        #expect(!catalog.strings.isEmpty)
        for (key, entry) in catalog.strings {
            let ja = entry.localizations?["ja"]?.stringUnit
            #expect(ja != nil, "\(path): '\(key)' has no ja translation")
            #expect(ja?.state == "translated", "\(path): '\(key)' ja not marked translated")
            #expect(ja?.value.isEmpty == false, "\(path): '\(key)' ja translation is empty")
            if let value = ja?.value {
                #expect(
                    Self.specifiers(in: key) == Self.specifiers(in: value),
                    "\(path): '\(key)' specifier mismatch with ja '\(value)'"
                )
            }
        }
    }

    /// Printf-style specifiers in order of appearance ("%%" excluded — it's a
    /// literal percent sign).
    private static func specifiers(in s: String) -> [String] {
        let pattern = /%(?:%|[0-9.]*[a-zA-Z@]+)/
        return s.matches(of: pattern).map(\.output).map(String.init).filter { $0 != "%%" }.sorted()
    }
}
