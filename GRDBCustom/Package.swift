// swift-tools-version: 6.1

import PackageDescription

let package = Package(
  name: "GRDBCustom",
  products: [
    .library(
      name: "SQLiteExtensions",
      targets: ["SQLiteExtensions"]
    ),
    .library(
      name: "GRDB",
      targets: ["GRDB"]
    )
  ],
  targets: [
    .target(
      name: "SQLiteExtensions",
      dependencies: ["GRDB"],
      publicHeadersPath: "include",
      cSettings: [
        .define("SQLITE_CORE", to: "1"),
      ]
    ),
    .binaryTarget(
      name: "GRDB",
      path: "Binary/GRDB.xcframework"
    ),
  ]
)
