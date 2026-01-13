// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NewsComb",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .library(name: "NewsComb", targets: ["NewsComb"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/nmdias/FeedKit", from: "9.1.2")
    ],
    targets: [
        .target(
            name: "NewsComb",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "FeedKit", package: "FeedKit")
            ],
            path: "Sources",
            exclude: ["NewsCombApp.swift"],
            swiftSettings: [
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]
        ),
        .executableTarget(
            name: "NewsCombApp",
            dependencies: ["NewsComb"],
            path: "Sources",
            sources: ["NewsCombApp.swift"]
        ),
        .testTarget(
            name: "NewsCombTests",
            dependencies: ["NewsComb"],
            path: "Tests"
        )
    ]
)
