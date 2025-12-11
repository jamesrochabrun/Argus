import AVFoundation
import Foundation
import MCP
import SwiftOpenAI

// Type alias to disambiguate Tool types
typealias MCPTool = MCP.Tool

// MARK: - Model Configuration

/// Default model for video analysis - change this to swap models globally
public let defaultVisionModel = "gpt-4o-mini"

// MARK: - Analysis Mode Configuration

/// Analysis quality modes with their associated configurations
enum AnalysisMode: String {
  case low
  case high

  /// Maximum recording duration in seconds for this mode
  var maxDuration: Int {
    switch self {
    case .low, .high:
      return 30  // All modes support 30 seconds (high mode caps at 150 frames)
    }
  }

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
          maxTokensPerBatch: 800,
          systemPrompt: """
            You are a visual observer providing detailed descriptions of this \(context). Describe what you see:

            ## VISUAL ELEMENTS
            - UI components: buttons, text fields, labels, icons, images
            - Layout: arrangement, spacing, alignment of elements
            - Design: colors, typography, shadows, borders, corner radii
            - Content: any text, numbers, or media visible

            ## MOTION & ANIMATION (if movement detected)
            - Position changes between frames
            - Opacity/fade transitions
            - Scale, rotation, or transform effects
            - Timing and easing characteristics

            ## STATE & CONTEXT
            - Current screen state and apparent purpose
            - Interactive elements and their visual states
            - Progress indicators, loading states, or feedback
            - Visual hierarchy and focus areas

            Reference frames as: "Frame X shows..."
            Describe objectively and thoroughly, like a designer or animator documenting their work.
            """,
          imageDetail: "low",
          temperature: 0.2
        ),
        extraction: VideoFrameExtractor.ExtractionConfig(
          framesPerSecond: 4.0,
          maxFrames: 120,
          targetWidth: 512,
          compressionQuality: 0.6
        )
      )

    case .high:
      return (
        analysis: VideoAnalyzer.AnalysisConfig(
          batchSize: 5,
          model: defaultVisionModel,
          maxTokensPerBatch: 2000,
          systemPrompt: """
            You are a visual observer providing detailed descriptions of this \(context). Describe what you see:

            ## VISUAL ELEMENTS
            - UI components: buttons, text fields, labels, icons, images
            - Layout: arrangement, spacing, alignment of elements
            - Design: colors, typography, shadows, borders, corner radii
            - Content: any text, numbers, or media visible

            ## MOTION & ANIMATION (if movement detected)
            - Position changes between frames
            - Opacity/fade transitions
            - Scale, rotation, or transform effects
            - Timing and easing characteristics

            ## STATE & CONTEXT
            - Current screen state and apparent purpose
            - Interactive elements and their visual states
            - Progress indicators, loading states, or feedback
            - Visual hierarchy and focus areas

            Reference frames as: "Frame X shows..."
            Describe objectively and thoroughly, like a designer or animator documenting their work.
            """,
          imageDetail: "high",
          temperature: 0.1
        ),
        extraction: VideoFrameExtractor.ExtractionConfig(
          framesPerSecond: 8.0,
          maxFrames: 150,
          targetWidth: 896,
          compressionQuality: 0.85
        )
      )
    }
  }
}

// MARK: - Analysis Cancellation

/// Error thrown when analysis is cancelled by user
enum AnalysisCancellationError: Error, LocalizedError {
  case cancelledByUser

  var errorDescription: String? {
    "Analysis cancelled by user. No results available."
  }
}

/// Result of a recording session
struct RecordingResult {
  let url: URL
}

/// Result from the argus status subcommand
struct StatusUIResult: Codable {
  enum ResultType: String, Codable {
    case stopped    // User clicked stop button
    case timeout    // Max duration reached
    case cancelled  // User cancelled
  }

  let result: ResultType
  let elapsed: Int
}

/// Handle to a running status UI process, allowing us to signal completion
class StatusUIHandle {
  let process: Process
  let outputPipe: Pipe
  let signalFilePath: String

  init(process: Process, outputPipe: Pipe, signalFilePath: String) {
    self.process = process
    self.outputPipe = outputPipe
    self.signalFilePath = signalFilePath
  }

  /// Read the status result from stdout (call after recording phase completes)
  func readResult() throws -> StatusUIResult {
    // Read available data from output pipe
    let data = outputPipe.fileHandleForReading.availableData

    guard let result = try? JSONDecoder().decode(StatusUIResult.self, from: data) else {
      throw ToolError.invalidArgument("Failed to parse status UI result")
    }

    return result
  }

  /// Signal that analysis completed successfully (via file)
  func signalSuccess() {
    try? "success".write(toFile: signalFilePath, atomically: true, encoding: .utf8)
  }

  /// Signal that analysis failed with an error (via file)
  func signalError() {
    try? "error".write(toFile: signalFilePath, atomically: true, encoding: .utf8)
  }

  /// Wait for the status UI process to exit
  func waitForExit() {
    process.waitUntilExit()
  }

  /// Terminate the status UI immediately (for cleanup)
  func terminate() {
    if process.isRunning {
      process.terminate()
    }
    // Clean up signal file
    try? FileManager.default.removeItem(atPath: signalFilePath)
  }
}

/// Launch the status UI and return a handle for signaling completion
/// The status UI will show "Recording" then transition to "Analyzing" when recording stops
/// Call signalSuccess() or signalError() after analysis to complete the UI
func launchStatusUI(durationSeconds: Int?) throws -> StatusUIHandle {
  guard let executablePath = Bundle.main.executablePath else {
    throw ToolError.invalidArgument("Cannot find own executable path")
  }

  // Generate unique signal file path for this session
  let signalFilePath = "/tmp/argus-signal-\(UUID().uuidString).txt"

  let process = Process()
  process.executableURL = URL(fileURLWithPath: executablePath)

  var args = ["status", "--signal-file=\(signalFilePath)"]
  if let duration = durationSeconds {
    args.append("--duration=\(duration)")
  }
  process.arguments = args

  // Set environment to allow GUI access when launched from non-GUI parent
  var env = ProcessInfo.processInfo.environment
  env["__CFBundleIdentifier"] = "com.argus.status"
  process.environment = env

  let outputPipe = Pipe()
  process.standardOutput = outputPipe
  process.standardError = FileHandle.standardError

  try process.run()

  return StatusUIHandle(process: process, outputPipe: outputPipe, signalFilePath: signalFilePath)
}

/// Legacy function for backward compatibility - launches status UI and waits for it to exit
/// Use launchStatusUI() + StatusUIHandle for the new analyzing state flow
func launchStatusUIAndWait(durationSeconds: Int?) async throws -> StatusUIResult {
  let handle = try launchStatusUI(durationSeconds: durationSeconds)

  // Wait for recording to complete (status UI will output JSON then transition to analyzing)
  // Since we're using the old flow, signal success immediately to exit
  handle.signalSuccess()
  handle.waitForExit()

  // For legacy compatibility, return a default result
  return StatusUIResult(result: .timeout, elapsed: durationSeconds ?? 0)
}

// MARK: - Recording Orchestrator

/// Result of recording phase, includes status UI handle for signaling analysis completion
struct RecordingPhaseResult {
  let url: URL
  let statusUIHandle: StatusUIHandle?
}

/// Orchestrates screen recording with synchronous status UI
enum RecordingOrchestrator {

  /// Performs a recording session with synchronous status UI
  /// - Parameters:
  ///   - eventStream: The recording event stream from ScreenRecorder
  ///   - durationSeconds: nil = manual mode (user clicks Stop), Int = timed mode
  ///   - maxDuration: Maximum allowed recording duration (mode-specific)
  ///   - screenRecorder: The screen recorder instance
  /// - Returns: RecordingPhaseResult containing URL and status UI handle for signaling analysis completion
  static func performRecording(
    eventStream: AsyncStream<ScreenRecorder.RecordingEvent>,
    durationSeconds: Int?,
    maxDuration: Int,
    screenRecorder: ScreenRecorder
  ) async throws -> RecordingPhaseResult {
    // Cap duration at max
    let effectiveDuration: Int? = durationSeconds.map { min($0, maxDuration) }

    var videoURL: URL?
    var firstFrameReceived = false
    var statusUIHandle: StatusUIHandle?

    // Wait for first frame before launching status UI
    for await event in eventStream {
      switch event {
      case .started(let url):
        videoURL = url

      case .firstFrameCaptured:
        firstFrameReceived = true
        // First frame received - launch status UI
        // The status UI will show "Recording" then auto-transition to "Analyzing" when recording stops
        do {
          let handle = try launchStatusUI(durationSeconds: effectiveDuration)
          statusUIHandle = handle

          // Run a task to wait for the status UI to output its result (recording stopped)
          // and then stop the screen recording
          // Capture outputPipe explicitly for Sendable compliance
          let outputPipe = handle.outputPipe
          Task { @Sendable in
            // Read the result when status UI outputs it (after recording phase completes)
            // This blocks until the status UI writes to stdout
            let data = outputPipe.fileHandleForReading.availableData
            if let result = try? JSONDecoder().decode(StatusUIResult.self, from: data) {
              // Status UI transitioned to analyzing - stop recording
              switch result.result {
              case .stopped, .timeout, .cancelled:
                _ = try? await screenRecorder.stopRecording()
              }
            }
          }
        } catch {
          // Status UI failed - fall back to timer-based recording
          FileHandle.standardError.write("Status UI failed: \(error). Using fallback timer.\n".data(using: .utf8)!)
          Task {
            if let duration = effectiveDuration {
              try? await Task.sleep(for: .seconds(duration))
            } else {
              try? await Task.sleep(for: .seconds(maxDuration))
            }
            _ = try? await screenRecorder.stopRecording()
          }
        }

      case .stopped(let url):
        videoURL = url
        guard let finalURL = videoURL else {
          throw ToolError.invalidArgument("Recording failed - no output URL")
        }
        return RecordingPhaseResult(url: finalURL, statusUIHandle: statusUIHandle)

      case .error(let message):
        // Signal error to status UI if running
        statusUIHandle?.signalError()
        throw ToolError.invalidArgument(message)
      }
    }

    // If we got here without receiving first frame, something went wrong
    if !firstFrameReceived {
      statusUIHandle?.signalError()
      throw ToolError.invalidArgument("Recording failed - screen capture did not start. Please try again.")
    }

    guard let finalURL = videoURL else {
      statusUIHandle?.signalError()
      throw ToolError.invalidArgument("Recording failed - no output URL")
    }

    return RecordingPhaseResult(url: finalURL, statusUIHandle: statusUIHandle)
  }

  /// Performs video analysis and signals the status UI when done
  static func performAnalysis(
    videoURL: URL,
    mode: AnalysisMode,
    context: String,
    customPrompt: String?,
    effectiveDuration: Int,
    frameExtractor: VideoFrameExtractor,
    videoAnalyzer: VideoAnalyzer,
    statusUIHandle: StatusUIHandle?
  ) async throws -> (extraction: VideoFrameExtractor.ExtractionResult, analysis: VideoAnalyzer.VideoAnalysisResult) {
    do {
      let result = try await analyzeVideo(
        url: videoURL,
        mode: mode,
        context: context,
        customPrompt: customPrompt,
        effectiveDuration: effectiveDuration,
        frameExtractor: frameExtractor,
        videoAnalyzer: videoAnalyzer
      )

      // Signal success to status UI
      statusUIHandle?.signalSuccess()

      return result
    } catch {
      // Signal error to status UI
      statusUIHandle?.signalError()
      throw error
    }
  }
}

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

// MARK: - MCP Server Entry Point

/// Main entry point for the MCP server
/// Called by MCPCommand subcommand
public func runMCPServer() async throws {
  // Get API key from environment
  guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
    FileHandle.standardError.write("Error: OPENAI_API_KEY environment variable not set\n".data(using: .utf8)!)
    throw ToolError.invalidArgument("OPENAI_API_KEY environment variable not set")
  }

  let frameExtractor = VideoFrameExtractor()
  let videoAnalyzer = VideoAnalyzer(apiKey: apiKey)
  let screenRecorder = ScreenRecorder()

  // Define tools with Value-based input schemas
  let tools: [MCPTool] = [
    MCPTool(
      name: "analyze_video",
      description: """
        Analyze a video file for detailed visual descriptions of UI content, animations, and design elements.
        Use to document recorded interactions, describe animation sequences, or get frame-by-frame visual analysis.
        Supports MP4, MOV, and other common formats.
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
            "description": "Number of frames to extract per second (default varies by mode)"
          ]),
          "max_frames": .object([
            "type": "integer",
            "description": "Maximum number of frames to extract (default varies by mode)"
          ]),
          "mode": .object([
            "type": "string",
            "description": """
              Analysis mode:
              - 'low': Quick Analysis (~$0.003) - Efficient visual description. 4fps, max 30s.
              - 'high': Detailed Analysis (~$0.01) - Thorough visual description. 8fps, max 30s (150 frame cap).
              """,
            "enum": .array(["low", "high"])
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
        Record screen and get detailed visual descriptions of the content.
        Perfect for documenting UI interactions, describing animations, or capturing visual details
        of your application. Recording includes a visual status indicator.
        """,
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "duration_seconds": .object([
            "type": "integer",
            "description": "Duration to record in seconds. If not provided, recording runs until user clicks Stop (max 30s for all modes)."
          ]),
          "mode": .object([
            "type": "string",
            "description": """
              Analysis mode:
              - 'low': Quick Analysis (~$0.003) - Efficient visual description. 4fps, max 30s.
              - 'high': Detailed Analysis (~$0.01) - Thorough visual description. 8fps, max 30s (150 frame cap).
              """,
            "enum": .array(["low", "high"])
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
        Select a screen region with visual crosshair, record it, and get detailed descriptions.
        Ideal for documenting specific UI components - buttons, modals, form fields,
        or individual animations without recording the entire screen.
        """,
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "duration_seconds": .object([
            "type": "integer",
            "description": "Duration to record in seconds. If not provided, recording runs until user clicks Stop (max 30s for all modes)."
          ]),
          "mode": .object([
            "type": "string",
            "description": """
              Analysis mode:
              - 'low': Quick Analysis (~$0.003) - Efficient visual description. 4fps, max 30s.
              - 'high': Detailed Analysis (~$0.01) - Thorough visual description. 8fps, max 30s (150 frame cap).
              """,
            "enum": .array(["low", "high"])
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
    name: "argus",
    version: "1.1.0",
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
  // Kill any orphan UI processes from previous sessions
  cleanupOrphanProcesses()

  guard let videoPath = arguments["video_path"]?.stringValue else {
    throw ToolError.missingArgument("video_path")
  }

  let url = URL(fileURLWithPath: videoPath)

  // Check if file exists
  guard FileManager.default.fileExists(atPath: videoPath) else {
    throw ToolError.fileNotFound(videoPath)
  }

  // Get video duration for high mode frame calculation
  let asset = AVURLAsset(url: url)
  let duration = try await asset.load(.duration)
  let effectiveDuration = Int(CMTimeGetSeconds(duration))

  // Parse mode and get configs from centralized source
  let modeString = arguments["mode"]?.stringValue ?? "low"
  let mode = AnalysisMode(rawValue: modeString) ?? .low
  var (analysisConfig, extractionConfig) = mode.configs(context: "video", effectiveDuration: effectiveDuration)

  // Apply user overrides for extraction config if provided
  if let fps = arguments["frames_per_second"]?.doubleValue {
    extractionConfig = VideoFrameExtractor.ExtractionConfig(
      framesPerSecond: fps,
      maxFrames: extractionConfig.maxFrames,
      targetWidth: extractionConfig.targetWidth,
      compressionQuality: extractionConfig.compressionQuality
    )
  }

  if let max = arguments["max_frames"]?.intValue {
    extractionConfig = VideoFrameExtractor.ExtractionConfig(
      framesPerSecond: extractionConfig.framesPerSecond,
      maxFrames: max,
      targetWidth: extractionConfig.targetWidth,
      compressionQuality: extractionConfig.compressionQuality
    )
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
  // Ensure clean state before starting new recording
  cleanupOrphanProcesses()
  await screenRecorder.forceReset()

  // Duration is optional: nil = manual mode, Int = timed mode (capped based on mode)
  let durationSeconds = arguments["duration_seconds"]?.intValue
  let mode = AnalysisMode(rawValue: arguments["mode"]?.stringValue ?? "low") ?? .low
  let effectiveDuration = durationSeconds.map { min($0, mode.maxDuration) } ?? mode.maxDuration

  // Start recording
  let eventStream = try await screenRecorder.startRecordingWithEvents()
  let recordingPhase = try await RecordingOrchestrator.performRecording(
    eventStream: eventStream,
    durationSeconds: durationSeconds,
    maxDuration: mode.maxDuration,
    screenRecorder: screenRecorder
  )

  // Analyze video (status UI will show "Analyzing..." during this phase)
  let result = try await RecordingOrchestrator.performAnalysis(
    videoURL: recordingPhase.url,
    mode: mode,
    context: "screen recording",
    customPrompt: arguments["custom_prompt"]?.stringValue,
    effectiveDuration: effectiveDuration,
    frameExtractor: frameExtractor,
    videoAnalyzer: videoAnalyzer,
    statusUIHandle: recordingPhase.statusUIHandle
  )

  let durationText = durationSeconds.map { "\($0) seconds" } ?? "manual (user stopped)"

  return """
    Recording completed and analyzed.
    Video file: \(recordingPhase.url.path)
    Duration: \(durationText)

    \(formatAnalysisResult(extraction: result.extraction, analysis: result.analysis))
    """
}

// MARK: - App Recording Handlers

func handleRecordSimulatorAndAnalyze(
  arguments: [String: Value],
  frameExtractor: VideoFrameExtractor,
  videoAnalyzer: VideoAnalyzer,
  screenRecorder: ScreenRecorder
) async throws -> String {
  // Ensure clean state before starting new recording
  cleanupOrphanProcesses()
  await screenRecorder.forceReset()

  // Duration is optional: nil = manual mode, Int = timed mode (capped based on mode)
  let durationSeconds = arguments["duration_seconds"]?.intValue
  let mode = AnalysisMode(rawValue: arguments["mode"]?.stringValue ?? "low") ?? .low
  let effectiveDuration = durationSeconds.map { min($0, mode.maxDuration) } ?? mode.maxDuration

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
  let recordingPhase = try await RecordingOrchestrator.performRecording(
    eventStream: eventStream,
    durationSeconds: durationSeconds,
    maxDuration: mode.maxDuration,
    screenRecorder: screenRecorder
  )

  // Analyze video (status UI will show "Analyzing..." during this phase)
  let result = try await RecordingOrchestrator.performAnalysis(
    videoURL: recordingPhase.url,
    mode: mode,
    context: "iOS Simulator recording",
    customPrompt: arguments["custom_prompt"]?.stringValue,
    effectiveDuration: effectiveDuration,
    frameExtractor: frameExtractor,
    videoAnalyzer: videoAnalyzer,
    statusUIHandle: recordingPhase.statusUIHandle
  )

  let durationText = durationSeconds.map { "\($0) seconds" } ?? "manual (user stopped)"

  return """
    iOS Simulator recording completed and analyzed.
    Video file: \(recordingPhase.url.path)
    Duration: \(durationText)
    Analysis mode: \(mode.rawValue)

    \(formatAnalysisResult(extraction: result.extraction, analysis: result.analysis))
    """
}

func handleRecordAppAndAnalyze(
  arguments: [String: Value],
  frameExtractor: VideoFrameExtractor,
  videoAnalyzer: VideoAnalyzer,
  screenRecorder: ScreenRecorder
) async throws -> String {
  // Ensure clean state before starting new recording
  cleanupOrphanProcesses()
  await screenRecorder.forceReset()

  guard let appName = arguments["app_name"]?.stringValue else {
    throw ToolError.missingArgument("app_name")
  }

  // Duration is optional: nil = manual mode, Int = timed mode (capped based on mode)
  let durationSeconds = arguments["duration_seconds"]?.intValue
  let mode = AnalysisMode(rawValue: arguments["mode"]?.stringValue ?? "low") ?? .low
  let effectiveDuration = durationSeconds.map { min($0, mode.maxDuration) } ?? mode.maxDuration

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
  let recordingPhase = try await RecordingOrchestrator.performRecording(
    eventStream: eventStream,
    durationSeconds: durationSeconds,
    maxDuration: mode.maxDuration,
    screenRecorder: screenRecorder
  )

  // Analyze video (status UI will show "Analyzing..." during this phase)
  let result = try await RecordingOrchestrator.performAnalysis(
    videoURL: recordingPhase.url,
    mode: mode,
    context: "'\(appName)' recording",
    customPrompt: arguments["custom_prompt"]?.stringValue,
    effectiveDuration: effectiveDuration,
    frameExtractor: frameExtractor,
    videoAnalyzer: videoAnalyzer,
    statusUIHandle: recordingPhase.statusUIHandle
  )

  let durationText = durationSeconds.map { "\($0) seconds" } ?? "manual (user stopped)"

  return """
    '\(appName)' recording completed and analyzed.
    Video file: \(recordingPhase.url.path)
    Duration: \(durationText)
    Analysis mode: \(mode.rawValue)

    \(formatAnalysisResult(extraction: result.extraction, analysis: result.analysis))
    """
}

// MARK: - Region Selection Handlers

/// Result from the argus select subcommand
struct SelectionResult: Codable {
  let x: Int
  let y: Int
  let width: Int
  let height: Int
  let screenWidth: Int
  let screenHeight: Int
  let cancelled: Bool
}

/// Launch the visual region selector and return the selection
/// Uses self-invocation: runs the same binary with "select" subcommand
func launchRegionSelector() async throws -> SelectionResult {
  // Self-invocation: use the same binary with "select" subcommand
  guard let executablePath = Bundle.main.executablePath else {
    throw ToolError.invalidArgument("Cannot find own executable path")
  }

  let process = Process()
  process.executableURL = URL(fileURLWithPath: executablePath)
  process.arguments = ["select"]  // Run as subcommand

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
  // Ensure clean state before starting new recording
  cleanupOrphanProcesses()
  await screenRecorder.forceReset()

  // Duration is optional: nil = manual mode, Int = timed mode (capped based on mode)
  let durationSeconds = arguments["duration_seconds"]?.intValue
  let mode = AnalysisMode(rawValue: arguments["mode"]?.stringValue ?? "low") ?? .low
  let effectiveDuration = durationSeconds.map { min($0, mode.maxDuration) } ?? mode.maxDuration

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
  let recordingPhase = try await RecordingOrchestrator.performRecording(
    eventStream: eventStream,
    durationSeconds: durationSeconds,
    maxDuration: mode.maxDuration,
    screenRecorder: screenRecorder
  )

  // Analyze video (status UI will show "Analyzing..." during this phase)
  let result = try await RecordingOrchestrator.performAnalysis(
    videoURL: recordingPhase.url,
    mode: mode,
    context: "screen recording",
    customPrompt: arguments["custom_prompt"]?.stringValue,
    effectiveDuration: effectiveDuration,
    frameExtractor: frameExtractor,
    videoAnalyzer: videoAnalyzer,
    statusUIHandle: recordingPhase.statusUIHandle
  )

  let durationText = durationSeconds.map { "\($0) seconds" } ?? "manual (user stopped)"

  return """
    Screen region recording completed and analyzed!

    Selected region: \(selection.x), \(selection.y) - \(selection.width)x\(selection.height)
    Video file: \(recordingPhase.url.path)
    Duration: \(durationText)
    Analysis mode: \(mode.rawValue)

    \(formatAnalysisResult(extraction: result.extraction, analysis: result.analysis))
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
  print("  - record_and_analyze: Record screen and analyze")
  print("  - select_record_and_analyze: Record selected region")
  print("  - analyze_video: Analyze existing video file")
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
