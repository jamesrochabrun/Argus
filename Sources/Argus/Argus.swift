import ArgumentParser
import Foundation

@main
struct Argus: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "argus",
    abstract: "Video analysis MCP server for Claude Code",
    version: "1.1.0",
    subcommands: [
      MCPCommand.self,
      StatusCommand.self,
      SelectCommand.self,
    ],
    defaultSubcommand: MCPCommand.self
  )

  @Flag(name: .long, help: "Configure Claude Code to use Argus")
  var setup = false

  mutating func run() async throws {
    if setup {
      try runSetup()
    }
  }
}

// MARK: - Setup Command

/// Configures Claude Code to use Argus MCP server
func runSetup() throws {
  let claudeConfigPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude.json")

  // Get the path to this executable
  let executablePath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments[0]

  // Read existing config or create new one
  var config: [String: Any] = [:]
  if FileManager.default.fileExists(atPath: claudeConfigPath.path) {
    let data = try Data(contentsOf: claudeConfigPath)
    if let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
      config = existing
    }
  }

  // Get or create mcpServers section
  var mcpServers = config["mcpServers"] as? [String: Any] ?? [:]

  // Check for OPENAI_API_KEY
  let openAIKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]

  // Create argus server config
  var argusConfig: [String: Any] = [
    "type": "stdio",
    "command": executablePath,
    "args": ["mcp"],
  ]

  if let key = openAIKey {
    argusConfig["env"] = ["OPENAI_API_KEY": key]
  }

  mcpServers["argus"] = argusConfig
  config["mcpServers"] = mcpServers

  // Write back
  let outputData = try JSONSerialization.data(
    withJSONObject: config,
    options: [.prettyPrinted, .sortedKeys]
  )
  try outputData.write(to: claudeConfigPath)

  print("Argus MCP server configured in ~/.claude.json")
  print("Executable: \(executablePath)")
  if openAIKey == nil {
    print("\nNote: OPENAI_API_KEY not found in environment.")
    print("You'll need to add it manually to ~/.claude.json")
  }
  print("\nRestart Claude Code to use Argus.")
}
