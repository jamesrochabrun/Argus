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

// MARK: - Model Configuration

/// Default model for video analysis - change this to swap models globally
public let defaultVisionModel = "gpt-5-nano"

// MARK: - Analysis Mode Configuration

/// Analysis quality modes with their associated configurations
enum AnalysisMode: String {
  case low
  case medium
  case high

  /// Returns analysis and extraction configs for the given mode
  /// - Parameters:
  ///   - context: Description like "screen recording", "iOS Simulator", etc.
  ///   - effectiveDuration: Used to calculate maxFrames for high mode
  func configs(context: String, effectiveDuration: Int) -> (
    analysis: VideoAnalyzer.AnalysisConfig,
    extraction: VideoFrameExtractor.ExtractionConfig
  ) {
    switch self {
    case .low:
      return (
        analysis: VideoAnalyzer.AnalysisConfig(
          batchSize: 8,
          model: defaultVisionModel,
          maxTokensPerBatch: 500,
          systemPrompt: "Provide a quick, concise summary of what happens in this \(context). Focus on the main content and key moments.",
          imageDetail: "low",
          temperature: 0.3
        ),
        extraction: VideoFrameExtractor.ExtractionConfig(
          framesPerSecond: 0.5,
          maxFrames: 15,
          targetWidth: 512,
          compressionQuality: 0.7
        )
      )

    case .medium:
      return (
        analysis: VideoAnalyzer.AnalysisConfig(
          batchSize: 5,
          model: defaultVisionModel,
          maxTokensPerBatch: 1500,
          systemPrompt: """
            Explain in detail what happens in this \(context). Describe:
            1. The overall content and context
            2. Step-by-step actions and events
            3. Important UI elements, text, and visual information
            4. The purpose and outcome of what's shown
            Be thorough and educational in your explanation.
            """,
          imageDetail: "auto",
          temperature: 0.3
        ),
        extraction: VideoFrameExtractor.ExtractionConfig(
          framesPerSecond: 1.0,
          maxFrames: 30,
          targetWidth: 1024,
          compressionQuality: 0.8
        )
      )

    case .high:
      return (
        analysis: VideoAnalyzer.AnalysisConfig(
          batchSize: 5,
          model: defaultVisionModel,
          maxTokensPerBatch: 2000,
          systemPrompt: """
            You are a QA engineer performing comprehensive analysis of this \(context). Examine each frame carefully and report on:

            ## ANIMATIONS
            - Timing and easing curves (ease-in, ease-out, linear, spring/bounce)
            - Smoothness - any dropped frames, stutters, or jerky motion?
            - Start/end states - are initial and final positions correct?

            ## VISUAL BUGS
            - Glitches, artifacts, incorrect rendering, clipping issues
            - Misaligned elements, overlapping content, broken layouts
            - Text truncation, overflow, incorrect formatting

            ## ACCESSIBILITY
            - Text readability and contrast (WCAG AA compliance)
            - Touch target sizes (44pt minimum for interactive elements)
            - Color-only indicators that may be problematic
            - Visual hierarchy clarity

            ## STATE CONSISTENCY
            - Wrong colors, missing elements, incorrect data
            - UI state errors or inconsistencies

            Be precise with frame numbers and timestamps when reporting issues.
            Provide specific recommendations for any problems found.
            """,
          imageDetail: "high",
          temperature: 0.1
        ),
        extraction: VideoFrameExtractor.ExtractionConfig(
          framesPerSecond: 30.0,
          maxFrames: min(effectiveDuration * 30, 120),
          targetWidth: 1920,
          compressionQuality: 0.9
        )
      )
    }
  }
}

// MARK: - Recording Orchestrator

/// Orchestrates screen recording with UI feedback and duration handling
enum RecordingOrchestrator {

  /// Maximum recording duration in seconds
  static let maxDuration = 30

  /// Performs a recording session with optional duration
  /// - Parameters:
  ///   - eventStream: The recording event stream from ScreenRecorder
  ///   - durationSeconds: nil = manual mode (user clicks Stop, max 30s), Int = timed mode (capped at 30s)
  ///   - screenRecorder: The screen recorder instance
  /// - Returns: Tuple of the recorded video URL and the status UI (for finalization after analysis)
  static func performRecording(
    eventStream: AsyncStream<ScreenRecorder.RecordingEvent>,
    durationSeconds: Int?,
    screenRecorder: ScreenRecorder
  ) async throws -> (url: URL, statusUI: RecordingStatusUI?) {
    // Cap duration at max
    let effectiveDuration: Int? = durationSeconds.map { min($0, maxDuration) }

    // Launch recording status UI
    let statusUI = await MainActor.run { RecordingStatusUI() }

    // Try to launch UI (continue without it if it fails)
    let uiEvents: AsyncStream<RecordingStatusUI.UIEvent>?
    do {
      uiEvents = try await statusUI.launch(config: .init(durationSeconds: effectiveDuration))
    } catch {
      FileHandle.standardError.write("Warning: Could not launch recording status UI: \(error)\n".data(using: .utf8)!)
      uiEvents = nil
    }

    var videoURL: URL?

    // Process recording events
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
            if let duration = effectiveDuration {
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
          // No UI available
          if let duration = effectiveDuration {
            // Timed mode: wait for specified duration
            try await Task.sleep(for: .seconds(duration))
            _ = try await screenRecorder.stopRecording()
          } else {
            // Manual mode but no UI - use max duration as safety fallback
            try await Task.sleep(for: .seconds(maxDuration))
            _ = try await screenRecorder.stopRecording()
          }
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

    return (url: finalURL, statusUI: statusUI)
  }

  /// Completes analysis and shows success/error in UI, then terminates
  static func finalizeWithUI(
    success: Bool,
    statusUI: RecordingStatusUI
  ) async {
    if success {
      await statusUI.notifySuccess()
    } else {
      await statusUI.notifyError()
    }
    try? await Task.sleep(for: .seconds(1.5))
    await MainActor.run { statusUI.terminate() }
  }
}

// MARK: - Analysis Helper

/// Performs video analysis with the given configuration
func analyzeVideo(
  url: URL,
  mode: AnalysisMode,
  context: String,
  customPrompt: String?,
  effectiveDuration: Int,
  frameExtractor: VideoFrameExtractor,
  videoAnalyzer: VideoAnalyzer
) async throws -> (extraction: VideoFrameExtractor.ExtractionResult, analysis: VideoAnalyzer.VideoAnalysisResult) {
  var (analysisConfig, extractionConfig) = mode.configs(context: context, effectiveDuration: effectiveDuration)

  // Apply custom prompt if provided
  if let customPrompt = customPrompt {
    analysisConfig = VideoAnalyzer.AnalysisConfig(
      batchSize: analysisConfig.batchSize,
      model: analysisConfig.model,
      maxTokensPerBatch: analysisConfig.maxTokensPerBatch,
      systemPrompt: customPrompt,
      imageDetail: analysisConfig.imageDetail,
      temperature: analysisConfig.temperature
    )
  }

  // Extract frames and analyze
  let extractionResult = try await frameExtractor.extractFrames(from: url, config: extractionConfig)
  let analysisResult = try await videoAnalyzer.analyze(
    extractionResult: extractionResult,
    config: analysisConfig
  )

  return (extraction: extractionResult, analysis: analysisResult)
}

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
                Analysis quality level:
                - 'low': Fast overview (~$0.001) - Quick summary, 15 frames at 0.5fps
                - 'medium': Balanced detail (~$0.003) - Good for most tasks, 30 frames at 1fps
                - 'high': Comprehensive analysis (~$0.05+, ⚠️ higher cost) - Frame-by-frame analysis at 30fps, catches animations, bugs, and accessibility issues
                """,
              "enum": .array(["low", "medium", "high"])
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
              "description": "Duration to record in seconds. If not provided, recording runs until user clicks Stop (max 30s)."
            ]),
            "mode": .object([
              "type": "string",
              "description": """
                Analysis quality level:
                - 'low': Fast overview (~$0.001) - Quick summary
                - 'medium': Balanced detail (~$0.003) - Good for most tasks
                - 'high': Comprehensive analysis (~$0.05+, ⚠️ higher cost) - Frame-by-frame, catches animations/bugs/accessibility
                """,
              "enum": .array(["low", "medium", "high"])
            ]),
            "custom_prompt": .object([
              "type": "string",
              "description": "Optional custom system prompt for analysis"
            ])
          ]),
          "required": .array(["mode"])
        ])
      ),

      MCPTool(
        name: "select_record_and_analyze",
        description: """
          Opens a visual crosshair overlay to select a specific screen region, then records
          that region for a specified duration and analyzes it. Perfect for testing specific
          UI components without recording the entire screen.
          """,
        inputSchema: .object([
          "type": "object",
          "properties": .object([
            "duration_seconds": .object([
              "type": "integer",
              "description": "Duration to record in seconds. If not provided, recording runs until user clicks Stop (max 30s)."
            ]),
            "mode": .object([
              "type": "string",
              "description": """
                Analysis quality level:
                - 'low': Fast overview (~$0.001) - Quick summary
                - 'medium': Balanced detail (~$0.003) - Good for most tasks
                - 'high': Comprehensive analysis (~$0.05+, ⚠️ higher cost) - Frame-by-frame, catches animations/bugs/accessibility
                """,
              "enum": .array(["low", "medium", "high"])
            ]),
            "custom_prompt": .object([
              "type": "string",
              "description": "Optional custom analysis prompt"
            ])
          ]),
          "required": .array(["mode"])
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
    case "low":
      // Fast overview - quick summary
      analysisConfig = VideoAnalyzer.AnalysisConfig(
        batchSize: 8,
        model: defaultVisionModel,
        maxTokensPerBatch: 500,
        systemPrompt: "Provide a quick, concise summary of what happens in this video. Focus on the main content and key moments.",
        imageDetail: "low",
        temperature: 0.3
      )
      framesPerSecond = 0.5
      maxFrames = 15
      targetWidth = 512
      compressionQuality = 0.7

    case "medium":
      // Balanced analysis - good for most tasks
      analysisConfig = VideoAnalyzer.AnalysisConfig(
        batchSize: 5,
        model: defaultVisionModel,
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

    case "high":
      // Comprehensive frame-by-frame analysis
      analysisConfig = VideoAnalyzer.AnalysisConfig(
        batchSize: 5,
        model: defaultVisionModel,
        maxTokensPerBatch: 2000,
        systemPrompt: """
          You are a QA engineer performing comprehensive video analysis. Examine each frame carefully and report on:

          ## ANIMATIONS
          - Timing and easing curves (ease-in, ease-out, linear, spring/bounce)
          - Smoothness - any dropped frames, stutters, or jerky motion?
          - Start/end states - are initial and final positions correct?

          ## VISUAL BUGS
          - Glitches, artifacts, incorrect rendering, clipping issues
          - Misaligned elements, overlapping content, broken layouts
          - Text truncation, overflow, incorrect formatting

          ## ACCESSIBILITY
          - Text readability and contrast (WCAG AA compliance)
          - Touch target sizes (44pt minimum for interactive elements)
          - Color-only indicators that may be problematic
          - Visual hierarchy clarity

          ## STATE CONSISTENCY
          - Wrong colors, missing elements, incorrect data
          - UI state errors or inconsistencies

          Be precise with frame numbers and timestamps when reporting issues.
          Provide specific recommendations for any problems found.
          """,
        imageDetail: "high",
        temperature: 0.1
      )
      framesPerSecond = 30.0
      maxFrames = 120
      targetWidth = 1920
      compressionQuality = 0.9

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
  // Duration is optional: nil = manual mode, Int = timed mode (capped at 30s)
  let durationSeconds = arguments["duration_seconds"]?.intValue
  let mode = AnalysisMode(rawValue: arguments["mode"]?.stringValue ?? "medium") ?? .medium
  let effectiveDuration = durationSeconds.map { min($0, RecordingOrchestrator.maxDuration) } ?? RecordingOrchestrator.maxDuration

  // Start recording
  let eventStream = try await screenRecorder.startRecordingWithEvents()
  let (videoURL, statusUI) = try await RecordingOrchestrator.performRecording(
    eventStream: eventStream,
    durationSeconds: durationSeconds,
    screenRecorder: screenRecorder
  )

  // Analyze video
  var analysisSucceeded = false
  var extraction: VideoFrameExtractor.ExtractionResult?
  var analysis: VideoAnalyzer.VideoAnalysisResult?

  do {
    let result = try await analyzeVideo(
      url: videoURL,
      mode: mode,
      context: "screen recording",
      customPrompt: arguments["custom_prompt"]?.stringValue,
      effectiveDuration: effectiveDuration,
      frameExtractor: frameExtractor,
      videoAnalyzer: videoAnalyzer
    )
    extraction = result.extraction
    analysis = result.analysis
    analysisSucceeded = true
  } catch {
    analysisSucceeded = false
  }

  // Finalize UI
  if let statusUI = statusUI {
    await RecordingOrchestrator.finalizeWithUI(success: analysisSucceeded, statusUI: statusUI)
  }

  // Re-throw if analysis failed
  guard analysisSucceeded, let extraction = extraction, let analysis = analysis else {
    throw ToolError.invalidArgument("Video analysis failed")
  }

  let durationText = durationSeconds.map { "\($0) seconds" } ?? "manual (user stopped)"

  return """
    Recording completed and analyzed.
    Video file: \(videoURL.path)
    Duration: \(durationText)

    \(formatAnalysisResult(extraction: extraction, analysis: analysis))
    """
}

// MARK: - App Recording Handlers

func handleRecordSimulatorAndAnalyze(
  arguments: [String: Value],
  frameExtractor: VideoFrameExtractor,
  videoAnalyzer: VideoAnalyzer,
  screenRecorder: ScreenRecorder
) async throws -> String {
  // Duration is optional: nil = manual mode, Int = timed mode (capped at 30s)
  let durationSeconds = arguments["duration_seconds"]?.intValue
  let mode = AnalysisMode(rawValue: arguments["mode"]?.stringValue ?? "medium") ?? .medium
  let effectiveDuration = durationSeconds.map { min($0, RecordingOrchestrator.maxDuration) } ?? RecordingOrchestrator.maxDuration

  // Configure recording for simulator (60fps for animations)
  let recordingConfig = ScreenRecorder.RecordingConfig(
    width: 0,
    height: 0,
    fps: 60,
    showsCursor: false,
    capturesAudio: false,
    quality: .high
  )

  // Start recording
  let eventStream = try await screenRecorder.startRecordingWithEvents(
    appName: "Simulator",
    config: recordingConfig,
    outputPath: nil
  )
  let (videoURL, statusUI) = try await RecordingOrchestrator.performRecording(
    eventStream: eventStream,
    durationSeconds: durationSeconds,
    screenRecorder: screenRecorder
  )

  // Analyze video
  var analysisSucceeded = false
  var extraction: VideoFrameExtractor.ExtractionResult?
  var analysis: VideoAnalyzer.VideoAnalysisResult?

  do {
    let result = try await analyzeVideo(
      url: videoURL,
      mode: mode,
      context: "iOS Simulator recording",
      customPrompt: arguments["custom_prompt"]?.stringValue,
      effectiveDuration: effectiveDuration,
      frameExtractor: frameExtractor,
      videoAnalyzer: videoAnalyzer
    )
    extraction = result.extraction
    analysis = result.analysis
    analysisSucceeded = true
  } catch {
    analysisSucceeded = false
  }

  // Finalize UI
  if let statusUI = statusUI {
    await RecordingOrchestrator.finalizeWithUI(success: analysisSucceeded, statusUI: statusUI)
  }

  // Re-throw if analysis failed
  guard analysisSucceeded, let extraction = extraction, let analysis = analysis else {
    throw ToolError.invalidArgument("Video analysis failed")
  }

  let durationText = durationSeconds.map { "\($0) seconds" } ?? "manual (user stopped)"

  return """
    iOS Simulator recording completed and analyzed.
    Video file: \(videoURL.path)
    Duration: \(durationText)
    Analysis mode: \(mode.rawValue)

    \(formatAnalysisResult(extraction: extraction, analysis: analysis))
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

  // Duration is optional: nil = manual mode, Int = timed mode (capped at 30s)
  let durationSeconds = arguments["duration_seconds"]?.intValue
  let mode = AnalysisMode(rawValue: arguments["mode"]?.stringValue ?? "medium") ?? .medium
  let effectiveDuration = durationSeconds.map { min($0, RecordingOrchestrator.maxDuration) } ?? RecordingOrchestrator.maxDuration

  // Configure recording for app window (60fps for animations)
  let recordingConfig = ScreenRecorder.RecordingConfig(
    width: 0,
    height: 0,
    fps: 60,
    showsCursor: true,
    capturesAudio: false,
    quality: .high
  )

  // Start recording
  let eventStream = try await screenRecorder.startRecordingWithEvents(
    appName: appName,
    config: recordingConfig,
    outputPath: nil
  )
  let (videoURL, statusUI) = try await RecordingOrchestrator.performRecording(
    eventStream: eventStream,
    durationSeconds: durationSeconds,
    screenRecorder: screenRecorder
  )

  // Analyze video
  var analysisSucceeded = false
  var extraction: VideoFrameExtractor.ExtractionResult?
  var analysis: VideoAnalyzer.VideoAnalysisResult?

  do {
    let result = try await analyzeVideo(
      url: videoURL,
      mode: mode,
      context: "'\(appName)' recording",
      customPrompt: arguments["custom_prompt"]?.stringValue,
      effectiveDuration: effectiveDuration,
      frameExtractor: frameExtractor,
      videoAnalyzer: videoAnalyzer
    )
    extraction = result.extraction
    analysis = result.analysis
    analysisSucceeded = true
  } catch {
    analysisSucceeded = false
  }

  // Finalize UI
  if let statusUI = statusUI {
    await RecordingOrchestrator.finalizeWithUI(success: analysisSucceeded, statusUI: statusUI)
  }

  // Re-throw if analysis failed
  guard analysisSucceeded, let extraction = extraction, let analysis = analysis else {
    throw ToolError.invalidArgument("Video analysis failed")
  }

  let durationText = durationSeconds.map { "\($0) seconds" } ?? "manual (user stopped)"

  return """
    '\(appName)' recording completed and analyzed.
    Video file: \(videoURL.path)
    Duration: \(durationText)
    Analysis mode: \(mode.rawValue)

    \(formatAnalysisResult(extraction: extraction, analysis: analysis))
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
  // Duration is optional: nil = manual mode, Int = timed mode (capped at 30s)
  let durationSeconds = arguments["duration_seconds"]?.intValue
  let mode = AnalysisMode(rawValue: arguments["mode"]?.stringValue ?? "medium") ?? .medium
  let effectiveDuration = durationSeconds.map { min($0, RecordingOrchestrator.maxDuration) } ?? RecordingOrchestrator.maxDuration

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

  // Start recording
  let eventStream = try await screenRecorder.startRecordingWithEvents(
    region: region,
    config: recordingConfig,
    outputPath: nil
  )
  let (videoURL, statusUI) = try await RecordingOrchestrator.performRecording(
    eventStream: eventStream,
    durationSeconds: durationSeconds,
    screenRecorder: screenRecorder
  )

  // Analyze video
  var analysisSucceeded = false
  var extraction: VideoFrameExtractor.ExtractionResult?
  var analysis: VideoAnalyzer.VideoAnalysisResult?

  do {
    let result = try await analyzeVideo(
      url: videoURL,
      mode: mode,
      context: "screen recording",
      customPrompt: arguments["custom_prompt"]?.stringValue,
      effectiveDuration: effectiveDuration,
      frameExtractor: frameExtractor,
      videoAnalyzer: videoAnalyzer
    )
    extraction = result.extraction
    analysis = result.analysis
    analysisSucceeded = true
  } catch {
    analysisSucceeded = false
  }

  // Finalize UI
  if let statusUI = statusUI {
    await RecordingOrchestrator.finalizeWithUI(success: analysisSucceeded, statusUI: statusUI)
  }

  // Re-throw if analysis failed
  guard analysisSucceeded, let extraction = extraction, let analysis = analysis else {
    throw ToolError.invalidArgument("Video analysis failed")
  }

  let durationText = durationSeconds.map { "\($0) seconds" } ?? "manual (user stopped)"

  return """
    Screen region recording completed and analyzed!

    Selected region: \(selection.x), \(selection.y) - \(selection.width)x\(selection.height)
    Video file: \(videoURL.path)
    Duration: \(durationText)
    Analysis mode: \(mode.rawValue)

    \(formatAnalysisResult(extraction: extraction, analysis: analysis))
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
