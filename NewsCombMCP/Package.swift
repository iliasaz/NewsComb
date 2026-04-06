// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NewsCombMCP",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(path: "../GRDBCustom"),
        .package(url: "https://github.com/jkrukowski/swift-embeddings", from: "0.0.16"),
    ],
    targets: [
        .executableTarget(
            name: "newscomb-mcp",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "GRDB", package: "GRDBCustom"),
                .product(name: "SQLiteExtensions", package: "GRDBCustom"),
                .product(name: "Embeddings", package: "swift-embeddings"),
            ],
            path: "Sources",
            swiftSettings: [
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        )
    ]
)
