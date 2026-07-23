import EdgeCore
import SwiftUI
import WidgetEngine

public struct AppearanceSettingsView: View {
    private let configStore: ConfigStore

    public init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    public var body: some View {
        Form {
            Section("Theme") {
                // The section header already says "Theme" — a labeled row
                // would repeat it and push the radios to the trailing edge.
                Picker("", selection: themeBinding) {
                    ForEach(BuiltinThemes.all) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                swatches
            }
            Section("Background") {
                sliderRow(
                    "Opacity",
                    value: optionBinding(\.backgroundOpacity),
                    range: 0...1,
                    text: String(format: "%.0f%%", configStore.config.options.backgroundOpacity * 100)
                )
                sliderRow(
                    "Blur",
                    value: optionBinding(\.backgroundBlurRadius),
                    range: 0...40,
                    text: String(format: "%.0f", configStore.config.options.backgroundBlurRadius)
                )
                Text("Lower the opacity to let the desktop wallpaper on the display show through; blur frosts it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Static label + fixed-width value so the slider doesn't resize while
    /// dragging (a live value inside the row label changed the label width,
    /// which made the slider jitter).
    private func sliderRow(
        _ label: String, value: Binding<Double>, range: ClosedRange<Double>, text: String
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 10) {
                Slider(value: value, in: range)
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    private func optionBinding<T>(_ keyPath: WritableKeyPath<GlobalOptions, T>) -> Binding<T> {
        Binding(
            get: { configStore.config.options[keyPath: keyPath] },
            set: { newValue in configStore.update { $0.options[keyPath: keyPath] = newValue } }
        )
    }

    private var themeBinding: Binding<ThemeID> {
        Binding(
            get: { configStore.config.themeID },
            set: { newValue in configStore.update { $0.themeID = newValue } }
        )
    }

    /// Small preview of the selected theme's data colors.
    private var swatches: some View {
        let theme = BuiltinThemes.theme(for: configStore.config.themeID)
        return HStack(spacing: 8) {
            ForEach(
                [theme.accent, theme.accentAlt, theme.warn, theme.critical],
                id: \.self
            ) { token in
                RoundedRectangle(cornerRadius: 4)
                    .fill(token.color)
                    .frame(width: 40, height: 20)
            }
            Spacer()
        }
        .padding(.top, 4)
    }
}
