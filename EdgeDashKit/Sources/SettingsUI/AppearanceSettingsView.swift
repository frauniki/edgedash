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
                Picker("Theme", selection: themeBinding) {
                    ForEach(BuiltinThemes.all) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
                .pickerStyle(.radioGroup)
                swatches
            }
            Section("Background") {
                LabeledContent(String(format: "Opacity %.0f%%", configStore.config.options.backgroundOpacity * 100)) {
                    Slider(value: optionBinding(\.backgroundOpacity), in: 0...1)
                }
                Toggle("Blur wallpaper behind", isOn: optionBinding(\.backgroundBlur))
                Text("Lower the opacity to let the desktop wallpaper on the display show through; blur frosts it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
