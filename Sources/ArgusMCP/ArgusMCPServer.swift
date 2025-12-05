import AppKit
import ArgumentParser
import Foundation
import MCP
import SwiftOpenAI

// Type alias to disambiguate Tool types
typealias MCPTool = MCP.Tool

// MARK: - Recording Session State

/// Manages the recording status UI across start/stop calls
@MainActor
final class RecordingSession {
  static let shared = RecordingSession()

  private var statusUI: RecordingStatusUI?
  private var uiEventTask: Task<Void, Never>?

  private init() {}

  /// Start the status UI for a recording session
  func startUI(durationSeconds: Int? = nil, onStopRequested: @escaping () async -> Void) async {
    // Clean up any existing UI
    await stopUI()

    statusUI = RecordingStatusUI()

    do {
      let events = try await statusUI!.launch(config: .init(durationSeconds: durationSeconds))

      // Listen for UI events in background
      uiEventTask = Task {
        for await event in events {
          switch event {
          case .stopClicked, .timeout:
            await onStopRequested()
            return
          case .ready, .processExited:
            break
          }
        }
      }
    } catch {
      FileHandle.standardError.write("Warning: Could not launch recording status UI: \(error)\n".data(using: .utf8)!)
      statusUI = nil
    }
  }

  /// Notify that recording has started (first frame captured)
  func notifyRecordingStarted() async {
    await statusUI?.notifyRecordingStarted()
  }

  /// Stop the status UI
  func stopUI() async {
    uiEventTask?.cancel()
    uiEventTask = nil
    await statusUI?.notifyRecordingStopped()
    statusUI?.terminate()
    statusUI = nil
  }
}

@main
struct ArgusMCPServer: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "argus-mcp",
    abstract: "MCP server for video analysis using OpenAI Vision API",
    version: "1.0.0"
  )

  mutating func run() async throws {
    // Initialize NSApplication to establish window server connection
    // This is required for ScreenCaptureKit to work in a headless context
    await MainActor.run {
      _ = NSApplication.shared
      NSApp.setActivationPolicy(.accessory)  // Run as background app (no dock icon)
    }

    // Get API key from environment
    guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
      FileHandle.standardError.write("Error: OPENAI_API_KEY environment variable not set\n".data(using: .utf8)!)
      throw ExitCode.failure
    }

    let frameExtractor = VideoFrameExtractor()
    let videoAnalyzer = VideoAnalyzer(apiKey: apiKey)
    let screenRecorder = await MainActor.run { ScreenRecorder() }

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
      ),

      MCPTool(
        name: "record_app_and_analyze",
        description: """
          Record a specific application window by name and automatically analyze it with AI.
          Perfect for testing UI, animations, and interactions in any app (Safari, Chrome, etc.).
          """,
        inputSchema: .object([
          "type": "object",
          "properties": .object([
            "app_name": .object([
              "type": "string",
              "description": "Name of the application to record (e.g., 'Safari', 'Chrome', 'Finder')"
            ]),
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
          "required": .array(["app_name", "duration_seconds"])
        ])
      ),

      MCPTool(
        name: "select_record_and_analyze",
        description: """
          Complete workflow: Opens visual selection, records the selected region
          for the specified duration, then analyzes it with OpenAI Vision.
          Perfect for testing specific UI areas or animations.

          Two modes:
          - Timed: Provide duration_seconds for countdown timer that auto-stops
          - Manual: Omit duration_seconds to show elapsed time; user clicks Stop to end (30s max)
          """,
        inputSchema: .object([
          "type": "object",
          "properties": .object([
            "duration_seconds": .object([
              "type": "integer",
              "description": "Duration to record in seconds. If omitted, recording runs until user clicks Stop (30s max)."
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
          ])
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

  case "record_and_analyze":
    return try await handleRecordAndAnalyze(
      arguments: arguments,
      frameExtractor: frameExtractor,
      videoAnalyzer: videoAnalyzer,
      screenRecorder: screenRecorder
    )

  case "record_simulator_and_analyze":
    return try await handleRecordSimulatorAndAnalyze(
      arguments: arguments,
      frameExtractor: frameExtractor,
      videoAnalyzer: videoAnalyzer,
      screenRecorder: screenRecorder
    )

  case "record_app_and_analyze":
    return try await handleRecordAppAndAnalyze(
      arguments: arguments,
      frameExtractor: frameExtractor,
      videoAnalyzer: videoAnalyzer,
      screenRecorder: screenRecorder
    )

  case "select_record_and_analyze":
    return try await handleSelectRecordAndAnalyze(
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

func handleRecordAndAnalyze(
  arguments: [String: Value],
  frameExtractor: VideoFrameExtractor,
  videoAnalyzer: VideoAnalyzer,
  screenRecorder: ScreenRecorder
) async throws -> String {
  guard let durationSeconds = arguments["duration_seconds"]?.intValue else {
    throw ToolError.missingArgument("duration_seconds")
  }

  // Enforce max duration of 30 seconds
  let effectiveDuration = min(durationSeconds, 30)

  // Launch recording status UI
  let statusUI = await MainActor.run { RecordingStatusUI() }

  // Try to launch UI (continue without it if it fails)
  let uiEvents: AsyncStream<RecordingStatusUI.UIEvent>?
  do {
    uiEvents = try await statusUI.launch(config: .init(durationSeconds: effectiveDuration))
  } catch {
    // Log warning but continue without UI
    FileHandle.standardError.write("Warning: Could not launch recording status UI: \(error)\n".data(using: .utf8)!)
    uiEvents = nil
  }

  // Start recording with event stream for precise duration synchronization
  let eventStream = try await screenRecorder.startRecordingWithEvents()

  var videoURL: URL?

  // Wait for first frame before starting timer
  for await event in eventStream {
    switch event {
    case .started(let url):
      videoURL = url
      // Recording infrastructure ready, but don't start timer yet

    case .firstFrameCaptured:
      // Notify UI that recording has started
      await statusUI.notifyRecordingStarted()

      // Race between duration timer and UI stop events
      if let uiEvents = uiEvents {
        // Use withTaskGroup to race between timer and UI events
        await withTaskGroup(of: Void.self) { group in
          // Timer task
          group.addTask {
            try? await Task.sleep(for: .seconds(effectiveDuration))
            _ = try? await screenRecorder.stopRecording()
          }

          // UI events task
          group.addTask {
            for await event in uiEvents {
              switch event {
              case .stopClicked, .timeout:
                _ = try? await screenRecorder.stopRecording()
                return
              case .ready, .processExited:
                break
              }
            }
          }

          // Wait for first task to complete (either timer or stop button)
          await group.next()
          // Cancel remaining tasks
          group.cancelAll()
        }
      } else {
        // No UI, just wait for duration
        try await Task.sleep(for: .seconds(effectiveDuration))
        _ = try await screenRecorder.stopRecording()
      }

    case .stopped(let url):
      videoURL = url
      // Notify UI to show analyzing state
      await statusUI.notifyAnalyzing()

    case .error(let message):
      await statusUI.notifyError()
      try? await Task.sleep(for: .seconds(1.5))
      await MainActor.run { statusUI.terminate() }
      throw ToolError.invalidArgument(message)
    }
  }

  guard let finalURL = videoURL else {
    await statusUI.notifyError()
    try? await Task.sleep(for: .seconds(1.5))
    await MainActor.run { statusUI.terminate() }
    throw ToolError.invalidArgument("Recording failed - no output URL")
  }

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
  do {
    let extractionResult = try await frameExtractor.extractFrames(from: finalURL, config: extractionConfig)
    let analysisResult = try await videoAnalyzer.analyze(
      extractionResult: extractionResult,
      config: analysisConfig
    )

    // Show success state briefly before closing UI
    await statusUI.notifySuccess()
    try? await Task.sleep(for: .seconds(1.5))
    await statusUI.notifyRecordingStopped()

    return """
      Recording completed and analyzed.
      Video file: \(finalURL.path)
      Duration: \(durationSeconds) seconds

      \(formatAnalysisResult(extraction: extractionResult, analysis: analysisResult))
      """
  } catch {
    // Show error state briefly before closing UI
    await statusUI.notifyError()
    try? await Task.sleep(for: .seconds(1.5))
    await statusUI.notifyRecordingStopped()
    throw error
  }
}

// MARK: - App Recording Handlers

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

  // Start recording with event stream for precise duration synchronization
  let eventStream = try await screenRecorder.startRecordingWithEvents(
    appName: "Simulator",
    config: recordingConfig,
    outputPath: nil
  )

  var videoURL: URL?

  // Wait for first frame before starting timer
  for await event in eventStream {
    switch event {
    case .started(let url):
      videoURL = url

    case .firstFrameCaptured:
      // NOW start the duration timer - first actual frame captured
      try await Task.sleep(for: .seconds(durationSeconds))
      _ = try await screenRecorder.stopRecording()

    case .stopped(let url):
      videoURL = url

    case .error(let message):
      throw ToolError.invalidArgument(message)
    }
  }

  guard let finalURL = videoURL else {
    throw ToolError.invalidArgument("Recording failed - no output URL")
  }

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
  let extractionResult = try await frameExtractor.extractFrames(from: finalURL, config: extractionConfig)
  let analysisResult = try await videoAnalyzer.analyze(
    extractionResult: extractionResult,
    config: analysisConfig
  )

  return """
    iOS Simulator recording completed and analyzed.
    Video file: \(finalURL.path)
    Duration: \(durationSeconds) seconds
    Analysis mode: \(mode)

    \(formatAnalysisResult(extraction: extractionResult, analysis: analysisResult))
    """
}

func handleRecordAppAndAnalyze(
  arguments: [String: Value],
  frameExtractor: VideoFrameExtractor,
  videoAnalyzer: VideoAnalyzer,
  screenRecorder: ScreenRecorder
) async throws -> String {
  guard let appName = arguments["app_name"]?.stringValue else {
    throw ToolError.missingArgument("app_name")
  }

  guard let durationSeconds = arguments["duration_seconds"]?.intValue else {
    throw ToolError.missingArgument("duration_seconds")
  }

  // Configure recording for app window (60fps for animations)
  let recordingConfig = ScreenRecorder.RecordingConfig(
    width: 0,  // Will be determined by window size
    height: 0,
    fps: 60,
    showsCursor: true,
    capturesAudio: false,
    quality: .high
  )

  // Start recording with event stream for precise duration synchronization
  let eventStream = try await screenRecorder.startRecordingWithEvents(
    appName: appName,
    config: recordingConfig,
    outputPath: nil
  )

  var videoURL: URL?

  // Wait for first frame before starting timer
  for await event in eventStream {
    switch event {
    case .started(let url):
      videoURL = url

    case .firstFrameCaptured:
      // NOW start the duration timer - first actual frame captured
      try await Task.sleep(for: .seconds(durationSeconds))
      _ = try await screenRecorder.stopRecording()

    case .stopped(let url):
      videoURL = url

    case .error(let message):
      throw ToolError.invalidArgument(message)
    }
  }

  guard let finalURL = videoURL else {
    throw ToolError.invalidArgument("Recording failed - no output URL for '\(appName)'")
  }

  // Determine analysis mode
  let mode = arguments["mode"]?.stringValue ?? "explain"

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
        You are a QA engineer testing UI animations in '\(appName)'. Analyze these sequential frames and report:
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
        You are a QA engineer testing '\(appName)'. Look for bugs and issues:
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
        Evaluate this '\(appName)' UI for accessibility concerns:
        1. TEXT: Is text readable? Appropriate size? Sufficient contrast?
        2. COLORS: Are there contrast issues? Color-only indicators?
        3. TOUCH TARGETS: Are interactive elements large enough?
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
        Explain what happens in this '\(appName)' recording. Describe:
        1. The overall content and context of the application
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
  let extractionResult = try await frameExtractor.extractFrames(from: finalURL, config: extractionConfig)
  let analysisResult = try await videoAnalyzer.analyze(
    extractionResult: extractionResult,
    config: analysisConfig
  )

  return """
    '\(appName)' recording completed and analyzed.
    Video file: \(finalURL.path)
    Duration: \(durationSeconds) seconds
    Analysis mode: \(mode)

    \(formatAnalysisResult(extraction: extractionResult, analysis: analysisResult))
    """
}

// MARK: - Region Selection Handlers

/// Result from the argus-select helper tool
struct SelectionResult: Codable {
  let x: Int
  let y: Int
  let width: Int
  let height: Int
  let screenWidth: Int
  let screenHeight: Int
  let cancelled: Bool
}

/// Get the path to the argus-select binary
func getArgusSelectPath() -> String {
  // First check if we're in a development environment
  let executableURL = Bundle.main.executableURL
  if let bundlePath = executableURL?.deletingLastPathComponent().path {
    let devPath = bundlePath + "/argus-select"
    if FileManager.default.fileExists(atPath: devPath) {
      return devPath
    }
  }

  // Check common installation paths
  let possiblePaths = [
    "/usr/local/bin/argus-select",
    "/opt/homebrew/bin/argus-select",
    ProcessInfo.processInfo.environment["HOME"].map { $0 + "/.local/bin/argus-select" },
    // Same directory as argus-mcp
    executableURL?.deletingLastPathComponent().appendingPathComponent("argus-select").path
  ].compactMap { $0 }

  for path in possiblePaths {
    if FileManager.default.fileExists(atPath: path) {
      return path
    }
  }

  // Default to assuming it's in PATH
  return "argus-select"
}

/// Launch the visual region selector and return the selection
func launchRegionSelector() async throws -> SelectionResult {
  let selectPath = getArgusSelectPath()

  let process = Process()
  process.executableURL = URL(fileURLWithPath: selectPath)

  let outputPipe = Pipe()
  let errorPipe = Pipe()
  process.standardOutput = outputPipe
  process.standardError = errorPipe

  try process.run()
  process.waitUntilExit()

  let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

  guard process.terminationStatus == 0 else {
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
    throw ToolError.invalidArgument("Region selection failed: \(errorString)")
  }

  guard let result = try? JSONDecoder().decode(SelectionResult.self, from: outputData) else {
    throw ToolError.invalidArgument("Failed to parse selection result")
  }

  return result
}

func handleSelectRecordAndAnalyze(
  arguments: [String: Value],
  frameExtractor: VideoFrameExtractor,
  videoAnalyzer: VideoAnalyzer,
  screenRecorder: ScreenRecorder
) async throws -> String {
  // duration_seconds is now optional
  // - If provided: timed mode with countdown
  // - If nil: manual mode with count-up (30s max)
  let durationSeconds = arguments["duration_seconds"]?.intValue

  // First, launch the visual selector
  let selection = try await launchRegionSelector()

  if selection.cancelled {
    return """
      Selection cancelled by user.
      No recording or analysis performed.
      """
  }

  let region = CGRect(
    x: selection.x,
    y: selection.y,
    width: selection.width,
    height: selection.height
  )

  // Configure recording (60fps for animations)
  let recordingConfig = ScreenRecorder.RecordingConfig(
    width: selection.width,
    height: selection.height,
    fps: 60,
    showsCursor: true,
    capturesAudio: false,
    quality: .high
  )

  // Launch recording status UI
  let statusUI = await MainActor.run { RecordingStatusUI() }

  // Try to launch UI (continue without it if it fails)
  // Pass durationSeconds (nil for manual mode = count-up timer)
  let uiEvents: AsyncStream<RecordingStatusUI.UIEvent>?
  do {
    uiEvents = try await statusUI.launch(config: .init(durationSeconds: durationSeconds))
  } catch {
    FileHandle.standardError.write("Warning: Could not launch recording status UI: \(error)\n".data(using: .utf8)!)
    uiEvents = nil
  }

  // Start recording with event stream for precise duration synchronization
  let eventStream = try await screenRecorder.startRecordingWithEvents(
    region: region,
    config: recordingConfig,
    outputPath: nil
  )

  var videoURL: URL?

  // Wait for first frame before starting timer
  for await event in eventStream {
    switch event {
    case .started(let url):
      videoURL = url

    case .firstFrameCaptured:
      // Notify UI that recording has started
      await statusUI.notifyRecordingStarted()

      // Race between duration timer (if timed mode) and UI stop events
      if let uiEvents = uiEvents {
        await withTaskGroup(of: Void.self) { group in
          // Timer task (only if duration specified - timed mode)
          if let duration = durationSeconds {
            group.addTask {
              try? await Task.sleep(for: .seconds(duration))
              _ = try? await screenRecorder.stopRecording()
            }
          }

          // UI events task (handles Stop button and timeout for manual mode)
          group.addTask {
            for await event in uiEvents {
              switch event {
              case .stopClicked, .timeout:
                _ = try? await screenRecorder.stopRecording()
                return
              case .ready, .processExited:
                break
              }
            }
          }

          // Wait for first task to complete
          await group.next()
          group.cancelAll()
        }
      } else {
        // No UI available - use duration if provided, otherwise default to 5 seconds
        let fallbackDuration = durationSeconds ?? 5
        try await Task.sleep(for: .seconds(fallbackDuration))
        _ = try await screenRecorder.stopRecording()
      }

    case .stopped(let url):
      videoURL = url
      // Notify UI to show analyzing state
      await statusUI.notifyAnalyzing()

    case .error(let message):
      await statusUI.notifyError()
      try? await Task.sleep(for: .seconds(1.5))
      await MainActor.run { statusUI.terminate() }
      throw ToolError.invalidArgument(message)
    }
  }

  guard let finalURL = videoURL else {
    await statusUI.notifyError()
    try? await Task.sleep(for: .seconds(1.5))
    await MainActor.run { statusUI.terminate() }
    throw ToolError.invalidArgument("Recording failed - no output URL")
  }

  // Determine analysis mode
  let mode = arguments["mode"]?.stringValue ?? "explain"

  // For frame extraction, use actual duration or default to 30 (max for manual mode)
  let effectiveDurationForFrames = durationSeconds ?? 30

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
        You are a QA engineer testing UI animations in a selected screen region. Analyze these sequential frames and report:
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
    maxFrames = min(effectiveDurationForFrames * 60, 180)
    targetWidth = 1024
    compressionQuality = 0.75

  case "find_bugs":
    analysisConfig = VideoAnalyzer.AnalysisConfig(
      batchSize: 5,
      model: "gpt-4o-mini",
      maxTokensPerBatch: 1500,
      systemPrompt: """
        You are a QA engineer looking for bugs in this screen region. Look for:
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
    maxFrames = min(effectiveDurationForFrames * 2, 60)
    targetWidth = 1920
    compressionQuality = 0.9

  case "accessibility":
    analysisConfig = VideoAnalyzer.AnalysisConfig(
      batchSize: 5,
      model: "gpt-4o-mini",
      maxTokensPerBatch: 1500,
      systemPrompt: """
        Evaluate this screen region for accessibility concerns:
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
    maxFrames = min(effectiveDurationForFrames, 30)
    targetWidth = 1920
    compressionQuality = 0.9

  default:  // "explain" or unknown
    analysisConfig = VideoAnalyzer.AnalysisConfig(
      batchSize: 5,
      model: "gpt-4o-mini",
      maxTokensPerBatch: 1500,
      systemPrompt: """
        Explain what happens in this screen recording. Describe:
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
  do {
    let extractionResult = try await frameExtractor.extractFrames(from: finalURL, config: extractionConfig)
    let analysisResult = try await videoAnalyzer.analyze(
      extractionResult: extractionResult,
      config: analysisConfig
    )

    // Show success state briefly before closing UI
    await statusUI.notifySuccess()
    try? await Task.sleep(for: .seconds(1.5))
    await statusUI.notifyRecordingStopped()

    let durationText = durationSeconds.map { "\($0) seconds" } ?? "manual (user stopped)"

    return """
      Screen region recording completed and analyzed!

      Selected region: \(selection.x), \(selection.y) - \(selection.width)x\(selection.height)
      Video file: \(finalURL.path)
      Duration: \(durationText)
      Analysis mode: \(mode)

      \(formatAnalysisResult(extraction: extractionResult, analysis: analysisResult))
      """
  } catch {
    // Show error state briefly before closing UI
    await statusUI.notifyError()
    try? await Task.sleep(for: .seconds(1.5))
    await statusUI.notifyRecordingStopped()
    throw error
  }
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
