// swift-tools-version: 6.2

import PackageDescription

// This bridge is built outside the main Xcode workspace (via a `swift build`
// invocation in a build phase) so that the MLX dependency does not appear in
// the workspace's module search path. SwiftAgents/Conduit (transitively
// pulled in by HyperGraphReasoning) become uncompilable when MLX is visible
// to them but not linked, because they gate `MLXProvider` references behind
// `#if canImport(MLX)` without coordinating with Conduit's MLX trait.
let package = Package(
    name: "NewsCombUMAPBridge",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "newscomb-umap-bridge", targets: ["newscomb-umap-bridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/iliasaz/umap-mlx-swift.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "newscomb-umap-bridge",
            dependencies: [
                .product(name: "UMAPMLX", package: "umap-mlx-swift"),
            ],
            path: "Sources"
        ),
    ]
)
