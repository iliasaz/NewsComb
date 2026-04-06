// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NewsCombMCPBridge",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "newscomb-mcp-bridge",
            path: "Sources"
        ),
    ]
)
