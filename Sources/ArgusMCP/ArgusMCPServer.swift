import Foundation
import MCP
import SwiftOpenAI

// Type alias to disambiguate Tool types
typealias MCPTool = MCP.Tool

// MARK: - Model Configuration

/// Default model for video analysis - change this to swap models globally
public let defaultVisionModel = "gpt-4o-mini"

// MARK: - Session Cleanup

/// Kills orphan argus processes running status/select subcommands to ensure fresh recording state.
/// This is called at the start of each tool handler to prevent state corruption from
/// incomplete previous operations.
func cleanupOrphanProcesses() {
  // With single binary architecture, we kill argus processes running status/select subcommands
  // Use pkill with -f to match command line arguments
  let patterns = ["argus status", "argus select"]

  for pattern in patterns {
    let killProcess = Process()
    killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    killProcess.arguments = ["-9", "-f", pattern]  // SIGKILL with full command line match

    // Redirect stderr to null to suppress "no matching processes" errors
    killProcess.standardError = FileHandle.nullDevice
    killProcess.standardOutput = FileHandle.nullDevice

    do {
      try killProcess.run()
      killProcess.waitUntilExit()  // Blocking - ensures cleanup completes before continuing
    } catch {
      // Silently ignore errors (process may not exist, which is fine)
    }
  }
}

// MARK: - MCP Server Entry Point

/// Main entry point for the MCP server
/// Called by MCPCommand subcommand
public func runMCPServer() async throws {
  // Get API key from environment
  guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
    FileHandle.standardError.write("Error: OPENAI_API_KEY environment variable not set\n".data(using: .utf8)!)
    throw ToolError.invalidArgument("OPENAI_API_KEY environment variable not set")
  }

  // Initialize FFmpeg processor (validates ffmpeg is available)
  let ffmpegProcessor: FFmpegProcessor
  do {
    ffmpegProcessor = try await FFmpegProcessor()
  } catch {
    FileHandle.standardError.write("Warning: FFmpeg not available: \(error.localizedDescription)\n".data(using: .utf8)!)
    throw error
  }

  let simpleAnalyzer = SimpleVideoAnalyzer(apiKey: apiKey)
  let codeGenAnalyzer = CodeGenAnalyzer(apiKey: apiKey)

  // Define tools with Value-based input schemas
  //
  // TODO: Re-add recording tools once screen capture is reimplemented
  // The CLI commands (argus select, argus status) still exist for UI.
  // Need to implement:
  //   - record_and_analyze: Full screen recording + analysis
  //   - select_record_and_analyze: Region selection + recording + analysis
  // These tools should use screencapture CLI or AVFoundation to record,
  // then pipe the video through analyze_video or design_from_video.
  //
  let tools: [MCPTool] = [
    // Tool 1: analyze_video - Simple video description
    MCPTool(
      name: "analyze_video",
      description: """
        Analyze a video file for detailed visual descriptions of UI content, animations, and design elements.
        Use to document recorded interactions, describe animation sequences, or get frame-by-frame visual analysis.
        Supports MP4, MOV, and other common formats.
        Cost: ~$0.001-0.003 per video.
        """,
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "video_path": .object([
            "type": "string",
            "description": "Absolute path to the video file to analyze"
          ]),
          "custom_prompt": .object([
            "type": "string",
            "description": "Optional custom system prompt for analysis"
          ])
        ]),
        "required": .array(["video_path"])
      ])
    ),

    // Tool 2: design_from_video - Extract design specifications from video
    MCPTool(
      name: "design_from_video",
      description: """
        Extract UI/animation design specifications from a screen recording.
        Analyzes timing, curves, choreography, and element behaviors.

        Returns a structured specification describing WHAT the animation does
        (not how to implement it), enabling implementation in any framework.

        Two modes:
        - 'quick': Fast analysis (~$0.003) - Good for simple transitions
        - 'high_detail': Detailed analysis (~$0.01) - Better for complex animations
        """,
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "video_path": .object([
            "type": "string",
            "description": "Absolute path to the video file to analyze"
          ]),
          "mode": .object([
            "type": "string",
            "description": "Analysis mode: 'quick' (~$0.003) or 'high_detail' (~$0.01)",
            "enum": .array(["quick", "high_detail"])
          ]),
          "focus_hint": .object([
            "type": "string",
            "description": "Optional hint about which element to focus on (e.g., 'the blue button')"
          ])
        ]),
        "required": .array(["video_path", "mode"])
      ])
    ),

  ]

  // Create server with tool capabilities
  let server = Server(
    name: "argus",
    version: "2.1.0",
    capabilities: Server.Capabilities(tools: .init())
  )

  // Register tool list handler
  await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: tools)
  }

  // Register tool call handler
  await server.withMethodHandler(CallTool.self) { params in
    do {
      let result = try await handleToolCall(
        name: params.name,
        arguments: params.arguments ?? [:],
        ffmpegProcessor: ffmpegProcessor,
        simpleAnalyzer: simpleAnalyzer,
        codeGenAnalyzer: codeGenAnalyzer
      )
      return CallTool.Result(content: [.text(result)])
    } catch {
      return CallTool.Result(
        content: [.text("Error: \(error.localizedDescription)")],
        isError: true
      )
    }
  }

  // Start server with stdio transport
  let transport = StdioTransport()
  try await server.start(transport: transport)

  // Keep server running
  await server.waitUntilCompleted()
}

// MARK: - Tool Call Handler

func handleToolCall(
  name: String,
  arguments: [String: Value],
  ffmpegProcessor: FFmpegProcessor,
  simpleAnalyzer: SimpleVideoAnalyzer,
  codeGenAnalyzer: CodeGenAnalyzer
) async throws -> String {
  switch name {
  case "analyze_video":
    return try await handleAnalyzeVideo(
      arguments: arguments,
      ffmpegProcessor: ffmpegProcessor,
      simpleAnalyzer: simpleAnalyzer
    )

  case "design_from_video":
    return try await handleDesignFromVideo(
      arguments: arguments,
      ffmpegProcessor: ffmpegProcessor,
      codeGenAnalyzer: codeGenAnalyzer
    )

  default:
    throw ToolError.unknownTool(name)
  }
}

// MARK: - Individual Tool Handlers

/// Handle analyze_video tool - simple video description
func handleAnalyzeVideo(
  arguments: [String: Value],
  ffmpegProcessor: FFmpegProcessor,
  simpleAnalyzer: SimpleVideoAnalyzer
) async throws -> String {
  cleanupOrphanProcesses()

  guard let videoPath = arguments["video_path"]?.stringValue else {
    throw ToolError.missingArgument("video_path")
  }

  let url = URL(fileURLWithPath: videoPath)

  // Check if file exists
  guard FileManager.default.fileExists(atPath: videoPath) else {
    throw ToolError.fileNotFound(videoPath)
  }

  // Get video metadata
  let metadata = try await ffmpegProcessor.getMetadata(from: url)

  // Validate video
  try await ffmpegProcessor.validate(metadata, maxDuration: 120)

  // Create sampling plan (simple mode: 1 FPS)
  let plan = FrameSampler.createPlan(duration: metadata.duration, mode: .simple)

  // Extract frames using FFmpeg
  let extractionResult = try await ffmpegProcessor.extractFrames(
    from: url,
    at: plan.timestamps,
    config: .simple
  )

  // Configure analyzer
  var config = SimpleVideoAnalyzer.Config.default
  if let customPrompt = arguments["custom_prompt"]?.stringValue {
    config = SimpleVideoAnalyzer.Config(
      model: defaultVisionModel,
      systemPrompt: customPrompt
    )
  }

  // Analyze
  let analysisResult = try await simpleAnalyzer.analyze(
    frames: extractionResult.frames,
    config: config
  )

  // Cleanup temp files
  await ffmpegProcessor.cleanup(extractionResult)

  // Format result
  return formatSimpleAnalysisResult(
    metadata: metadata,
    extraction: extractionResult,
    analysis: analysisResult
  )
}

/// Handle design_from_video tool - extract design specifications from video
func handleDesignFromVideo(
  arguments: [String: Value],
  ffmpegProcessor: FFmpegProcessor,
  codeGenAnalyzer: CodeGenAnalyzer
) async throws -> String {
  cleanupOrphanProcesses()

  guard let videoPath = arguments["video_path"]?.stringValue else {
    throw ToolError.missingArgument("video_path")
  }

  guard let modeString = arguments["mode"]?.stringValue else {
    throw ToolError.missingArgument("mode")
  }

  let url = URL(fileURLWithPath: videoPath)

  // Check if file exists
  guard FileManager.default.fileExists(atPath: videoPath) else {
    throw ToolError.fileNotFound(videoPath)
  }

  // Parse mode
  let mode: CodeGenAnalyzer.Mode = modeString == "high_detail" ? .highDetail : .quick

  // Get video metadata
  let metadata = try await ffmpegProcessor.getMetadata(from: url)

  // Validate video
  try await ffmpegProcessor.validate(metadata, maxDuration: 120)

  // Create sampling plan
  let plan = FrameSampler.createPlan(duration: metadata.duration, mode: mode.samplerMode)

  // Extract frames using FFmpeg
  let extractionConfig: FFmpegProcessor.ExtractionConfig = mode == .quick ? .quick : .highDetail
  let extractionResult = try await ffmpegProcessor.extractFrames(
    from: url,
    at: plan.timestamps,
    config: extractionConfig
  )

  // Configure analyzer
  let config = CodeGenAnalyzer.Config(
    mode: mode,
    model: defaultVisionModel,
    focusHint: arguments["focus_hint"]?.stringValue
  )

  // Create cost tracker
  let costTracker = CostTracker(limits: mode.costLimits)
  try await costTracker.recordFrames(extractionResult.frames.count)

  // Perform two-pass analysis
  let analysisResult = try await codeGenAnalyzer.analyze(
    frames: extractionResult.frames,
    plan: plan,
    config: config,
    costTracker: costTracker
  )

  // Get cost breakdown
  let costBreakdown = await costTracker.finalize()

  // Cleanup temp files
  await ffmpegProcessor.cleanup(extractionResult)

  // Format result - design specification only, no code generation
  return formatDesignResult(
    metadata: metadata,
    featureSummary: analysisResult.featureSummary,
    timeline: analysisResult.timeline,
    animationSpec: analysisResult.animationSpec,
    costBreakdown: costBreakdown,
    analysisTime: analysisResult.analysisTime
  )
}

// MARK: - Helper Functions

/// Format simple analysis result for analyze_video tool
func formatSimpleAnalysisResult(
  metadata: FFmpegProcessor.VideoMetadata,
  extraction: FFmpegProcessor.ExtractionResult,
  analysis: SimpleVideoAnalyzer.AnalysisResult
) -> String {
  return """
    ## Video Analysis Results

    ### Video Information
    - Duration: \(String(format: "%.1f", metadata.duration)) seconds
    - Resolution: \(metadata.resolution)
    - FPS: \(String(format: "%.1f", metadata.fps))
    - Codec: \(metadata.codec)

    ### Analysis Statistics
    - Frames Analyzed: \(analysis.frameCount)
    - Batches Processed: \(analysis.batchResults.count)
    - Tokens: \(analysis.totalTokensUsed) total (\(analysis.totalPromptTokens) input / \(analysis.totalCompletionTokens) output)
    - Extraction Time: \(String(format: "%.2f", extraction.extractionTime)) seconds
    - Analysis Time: \(String(format: "%.2f", analysis.analysisTime)) seconds

    ### Summary
    \(analysis.summary)

    ### Detailed Frame Analysis
    \(analysis.batchResults.map { batch in
      """
      **[\(String(format: "%.1f", batch.timestampRange.lowerBound))s - \(String(format: "%.1f", batch.timestampRange.upperBound))s]**
      \(batch.analysis)
      """
    }.joined(separator: "\n\n"))
    """
}

/// Format design specification result for design_from_video tool
func formatDesignResult(
  metadata: FFmpegProcessor.VideoMetadata,
  featureSummary: String,
  timeline: [TimelineEvent],
  animationSpec: AnimationSpec,
  costBreakdown: CostTracker.CostBreakdown,
  analysisTime: Double
) -> String {
  // Encode animation specs to JSON for display
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let specsJSON = (try? encoder.encode(animationSpec))
    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

  // Build elements description
  let elementsDescription = animationSpec.elements.map { element in
    let properties = describeElementAnimation(element)
    return "- **\(element.id)** (\(element.type.rawValue)): \(properties)"
  }.joined(separator: "\n")

  return """
    ## Design Specification

    ### Video Information
    - Duration: \(String(format: "%.1f", metadata.duration)) seconds
    - Resolution: \(metadata.resolution)

    ### What This Animation Does
    \(featureSummary)

    ### Elements
    \(elementsDescription)

    ### Timeline
    \(timeline.map { event in
      "- **[\(String(format: "%.2f", event.timestamp))s]** \(event.description)"
    }.joined(separator: "\n"))

    ### Animation Spec (JSON)
    ```json
    \(specsJSON)
    ```

    ### Analysis Stats
    - Frames Analyzed: \(costBreakdown.framesExtracted)
    - Vision Calls: \(costBreakdown.visionCallsMade)
    - Estimated Cost: \(costBreakdown.formattedCost)
    - Analysis Time: \(String(format: "%.2f", analysisTime)) seconds
    """
}

/// Describe what an element's animation does in natural language
private func describeElementAnimation(_ element: AnimatedElement) -> String {
  var descriptions: [String] = []

  guard let first = element.keyframes.first, let last = element.keyframes.last else {
    return "static"
  }

  // Opacity changes
  if let startOpacity = first.opacity, let endOpacity = last.opacity, startOpacity != endOpacity {
    if startOpacity < endOpacity {
      descriptions.append("fades in (\(Int(startOpacity * 100))% → \(Int(endOpacity * 100))%)")
    } else {
      descriptions.append("fades out (\(Int(startOpacity * 100))% → \(Int(endOpacity * 100))%)")
    }
  }

  // Scale changes
  if let startScale = first.scale, let endScale = last.scale, startScale != endScale {
    if startScale < endScale {
      descriptions.append("scales up (\(String(format: "%.1f", startScale))x → \(String(format: "%.1f", endScale))x)")
    } else {
      descriptions.append("scales down (\(String(format: "%.1f", startScale))x → \(String(format: "%.1f", endScale))x)")
    }
  }

  // Position changes
  if let startX = first.x, let endX = last.x, let startY = first.y, let endY = last.y {
    let deltaX = endX - startX
    let deltaY = endY - startY
    if abs(deltaX) > 0.05 || abs(deltaY) > 0.05 {
      var direction: [String] = []
      if deltaX > 0.05 { direction.append("right") }
      else if deltaX < -0.05 { direction.append("left") }
      if deltaY > 0.05 { direction.append("down") }
      else if deltaY < -0.05 { direction.append("up") }
      if !direction.isEmpty {
        descriptions.append("moves \(direction.joined(separator: " and "))")
      }
    }
  }

  // Rotation changes
  if let startRot = first.rotation, let endRot = last.rotation, startRot != endRot {
    descriptions.append("rotates \(Int(endRot - startRot))°")
  }

  // Curve info
  if let curve = last.curve {
    switch curve {
    case .spring:
      descriptions.append("with spring")
    case .easeOut:
      descriptions.append("with ease-out")
    case .easeIn:
      descriptions.append("with ease-in")
    default:
      break
    }
  }

  return descriptions.isEmpty ? "animates" : descriptions.joined(separator: ", ")
}

// MARK: - Setup Command

/// Configures Claude Code to use Argus MCP server
func runSetup() throws {
  let claudeConfigPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude.json")

  // Get the path to this executable
  let executablePath = ProcessInfo.processInfo.arguments[0]
  let resolvedPath: String

  // Resolve to absolute path if needed
  if executablePath.hasPrefix("/") {
    resolvedPath = executablePath
  } else {
    let currentDir = FileManager.default.currentDirectoryPath
    resolvedPath = (currentDir as NSString).appendingPathComponent(executablePath)
  }

  print("Argus MCP Setup")
  print("===============")
  print("")
  print("Executable path: \(resolvedPath)")
  print("Claude config: \(claudeConfigPath.path)")
  print("")

  // Check if config exists
  var config: [String: Any] = [:]
  if FileManager.default.fileExists(atPath: claudeConfigPath.path) {
    if let data = try? Data(contentsOf: claudeConfigPath),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      config = json
      print("Found existing ~/.claude.json")
    }
  } else {
    print("No existing ~/.claude.json found, will create one")
  }

  // Get or create mcpServers
  var mcpServers = config["mcpServers"] as? [String: Any] ?? [:]

  // Check if argus already configured
  if mcpServers["argus"] != nil {
    print("")
    print("Argus is already configured in ~/.claude.json")
    print("Current configuration will be updated.")
  }

  // Create argus config
  let argusConfig: [String: Any] = [
    "type": "stdio",
    "command": resolvedPath,
    "env": [
      "OPENAI_API_KEY": ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "YOUR_OPENAI_API_KEY"
    ]
  ]

  mcpServers["argus"] = argusConfig
  config["mcpServers"] = mcpServers

  // Write config
  let jsonData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
  try jsonData.write(to: claudeConfigPath)

  print("")
  print("Configuration written to ~/.claude.json")
  print("")

  // Check API key
  if ProcessInfo.processInfo.environment["OPENAI_API_KEY"] == nil {
    print("WARNING: OPENAI_API_KEY environment variable not set!")
    print("")
    print("You need to edit ~/.claude.json and replace YOUR_OPENAI_API_KEY")
    print("with your actual OpenAI API key.")
    print("")
    print("Get your API key at: https://platform.openai.com/api-keys")
  } else {
    print("OpenAI API key detected from environment.")
  }

  print("")
  print("Setup complete! Restart Claude Code to use Argus.")
  print("")
  print("Available tools:")
  print("  - analyze_video: Analyze existing video file")
  print("  - design_from_video: Extract animation/UI design specs")
  // TODO: Re-enable recording tools once screen capture is reimplemented
  // print("  - record_and_analyze: Record screen and analyze")
  // print("  - select_record_and_analyze: Record selected region")
}

// MARK: - Errors

enum ToolError: Error, LocalizedError {
  case unknownTool(String)
  case missingArgument(String)
  case fileNotFound(String)
  case invalidArgument(String)

  var errorDescription: String? {
    switch self {
    case .unknownTool(let name):
      return "Unknown tool: \(name)"
    case .missingArgument(let arg):
      return "Missing required argument: \(arg)"
    case .fileNotFound(let path):
      return "File not found: \(path)"
    case .invalidArgument(let msg):
      return "Invalid argument: \(msg)"
    }
  }
}
