// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Absolute -L for the prebuilt Rust staticlib (built by scripts/build-rust.sh).
// Derived from this manifest's location so no env var is needed.
let rustLibDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // swift/
    .deletingLastPathComponent() // repo root
    .appendingPathComponent("rust/ostmac-core/target/release")
    .standardizedFileURL.path

let rustLink: [LinkerSetting] = [
    .unsafeFlags(["-L\(rustLibDir)", "-lostmac_core"]),
    .linkedFramework("Security"),
    .linkedFramework("CoreFoundation"),
    .linkedFramework("SystemConfiguration"),
]

// UI-SPEC §4: every target stays in Swift 5 language mode (no strict-
// concurrency churn in the core).
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "OstMac",
    // Keep in sync with MACOSX_DEPLOYMENT_TARGET in scripts/build-rust.sh.
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "OstMac", targets: ["OstMac"]),
        .executable(name: "ostmac-mcp", targets: ["ostmac-mcp"]),
    ],
    targets: [
        .target(name: "COstMac", publicHeadersPath: "include"),
        // All non-view logic, incl. the former OstMacChatList files and
        // the AppState composition root (UI-SPEC §11.1).
        .target(name: "OstMacCore", dependencies: ["COstMac"], swiftSettings: v5),
        .target(name: "OstMacMCP", dependencies: ["OstMacCore"], swiftSettings: v5),
        // Every view, controller, and window (UI-SPEC §11.2). Skeleton
        // until P1.
        .target(
            name: "BetterTeamsUI",
            dependencies: ["OstMacCore", "COstMac"],
            swiftSettings: v5
        ),
        .executableTarget(
            name: "OstMac",
            dependencies: ["BetterTeamsUI", "OstMacCore", "COstMac"],
            swiftSettings: v5,
            linkerSettings: rustLink
        ),
        .executableTarget(
            name: "ostmac-mcp",
            dependencies: ["OstMacMCP", "OstMacCore", "COstMac"],
            swiftSettings: v5,
            linkerSettings: rustLink
        ),
        .testTarget(
            name: "OstMacCoreTests",
            dependencies: ["OstMacCore", "COstMac"],
            swiftSettings: v5,
            linkerSettings: rustLink
        ),
        .testTarget(
            name: "OstMacMCPTests",
            dependencies: ["OstMacMCP", "OstMacCore", "COstMac"],
            swiftSettings: v5,
            linkerSettings: rustLink
        ),
        // Pure-logic UI tests only (UI-SPEC §11.1).
        .testTarget(
            name: "BetterTeamsUITests",
            dependencies: ["BetterTeamsUI", "OstMacCore", "COstMac"],
            swiftSettings: v5,
            linkerSettings: rustLink
        ),
    ]
)
