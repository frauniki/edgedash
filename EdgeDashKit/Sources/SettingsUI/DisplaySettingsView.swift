import EdgeCore
import SwiftUI

/// A selectable display as presented by the app layer.
public struct DisplayChoice: Identifiable, Sendable {
    public let id: String // CGDisplay UUID string
    public let name: String
    public let isProfileMatch: Bool

    public init(id: String, name: String, isProfileMatch: Bool) {
        self.id = id
        self.name = name
        self.isProfileMatch = isProfileMatch
    }
}

public struct DisplaySettingsView: View {
    private let configStore: ConfigStore
    private let statusText: String
    private let displayChoices: @MainActor () -> [DisplayChoice]

    @State private var choices: [DisplayChoice] = []

    public init(
        configStore: ConfigStore,
        statusText: String,
        displayChoices: @escaping @MainActor () -> [DisplayChoice]
    ) {
        self.configStore = configStore
        self.statusText = statusText
        self.displayChoices = displayChoices
    }

    public var body: some View {
        Form {
            Section(loc("Dashboard display")) {
                LabeledContent(loc("Status"), value: statusText)
                Picker(loc("Display"), selection: selectionBinding) {
                    Text("Auto-detect supported device", bundle: Bundle.module).tag(String?.none)
                    ForEach(choices) { choice in
                        Text(choice.name + (choice.isProfileMatch ? loc("  ✓ supported device") : ""))
                            .tag(Optional(choice.id))
                    }
                }
                .help(Text("Auto-detect finds known devices (XENEON EDGE). Pick a specific display to use any screen.", bundle: Bundle.module))
            }
            Section(loc("Power")) {
                Toggle(loc("Keep displays awake while dashboard is visible"), isOn: keepAwakeBinding)
                Text("macOS has no per-display sleep — this keeps ALL displays awake.", bundle: Bundle.module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { choices = displayChoices() }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: {
                if case .byUUIDs(let uuids) = configStore.config.display { return uuids.first }
                return nil
            },
            set: { newValue in
                configStore.update { config in
                    config.display = newValue.map { .byUUIDs([$0]) } ?? .autoDetect
                }
            }
        )
    }

    private var keepAwakeBinding: Binding<Bool> {
        Binding(
            get: { configStore.config.options.keepAwake },
            set: { newValue in configStore.update { $0.options.keepAwake = newValue } }
        )
    }
}
