// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EdgeDashKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "EdgeDashKit",
            targets: [
                "EdgeCore", "EdgeMetrics", "SMCBridge", "EdgeDisplay",
                "EdgeTouch", "WidgetEngine", "BuiltinWidgets", "MediaWidgets", "AgentWidgets", "WeatherWidgets", "SettingsUI",
            ]
        ),
        .executable(name: "touch-spike", targets: ["TouchSpike"]),
    ],
    targets: [
        .target(name: "EdgeCore"),
        .target(name: "EdgeMetrics", dependencies: ["EdgeCore"]),
        .target(name: "SMCBridge", dependencies: ["EdgeCore"]),
        .target(name: "EdgeDisplay", dependencies: ["EdgeCore"]),
        .target(name: "EdgeTouch", dependencies: ["EdgeCore"]),
        .target(name: "WidgetEngine", dependencies: ["EdgeCore"]),
        .target(
            name: "BuiltinWidgets",
            dependencies: ["WidgetEngine", "EdgeMetrics", "SMCBridge", "EdgeTouch"],
            resources: [.process("Localizable.xcstrings")]
        ),
        .target(
            name: "MediaWidgets",
            dependencies: ["WidgetEngine", "EdgeTouch"],
            resources: [.process("Localizable.xcstrings")],
            linkerSettings: [.linkedFramework("ScriptingBridge")]
        ),
        .target(
            name: "AgentWidgets",
            dependencies: ["WidgetEngine", "EdgeTouch"],
            resources: [.process("Localizable.xcstrings")]
        ),
        .target(
            name: "WeatherWidgets",
            dependencies: ["WidgetEngine"],
            resources: [.process("Localizable.xcstrings")],
            linkerSettings: [.linkedFramework("CoreLocation")]
        ),
        .target(
            name: "SettingsUI",
            dependencies: ["WidgetEngine", "EdgeCore", "EdgeTouch"],
            resources: [.process("Localizable.xcstrings")]
        ),
        .executableTarget(
            name: "TouchSpike",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .testTarget(name: "EdgeCoreTests", dependencies: ["EdgeCore"]),
        .testTarget(name: "SMCBridgeTests", dependencies: ["SMCBridge"]),
        .testTarget(name: "EdgeMetricsTests", dependencies: ["EdgeMetrics"]),
        .testTarget(name: "EdgeTouchTests", dependencies: ["EdgeTouch"]),
        .testTarget(name: "WidgetEngineTests", dependencies: ["WidgetEngine"]),
        .testTarget(name: "MediaWidgetsTests", dependencies: ["MediaWidgets"]),
        .testTarget(name: "AgentWidgetsTests", dependencies: ["AgentWidgets"]),
        .testTarget(
            name: "WeatherWidgetsTests",
            dependencies: ["WeatherWidgets"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
