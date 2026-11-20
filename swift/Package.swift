// swift-tools-version: 6.0
// Microhm — native macOS port of micro-harness-manager. See PORTING.md.
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Microhm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Microhm", targets: ["MicrohmApp"]),
        .executable(name: "microhm-mux", targets: ["microhm-mux"]),
        .executable(name: "microhm-host", targets: ["microhm-host"]),
    ],
    targets: [
        .target(name: "MicrohmShared", swiftSettings: v5),
        .target(name: "MicrohmVT", dependencies: ["MicrohmShared"], swiftSettings: v5),
        .target(name: "MicrohmPTY", dependencies: ["MicrohmShared"], swiftSettings: v5),
        .target(name: "MicrohmMux", dependencies: ["MicrohmShared", "MicrohmVT", "MicrohmPTY"], swiftSettings: v5),
        .target(name: "MicrohmCore", dependencies: ["MicrohmShared", "MicrohmVT", "MicrohmMux"],
                resources: [.copy("Resources/web")], swiftSettings: v5),
        .target(name: "MicrohmTerminal", dependencies: ["MicrohmShared", "MicrohmVT"], swiftSettings: v5),
        .executableTarget(name: "MicrohmApp", dependencies: ["MicrohmCore", "MicrohmTerminal"],
                          resources: [.copy("Resources/app-icon.png"), .copy("Resources/provider-icons")],
                          swiftSettings: v5),
        .executableTarget(name: "microhm-mux", dependencies: ["MicrohmMux"], swiftSettings: v5),
        .executableTarget(name: "microhm-host", dependencies: ["MicrohmCore"], swiftSettings: v5),
        .testTarget(name: "MicrohmVTTests", dependencies: ["MicrohmVT"], resources: [.copy("golden")], swiftSettings: v5),
        .testTarget(name: "MicrohmPTYTests", dependencies: ["MicrohmPTY"], swiftSettings: v5),
        .testTarget(name: "MicrohmMuxTests", dependencies: ["MicrohmMux"], swiftSettings: v5),
        .testTarget(name: "MicrohmCoreTests", dependencies: ["MicrohmCore"], swiftSettings: v5),
        .testTarget(name: "MicrohmTerminalTests", dependencies: ["MicrohmTerminal"], swiftSettings: v5),
    ]
)
