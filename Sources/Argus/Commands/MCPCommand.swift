import ArgumentParser
import ArgusMCP
import Foundation

// MARK: - MCP Command

struct MCPCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mcp",
    abstract: "Start the MCP server for video analysis"
  )

  mutating func run() async throws {
    // Call the main MCP server logic
    try await runMCPServer()
  }
}
