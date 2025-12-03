// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ArgusMCP",
  platforms: [
    .macOS(.v14),
  ],
  products: [
    .executable(name: "argus-mcp", targets: ["ArgusMCP"]),
    .executable(name: "argus-select", targets: ["ArgusSelect"]),
  ],
  dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.7.1"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    .package(path: "/Users/jamesrochabrun/Desktop/git/SwiftOpenAI"),
  ],
  targets: [
    .executableTarget(
      name: "ArgusMCP",
      dependencies: [
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "SwiftOpenAI", package: "SwiftOpenAI"),
      ]
    ),
    .executableTarget(
      name: "ArgusSelect",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
  ]
)
