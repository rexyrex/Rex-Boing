// swift-tools-version: 6.0
//
// RexBoingKit: the parts of Rex Boing that Rex Boing Remote shares — the
// snapshot model, its history, the samplers, the wire format, the dashboard
// cards and the menu bar characters.
//
// Rex Boing itself does not build through this manifest: its Xcode project
// (generated from project.yml) compiles the same files directly into the app.
// The manifest exists so other projects can depend on this repository with
// Swift Package Manager. It deliberately contains no networking code; neither
// does anything else in this repository.
import PackageDescription

let package = Package(
    name: "RexBoingKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RexBoingKit", targets: ["RexBoingKit"]),
    ],
    targets: [
        .target(
            name: "RexBoingKit",
            path: "RexBoing",
            exclude: [
                "App",
                "Assets.xcassets",
                "Info.plist",
                "RexBoing.entitlements",
                "Metrics/MetricsEngine.swift",
                "StatusBar/StatusItemController.swift",
                "UI/DashboardView.swift",
                "UI/ProcessInspector.swift",
                "UI/SettingsView.swift",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("StrictConcurrency"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("QuartzCore"),
            ]
        ),
    ]
)
