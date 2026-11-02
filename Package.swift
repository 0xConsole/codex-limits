// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .executable(name: "codex-limits", targets: ["CodexLimitsCLI"]),
]

var targets: [Target] = [
    .target(
        name: "CodexLimitsCore",
        path: "Sources/CodexLimitsCore"
    ),
    .executableTarget(
        name: "CodexLimitsCLI",
        dependencies: ["CodexLimitsCore"],
        path: "Sources/CodexLimitsCLI"
    ),
    .testTarget(
        name: "CodexLimitsCoreTests",
        dependencies: ["CodexLimitsCore"],
        path: "Tests/CodexLimitsCoreTests"
    ),
]

// The menu-bar app needs AppKit and SwiftUI, so it only exists when building on macOS.
#if os(macOS)
products.append(.executable(name: "CodexLimits", targets: ["CodexLimits"]))
targets.append(
    .executableTarget(
        name: "CodexLimits",
        dependencies: ["CodexLimitsCore"],
        path: "Sources/CodexLimits"
    )
)
#endif

let package = Package(
    name: "CodexLimits",
    platforms: [
        .macOS(.v13),
    ],
    products: products,
    targets: targets
)
