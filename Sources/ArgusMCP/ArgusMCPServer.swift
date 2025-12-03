import ArgumentParser
import Foundation
import MCP
import SwiftOpenAI

// Type alias to disambiguate Tool types
typealias MCPTool = MCP.Tool

@main
struct ArgusMCPServer: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "argus-mcp",
    abstract: "MCP server for video analysis using OpenAI Vision API",
    version: "1.0.0"
  )

  mutating func run() async throws {
    // Get API key from environment
    guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
      FileHandle.standardError.write("Error: OPENAI_API_KEY environment variable not set\n".data(using: .utf8)!)
      throw ExitCode.failure
    }

    let frameExtractor = VideoFrameExtractor()
    let videoAnalyzer = VideoAnalyzer(apiKey: apiKey)
    let screenRecorder = ScreenRecorder()

    // Define tools with Value-based input schemas
    let tools: [MCPTool] = [
      MCPTool(
        name: "analyze_video",
        description: """
          Analyze a video file by extracting frames and sending them to OpenAI's Vision API.
          Returns a detailed description of the video content including key moments, UI elements,
          text, and transitions. Supports various video formats (MP4, MOV, AVI, etc.).
          """,
        inputSchema: .object([
          "type": "object",
          "properties": .object([
            "video_path": .object([
              "type": "string",
              "description": "Absolute path to the video file to analyze"
            ]),
            "frames_per_second": .object([
              "type": "number",
              "description": "Number of frames to extract per second (default: 1.0)"
            ]),
            "max_frames": .object([
              "type": "integer",
              "description": "Maximum number of frames to extract (default: 30)"
            ]),
            "mode": .object([
              "type": "string",
              "description": """
                Analysis mode based on intent:
                - 'quick_look': Fast overview of video content (15 frames, 0.5fps)
                - 'explain': Detailed explanation of what happens (30 frames, 1fps)
                - 'test_animation': Frame-by-frame animation analysis for QA testing (180 frames, 60fps)
                - 'find_bugs': Look for visual glitches, stutters, UI issues (60 frames, 2fps)
                - 'accessibility': Check text readability, contrast, UI elements (30 frames, 1fps, high detail)
                - 'compare_frames': Detailed pixel-level comparison between frames (120 frames, 30fps)
                """,
              "enum": .array(["quick_look", "explain", "test_animation", "find_bugs", "accessibility", "compare_frames"])
            ]),
            "custom_prompt": .object([
              "type": "string",
              "description": "Optional custom system prompt for analysis"
            ])
          ]),
          "required": .array(["video_path"])
        ])
      ),

      MCPTool(
        name: "start_screen_recording",
        description: """
          Start recording the screen using ScreenCaptureKit.
          Records the main display by default. Returns the path where the recording will be saved.
          Use stop_screen_recording to stop and finalize the recording.
          """,
        inputSchema: .object([
          "type": "object",
          "properties": .object([
            "output_path": .object([
              "type": "string",
              "description": "Optional path for the output video file"
            ]),
            "width": .object([
              "type": "integer",
              "description": "Recording width in pixels (default: 1920)"
            ]),
            "height": .object([
              "type": "integer",
              "description": "Recording height in pixels (default: 1080)"
            ]),
            "fps": .object([
              "type": "integer",
              "description": "Frames per second (default: 30)"
            ]),
            "quality": .object([
              "type": "string",
              "description": "Recording quality: 'low', 'medium', or 'high'",
              "enum": .array(["low", "medium", "high"])
            ])
          ]),
          "required": .array([])
        ])
      ),

      MCPTool(
        name: "stop_screen_recording",
        description: "Stop the current screen recording and return the path to the saved video file.",
        inputSchema: .object([
          "type": "object",
          "properties": .object([:]),
          "required": .array([])
        ])
      ),

      MCPTool(
        name: "list_displays",
        description: "List all available displays for screen recording.",
        inputSchema: .object([
          "type": "object",
          "properties": .object([:]),
          "required": .array([])
        ])
      ),

      MCPTool(
        name: "list_windows",
        description: "List all available windows for screen recording.",
        inputSchema: .object([
          "type": "object",
          "properties": .object([:]),
          "required": .array([])
        ])
      ),

      MCPTool(
        name: "record_and_analyze",
        description: """
          Start a screen recording, wait for the specified duration, stop recording,
          and automatically analyze the recorded video. This is a convenience tool that
          combines screen recording and video analysis into a single operation.
          """,
        inputSchema: .object([
          "type": "object",
          "properties": .object([
            "duration_seconds": .object([
              "type": "integer",
              "description": "Duration to record in seconds (required)"
            ]),
            "analysis_quality": .object([
              "type": "string",
              "description": "Analysis quality: 'fast', 'default', or 'detailed'",
              "enum": .array(["fast", "default", "detailed"])
            ]),
            "custom_prompt": .object([
              "type": "string",
              "description": "Optional custom system prompt for analysis"
            ])
          ]),
          "required": .array(["duration_seconds"])
        ])
      ),

      MCPTool(
        name: "record_app",
        description: """
          Record a specific application window by name (e.g., 'Simulator', 'Safari', 'Chrome').
          This captures only that app's window, not the entire screen.
          Use stop_screen_recording to stop.
          """,
        inputSchema: .object([
          "type": "object",
          "properties": .object([
            "app_name": .object([
              "type": "string",
              "description": "Name of the application to record (e.g., 'Simulator', 'Safari')"
            ]),
            "fps": .object([
              "type": "integer",
              "description": "Frames per second (default: 60 for animations, 30 for general use)"
            ]),
            "output_path": .object([
              "type": "string",
              "description": "Optional path for the output video file"
            ])
          ]),
          "required": .array(["app_name"])
        ])
      ),

      MCPTool(
        name: "record_simulator",
        description: """
          Record the iOS Simulator window. Optimized for capturing animations at 60fps.
          Perfect for testing UI animations, transitions, and interactions.
          Use stop_screen_recording to stop.
          """,
        inputSchema: .object([
          "type": "object",
          "properties": .object([
            "fps": .object([
              "type": "integer",
              "description": "Frames per second (default: 60)"
            ]),
            "duration_seconds": .object([
              "type": "integer",
              "description": "Optional: Auto-stop after this many seconds"
            ]),
            "output_path": .object([
              "type": "string",
              "description": "Optional path for the output video file"
            ])
          ]),
          "required": .array([])
        ])
      ),

      MCPTool(
        name: "record_simulator_and_analyze",
        description: """
          Record the iOS Simulator for a specified duration and automatically analyze
          the animation/UI. Perfect for QA testing animations and transitions.
          """,
        inputSchema: .object([
          "type": "object",
          "properties": .object([
            "duration_seconds": .object([
              "type": "integer",
              "description": "Duration to record in seconds"
            ]),
            "mode": .object([
              "type": "string",
              "description": "Analysis mode: 'test_animation', 'find_bugs', 'accessibility', 'explain'",
              "enum": .array(["test_animation", "find_bugs", "accessibility", "explain"])
            ]),
            "custom_prompt": .object([
              "type": "string",
              "description": "Optional custom analysis prompt"
            ])
          ]),
          "required": .array(["duration_seconds"])
        ])
      )
    ]

    // Create server with tool capabilities
    let server = Server(
      name: "argus-mcp",
      version: "1.0.0",
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
          frameExtractor: frameExtractor,
          videoAnalyzer: videoAnalyzer,
          screenRecorder: screenRecorder
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
}

// MARK: - Tool Call Handler

func handleToolCall(
  name: String,
  arguments: [String: Value],
  frameExtractor: VideoFrameExtractor,
  videoAnalyzer: VideoAnalyzer,
  screenRecorder: ScreenRecorder
) async throws -> String {
  switch name {
  case "analyze_video":
    return try await handleAnalyzeVideo(
      arguments: arguments,
      frameExtractor: frameExtractor,
      videoAnalyzer: videoAnalyzer
    )

  case "start_screen_recording":
    return try await handleStartRecording(
      arguments: arguments,
      screenRecorder: screenRecorder
    )

  case "stop_screen_recording":
    return try await handleStopRecording(screenRecorder: screenRecorder)

  case "list_displays":
    return try await handleListDisplays(screenRecorder: screenRecorder)

  case "list_windows":
    return try await handleListWindows(screenRecorder: screenRecorder)

  case "record_and_analyze":
    return try await handleRecordAndAnalyze(
      arguments: arguments,
      frameExtractor: frameExtractor,
      videoAnalyzer: videoAnalyzer,
      screenRecorder: screenRecorder
    )

  case "record_app":
    return try await handleRecordApp(
      arguments: arguments,
      screenRecorder: screenRecorder
    )

  case "record_simulator":
    return try await handleRecordSimulator(
      arguments: arguments,
      screenRecorder: screenRecorder
    )

  case "record_simulator_and_analyze":
    return try await handleRecordSimulatorAndAnalyze(
      arguments: arguments,
      frameExtractor: frameExtractor,
      videoAnalyzer: videoAnalyzer,
      screenRecorder: screenRecorder
    )

  default:
    throw ToolError.unknownTool(name)
  }
}

// MARK: - Individual Tool Handlers

func handleAnalyzeVideo(
  arguments: [String: Value],
  frameExtractor: VideoFrameExtractor,
  videoAnalyzer: VideoAnalyzer
) async throws -> String {
  guard let videoPath = arguments["video_path"]?.stringValue else {
    throw ToolError.missingArgument("video_path")
  }

  let url = URL(fileURLWithPath: videoPath)

  // Check if file exists
  guard FileManager.default.fileExists(atPath: videoPath) else {
    throw ToolError.fileNotFound(videoPath)
  }

  // Parse extraction config
  var framesPerSecond = 1.0
  var maxFrames = 30
  var targetWidth = 1024
  var compressionQuality = 0.8

  if let fps = arguments["frames_per_second"]?.doubleValue {
    framesPerSecond = fps
  }

  if let max = arguments["max_frames"]?.intValue {
    maxFrames = max
  }

  // Parse analysis config based on mode
  var analysisConfig: VideoAnalyzer.AnalysisConfig = .default

  if let mode = arguments["mode"]?.stringValue {
    switch mode {
    case "quick_look":
      analysisConfig = VideoAnalyzer.AnalysisConfig(
        batchSize: 8,
        model: "gpt-4o-mini",
        maxTokensPerBatch: 500,
        systemPrompt: "Provide a quick, concise summary of what happens in this video. Focus on the main content and key moments.",
        imageDetail: "low",
        temperature: 0.3
      )
      framesPerSecond = 0.5
      maxFrames = 15
      targetWidth = 512
      compressionQuality = 0.7

    case "explain":
      analysisConfig = VideoAnalyzer.AnalysisConfig(
        batchSize: 5,
        model: "gpt-4o-mini",
        maxTokensPerBatch: 1500,
        systemPrompt: """
          Explain in detail what happens in this video. Describe:
          1. The overall content and context
          2. Step-by-step actions and events
          3. Important UI elements, text, and visual information
          4. The purpose and outcome of what's shown
          Be thorough and educational in your explanation.
          """,
        imageDetail: "auto",
        temperature: 0.3
      )
      framesPerSecond = 1.0
      maxFrames = 30
      targetWidth = 1024
      compressionQuality = 0.8

    case "test_animation":
      analysisConfig = VideoAnalyzer.AnalysisConfig(
        batchSize: 10,
        model: "gpt-4o-mini",
        maxTokensPerBatch: 2000,
        systemPrompt: """
          You are a QA engineer testing UI animations. Analyze these sequential frames and report:
          1. TIMING: Estimate the easing curve (ease-in, ease-out, ease-in-out, linear, spring/bounce)
          2. SMOOTHNESS: Any dropped frames, stutters, or jerky motion?
          3. CONSISTENCY: Does the animation maintain consistent speed/acceleration?
          4. START/END STATES: Are initial and final positions correct?
          5. ISSUES: Any visual glitches, clipping, z-index problems, or artifacts?
          Be precise with frame numbers and timestamps when reporting issues.
          """,
        imageDetail: "high",
        temperature: 0.1
      )
      framesPerSecond = 60.0
      maxFrames = 180
      targetWidth = 1024
      compressionQuality = 0.75

    case "find_bugs":
      analysisConfig = VideoAnalyzer.AnalysisConfig(
        batchSize: 5,
        model: "gpt-4o-mini",
        maxTokensPerBatch: 1500,
        systemPrompt: """
          You are a QA engineer looking for bugs and issues. Carefully examine each frame for:
          1. VISUAL BUGS: Glitches, artifacts, incorrect rendering, clipping issues
          2. UI ISSUES: Misaligned elements, overlapping content, broken layouts
          3. TEXT PROBLEMS: Truncation, overflow, incorrect formatting, typos
          4. STATE ERRORS: Wrong colors, missing elements, incorrect data
          5. ANIMATION ISSUES: Stutters, jumps, incomplete transitions
          Report each issue with the frame number/timestamp and specific location.
          """,
        imageDetail: "high",
        temperature: 0.1
      )
      framesPerSecond = 2.0
      maxFrames = 60
      targetWidth = 1920
      compressionQuality = 0.9

    case "accessibility":
      analysisConfig = VideoAnalyzer.AnalysisConfig(
        batchSize: 5,
        model: "gpt-4o-mini",
        maxTokensPerBatch: 1500,
        systemPrompt: """
          Evaluate this UI for accessibility concerns:
          1. TEXT: Is text readable? Appropriate size? Sufficient contrast?
          2. COLORS: Are there contrast issues? Color-only indicators?
          3. TOUCH TARGETS: Are interactive elements large enough (44pt minimum)?
          4. LABELS: Are UI elements clearly labeled?
          5. HIERARCHY: Is the visual hierarchy clear?
          6. MOTION: Any animations that could cause issues for motion-sensitive users?
          Provide specific recommendations for improvements.
          """,
        imageDetail: "high",
        temperature: 0.2
      )
      framesPerSecond = 1.0
      maxFrames = 30
      targetWidth = 1920
      compressionQuality = 0.9

    case "compare_frames":
      analysisConfig = VideoAnalyzer.AnalysisConfig(
        batchSize: 6,
        model: "gpt-4o-mini",
        maxTokensPerBatch: 2000,
        systemPrompt: """
          Compare consecutive frames and identify exact differences:
          1. POSITION CHANGES: Which elements moved? By approximately how many pixels?
          2. SIZE CHANGES: Any elements that grew or shrank?
          3. OPACITY/COLOR: Changes in transparency or color values
          4. VISIBILITY: Elements that appeared or disappeared
          5. STATE CHANGES: Buttons, toggles, or other state indicators
          Be as precise as possible with measurements and locations.
          """,
        imageDetail: "high",
        temperature: 0.1
      )
      framesPerSecond = 30.0
      maxFrames = 120
      targetWidth = 1280
      compressionQuality = 0.8

    default:
      break
    }
  }

  let extractionConfig = VideoFrameExtractor.ExtractionConfig(
    framesPerSecond: framesPerSecond,
    maxFrames: maxFrames,
    targetWidth: targetWidth,
    compressionQuality: compressionQuality
  )

  if let customPrompt = arguments["custom_prompt"]?.stringValue {
    analysisConfig = VideoAnalyzer.AnalysisConfig(
      batchSize: analysisConfig.batchSize,
      model: analysisConfig.model,
      maxTokensPerBatch: analysisConfig.maxTokensPerBatch,
      systemPrompt: customPrompt,
      imageDetail: analysisConfig.imageDetail,
      temperature: analysisConfig.temperature
    )
  }

  // Extract frames
  let extractionResult = try await frameExtractor.extractFrames(from: url, config: extractionConfig)

  // Analyze video
  let analysisResult = try await videoAnalyzer.analyze(
    extractionResult: extractionResult,
    config: analysisConfig
  )

  // Format result
  return formatAnalysisResult(extraction: extractionResult, analysis: analysisResult)
}

func handleStartRecording(
  arguments: [String: Value],
  screenRecorder: ScreenRecorder
) async throws -> String {
  var width = 1920
  var height = 1080
  var fps = 30
  var quality: ScreenRecorder.RecordingConfig.Quality = .medium

  if let w = arguments["width"]?.intValue {
    width = w
  }

  if let h = arguments["height"]?.intValue {
    height = h
  }

  if let f = arguments["fps"]?.intValue {
    fps = f
  }

  if let qualityStr = arguments["quality"]?.stringValue,
     let q = ScreenRecorder.RecordingConfig.Quality(rawValue: qualityStr)
  {
    quality = q
  }

  let config = ScreenRecorder.RecordingConfig(
    width: width,
    height: height,
    fps: fps,
    showsCursor: true,
    capturesAudio: false,
    quality: quality
  )

  var outputPath: String?
  if let path = arguments["output_path"]?.stringValue {
    outputPath = path
  }

  let url = try await screenRecorder.startRecording(config: config, outputPath: outputPath)

  return """
    Screen recording started successfully.
    Output file: \(url.path)
    Resolution: \(config.width)x\(config.height)
    FPS: \(config.fps)
    Quality: \(config.quality.rawValue)

    Use 'stop_screen_recording' to stop and save the recording.
    """
}

func handleStopRecording(screenRecorder: ScreenRecorder) async throws -> String {
  let url = try await screenRecorder.stopRecording()

  // Get file size
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  let fileSize = attributes[.size] as? Int64 ?? 0
  let fileSizeMB = Double(fileSize) / 1_000_000.0

  return """
    Screen recording stopped and saved successfully.
    Output file: \(url.path)
    File size: \(String(format: "%.2f", fileSizeMB)) MB

    You can now use 'analyze_video' with this path to analyze the recording.
    """
}

func handleListDisplays(screenRecorder: ScreenRecorder) async throws -> String {
  let displays = try await screenRecorder.getAvailableDisplays()

  var result = "Available Displays:\n"
  for (index, display) in displays.enumerated() {
    result += """
      \(index + 1). Display ID: \(display.displayID)
         Resolution: \(display.width)x\(display.height)
         Main Display: \(display.isMain ? "Yes" : "No")

      """
  }

  return result
}

func handleListWindows(screenRecorder: ScreenRecorder) async throws -> String {
  let windows = try await screenRecorder.getAvailableWindows()

  var result = "Available Windows:\n"
  for (index, window) in windows.prefix(20).enumerated() {
    let title = window.title ?? "Untitled"
    let owner = window.ownerName ?? "Unknown"
    result += """
      \(index + 1). Window ID: \(window.windowID)
         Title: \(title)
         Application: \(owner)
         Size: \(Int(window.frame.width))x\(Int(window.frame.height))

      """
  }

  if windows.count > 20 {
    result += "... and \(windows.count - 20) more windows\n"
  }

  return result
}

func handleRecordAndAnalyze(
  arguments: [String: Value],
  frameExtractor: VideoFrameExtractor,
  videoAnalyzer: VideoAnalyzer,
  screenRecorder: ScreenRecorder
) async throws -> String {
  guard let durationSeconds = arguments["duration_seconds"]?.intValue else {
    throw ToolError.missingArgument("duration_seconds")
  }

  // Start recording
  _ = try await screenRecorder.startRecording()

  // Wait for the specified duration
  try await Task.sleep(for: .seconds(durationSeconds))

  // Stop recording
  let videoURL = try await screenRecorder.stopRecording()

  // Prepare analysis config
  var analysisConfig: VideoAnalyzer.AnalysisConfig = .default
  var extractionConfig: VideoFrameExtractor.ExtractionConfig = .default

  if let quality = arguments["analysis_quality"]?.stringValue {
    switch quality {
    case "fast":
      analysisConfig = .fast
      extractionConfig = .fast
    case "detailed":
      analysisConfig = .detailed
      extractionConfig = .highQuality
    default:
      break
    }
  }

  if let customPrompt = arguments["custom_prompt"]?.stringValue {
    analysisConfig = VideoAnalyzer.AnalysisConfig(
      batchSize: analysisConfig.batchSize,
      model: analysisConfig.model,
      maxTokensPerBatch: analysisConfig.maxTokensPerBatch,
      systemPrompt: customPrompt,
      imageDetail: analysisConfig.imageDetail,
      temperature: analysisConfig.temperature
    )
  }

  // Extract and analyze
  let extractionResult = try await frameExtractor.extractFrames(from: videoURL, config: extractionConfig)
  let analysisResult = try await videoAnalyzer.analyze(
    extractionResult: extractionResult,
    config: analysisConfig
  )

  return """
    Recording completed and analyzed.
    Video file: \(videoURL.path)
    Duration: \(durationSeconds) seconds

    \(formatAnalysisResult(extraction: extractionResult, analysis: analysisResult))
    """
}

// MARK: - App Recording Handlers

func handleRecordApp(
  arguments: [String: Value],
  screenRecorder: ScreenRecorder
) async throws -> String {
  guard let appName = arguments["app_name"]?.stringValue else {
    throw ToolError.missingArgument("app_name")
  }

  var fps = 60  // Default to 60fps for animations
  if let f = arguments["fps"]?.intValue {
    fps = f
  }

  var outputPath: String?
  if let path = arguments["output_path"]?.stringValue {
    outputPath = path
  }

  let config = ScreenRecorder.RecordingConfig(
    width: 0,  // Will be determined by window size
    height: 0,
    fps: fps,
    showsCursor: true,
    capturesAudio: false,
    quality: .high
  )

  let url = try await screenRecorder.startRecording(
    appName: appName,
    config: config,
    outputPath: outputPath
  )

  return """
    Started recording '\(appName)' window.
    Output file: \(url.path)
    FPS: \(fps)

    Use 'stop_screen_recording' to stop and save the recording.
    """
}

func handleRecordSimulator(
  arguments: [String: Value],
  screenRecorder: ScreenRecorder
) async throws -> String {
  var fps = 60  // Default to 60fps for simulator animations
  if let f = arguments["fps"]?.intValue {
    fps = f
  }

  var outputPath: String?
  if let path = arguments["output_path"]?.stringValue {
    outputPath = path
  }

  let config = ScreenRecorder.RecordingConfig(
    width: 0,
    height: 0,
    fps: fps,
    showsCursor: false,  // Hide cursor for simulator recordings
    capturesAudio: false,
    quality: .high
  )

  // Find and record the Simulator window
  let url = try await screenRecorder.startRecording(
    appName: "Simulator",
    config: config,
    outputPath: outputPath
  )

  // Handle optional auto-stop duration
  if let durationSeconds = arguments["duration_seconds"]?.intValue {
    // Schedule auto-stop
    Task {
      try await Task.sleep(for: .seconds(durationSeconds))
      _ = try? await screenRecorder.stopRecording()
    }

    return """
      Started recording iOS Simulator.
      Output file: \(url.path)
      FPS: \(fps)
      Auto-stop: \(durationSeconds) seconds

      Recording will automatically stop after \(durationSeconds) seconds,
      or use 'stop_screen_recording' to stop early.
      """
  }

  return """
    Started recording iOS Simulator.
    Output file: \(url.path)
    FPS: \(fps)

    Use 'stop_screen_recording' to stop and save the recording.
    """
}

func handleRecordSimulatorAndAnalyze(
  arguments: [String: Value],
  frameExtractor: VideoFrameExtractor,
  videoAnalyzer: VideoAnalyzer,
  screenRecorder: ScreenRecorder
) async throws -> String {
  guard let durationSeconds = arguments["duration_seconds"]?.intValue else {
    throw ToolError.missingArgument("duration_seconds")
  }

  // Configure recording for simulator (60fps for animations)
  let recordingConfig = ScreenRecorder.RecordingConfig(
    width: 0,
    height: 0,
    fps: 60,
    showsCursor: false,
    capturesAudio: false,
    quality: .high
  )

  // Start recording the Simulator
  _ = try await screenRecorder.startRecording(
    appName: "Simulator",
    config: recordingConfig,
    outputPath: nil
  )

  // Wait for the specified duration
  try await Task.sleep(for: .seconds(durationSeconds))

  // Stop recording
  let videoURL = try await screenRecorder.stopRecording()

  // Determine analysis mode
  let mode = arguments["mode"]?.stringValue ?? "test_animation"

  var analysisConfig: VideoAnalyzer.AnalysisConfig
  var framesPerSecond: Double
  var maxFrames: Int
  var targetWidth: Int
  var compressionQuality: Double

  switch mode {
  case "test_animation":
    analysisConfig = VideoAnalyzer.AnalysisConfig(
      batchSize: 10,
      model: "gpt-4o-mini",
      maxTokensPerBatch: 2000,
      systemPrompt: """
        You are a QA engineer testing UI animations in an iOS Simulator. Analyze these sequential frames and report:
        1. TIMING: Estimate the easing curve (ease-in, ease-out, ease-in-out, linear, spring/bounce)
        2. SMOOTHNESS: Any dropped frames, stutters, or jerky motion?
        3. CONSISTENCY: Does the animation maintain consistent speed/acceleration?
        4. START/END STATES: Are initial and final positions correct?
        5. ISSUES: Any visual glitches, clipping, z-index problems, or artifacts?
        Be precise with frame numbers and timestamps when reporting issues.
        """,
      imageDetail: "high",
      temperature: 0.1
    )
    framesPerSecond = 60.0
    maxFrames = min(durationSeconds * 60, 180)
    targetWidth = 1024
    compressionQuality = 0.75

  case "find_bugs":
    analysisConfig = VideoAnalyzer.AnalysisConfig(
      batchSize: 5,
      model: "gpt-4o-mini",
      maxTokensPerBatch: 1500,
      systemPrompt: """
        You are a QA engineer testing an iOS app in the Simulator. Look for bugs and issues:
        1. VISUAL BUGS: Glitches, artifacts, incorrect rendering, clipping issues
        2. UI ISSUES: Misaligned elements, overlapping content, broken layouts
        3. TEXT PROBLEMS: Truncation, overflow, incorrect formatting
        4. STATE ERRORS: Wrong colors, missing elements, incorrect data
        5. ANIMATION ISSUES: Stutters, jumps, incomplete transitions
        Report each issue with the frame number/timestamp and specific location.
        """,
      imageDetail: "high",
      temperature: 0.1
    )
    framesPerSecond = 2.0
    maxFrames = min(durationSeconds * 2, 60)
    targetWidth = 1920
    compressionQuality = 0.9

  case "accessibility":
    analysisConfig = VideoAnalyzer.AnalysisConfig(
      batchSize: 5,
      model: "gpt-4o-mini",
      maxTokensPerBatch: 1500,
      systemPrompt: """
        Evaluate this iOS app UI for accessibility concerns:
        1. TEXT: Is text readable? Appropriate size? Sufficient contrast?
        2. COLORS: Are there contrast issues? Color-only indicators?
        3. TOUCH TARGETS: Are interactive elements large enough (44pt minimum)?
        4. LABELS: Are UI elements clearly labeled?
        5. HIERARCHY: Is the visual hierarchy clear?
        6. MOTION: Any animations that could cause issues for motion-sensitive users?
        Provide specific recommendations for improvements.
        """,
      imageDetail: "high",
      temperature: 0.2
    )
    framesPerSecond = 1.0
    maxFrames = min(durationSeconds, 30)
    targetWidth = 1920
    compressionQuality = 0.9

  default:  // "explain" or unknown
    analysisConfig = VideoAnalyzer.AnalysisConfig(
      batchSize: 5,
      model: "gpt-4o-mini",
      maxTokensPerBatch: 1500,
      systemPrompt: """
        Explain what happens in this iOS Simulator recording. Describe:
        1. The overall content and context of the app
        2. Step-by-step user interactions and responses
        3. Screen transitions and navigation flow
        4. Important UI elements and their states
        Be thorough and descriptive.
        """,
      imageDetail: "auto",
      temperature: 0.3
    )
    framesPerSecond = 1.0
    maxFrames = 30
    targetWidth = 1024
    compressionQuality = 0.8
  }

  // Apply custom prompt if provided
  if let customPrompt = arguments["custom_prompt"]?.stringValue {
    analysisConfig = VideoAnalyzer.AnalysisConfig(
      batchSize: analysisConfig.batchSize,
      model: analysisConfig.model,
      maxTokensPerBatch: analysisConfig.maxTokensPerBatch,
      systemPrompt: customPrompt,
      imageDetail: analysisConfig.imageDetail,
      temperature: analysisConfig.temperature
    )
  }

  let extractionConfig = VideoFrameExtractor.ExtractionConfig(
    framesPerSecond: framesPerSecond,
    maxFrames: maxFrames,
    targetWidth: targetWidth,
    compressionQuality: compressionQuality
  )

  // Extract and analyze
  let extractionResult = try await frameExtractor.extractFrames(from: videoURL, config: extractionConfig)
  let analysisResult = try await videoAnalyzer.analyze(
    extractionResult: extractionResult,
    config: analysisConfig
  )

  return """
    iOS Simulator recording completed and analyzed.
    Video file: \(videoURL.path)
    Duration: \(durationSeconds) seconds
    Analysis mode: \(mode)

    \(formatAnalysisResult(extraction: extractionResult, analysis: analysisResult))
    """
}

// MARK: - Helper Functions

func formatAnalysisResult(
  extraction: VideoFrameExtractor.ExtractionResult,
  analysis: VideoAnalyzer.VideoAnalysisResult
) -> String {
  return """
    ## Video Analysis Results

    ### Video Information
    - Duration: \(String(format: "%.1f", extraction.videoDuration)) seconds
    - Resolution: \(Int(extraction.videoSize.width))x\(Int(extraction.videoSize.height))
    - FPS: \(String(format: "%.1f", extraction.videoFPS))
    - Total Frames: \(extraction.totalFrameCount)

    ### Analysis Statistics
    - Frames Analyzed: \(analysis.frameCount)
    - Batches Processed: \(analysis.batchResults.count)
    - Total Tokens Used: \(analysis.totalTokensUsed)
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
