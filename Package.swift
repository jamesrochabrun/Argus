// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Argus",
  platforms: [
    .macOS(.v14),
  ],
  products: [
    .executable(name: "argus", targets: ["Argus"]),
  ],
  dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.7.1"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    .package(url: "https://github.com/jamesrochabrun/SwiftOpenAI", exact: "4.4.5"),
  ],
  targets: [
    .executableTarget(
      name: "Argus",
      dependencies: [
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "SwiftOpenAI", package: "SwiftOpenAI"),
        "ArgusMCP",
      ],
      path: "Sources/Argus"
    ),
    .target(
      name: "ArgusMCP",
      dependencies: [
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "SwiftOpenAI", package: "SwiftOpenAI"),
      ],
      path: "Sources/ArgusMCP"
    ),
  ]
)
