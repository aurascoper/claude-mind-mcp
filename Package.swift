// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ClaudeMindMCP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "claude-mind-mcp", targets: ["ClaudeMindMCP"]),
        .executable(name: "claude-mind-bench", targets: ["ClaudeMindBench"]),
        .executable(name: "claude-mind-regression", targets: ["ClaudeMindRegressionTest"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.29.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.3.0")
    ],
    targets: [
        .target(
            name: "ClaudeMindCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Transformers", package: "swift-transformers")
            ]
        ),
        .target(
            name: "ClaudeMindMirror",
            dependencies: [
                "ClaudeMindCore",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle")
            ],
            // Stop-gap for Swift 6.3.1 release-mode optimizer bug that crashes
            // postgres-nio with "freed pointer was not the last allocation" on
            // the second consecutive query. Mirror is I/O-bound, so -Onone for
            // this target only is a fine trade until the upstream fix lands.
            swiftSettings: [
                .unsafeFlags(["-Onone"], .when(configuration: .release))
            ]
        ),
        .executableTarget(
            name: "ClaudeMindMCP",
            dependencies: [
                "ClaudeMindCore",
                "ClaudeMindMirror",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle")
            ]
        ),
        .executableTarget(
            name: "ClaudeMindBench",
            dependencies: [
                "ClaudeMindCore",
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        // CommandLineTools-only setups (no Xcode) lack XCTest/Testing modules,
        // so regression checks live in a tiny executable that exits non-zero
        // on failure. Run via: `swift run claude-mind-regression`.
        .executableTarget(
            name: "ClaudeMindRegressionTest",
            dependencies: [
                "ClaudeMindCore",
                .product(name: "Logging", package: "swift-log")
            ]
        )
    ]
)
