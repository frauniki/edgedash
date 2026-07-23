import Foundation

/// Settings-UI strings resolve against this module's own catalog — the
/// bare-key initializers on SwiftUI controls only search the main bundle.
func loc(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: Bundle.module)
}
