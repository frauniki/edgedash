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
            Section("Dashboard display") {
                LabeledContent("Status", value: statusText)
                Picker("Display", selection: selectionBinding) {
                    Text("Auto-detect supported device").tag(Optional<String>.none)
                    ForEach(choices) { choice in
                        Text(choice.name + (choice.isProfileMatch ? "  ✓ supported device" : ""))
                            .tag(Optional(choice.id))
                    }
                }
                .help("Auto-detect finds known devices (XENEON EDGE). Pick a specific display to use any screen.")
            }
            Section("Power") {
                Toggle("Keep displays awake while dashboard is visible", isOn: keepAwakeBinding)
                Text("macOS has no per-display sleep — this keeps ALL displays awake.")
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
