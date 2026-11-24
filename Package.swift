// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "rtop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "rtop", targets: ["RTopCLI"])
    ],
    targets: [
        // C boundary for ABI-sensitive Darwin calls and the signal self-pipe.
        .target(name: "DarwinSupport"),
        .target(name: "MonitorCore"),
        .target(name: "MonitorDarwin", dependencies: ["DarwinSupport", "MonitorCore"]),
        .target(name: "TerminalUI", dependencies: ["DarwinSupport", "MonitorCore"]),
        .executableTarget(
            name: "RTopCLI",
            dependencies: ["MonitorCore", "MonitorDarwin", "TerminalUI"]
        ),
        .testTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"]),
        .testTarget(name: "MonitorDarwinTests", dependencies: ["MonitorDarwin", "DarwinSupport"]),
        .testTarget(name: "TerminalUITests", dependencies: ["TerminalUI", "DarwinSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
