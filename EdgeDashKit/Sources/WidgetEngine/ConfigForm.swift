import SwiftUI

/// Layout container for widget config UIs hosted in the settings inspector.
/// `Form`'s column layout falls apart in that narrow pane (labels wrap,
/// toggles drift toward the middle), so config views use this plain
/// leading-aligned column instead.
public struct ConfigForm<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Titled group of rows inside a ``ConfigForm``.
public struct ConfigSection<Content: View>: View {
    private let title: String
    private let content: Content

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(.top, 4)
    }
}
