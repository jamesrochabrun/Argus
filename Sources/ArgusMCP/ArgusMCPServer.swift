import ArgumentParser
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
            You are a QA engineer reviewing this \(context) for UI bugs. Scan for:

            ## LAYOUT ISSUES
            - Overlapping elements or text
            - Incorrect spacing or alignment
            - Elements cut off or overflowing
            - Missing or broken images

            ## VISUAL BUGS
            - Incorrect colors or contrast issues
            - Missing UI elements (buttons, icons, labels)
            - Broken or inconsistent styling
            - Text truncation or rendering issues

            ## STATE PROBLEMS
            - Incorrect loading states
            - Error states not displayed properly
            - Empty states missing or malformed

            Report issues as: **[SEVERITY]** Issue description (location)
            Severities: CRITICAL, HIGH, MEDIUM, LOW
            If no issues found, state "No UI bugs detected."
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
            You are a senior UI engineer performing detailed analysis of this \(context). Examine:

            ## DESIGN-IMPLEMENTATION ALIGNMENT
            - Do colors match expected values?
            - Are fonts, sizes, weights correct?
            - Is spacing consistent with design system?
            - Are corner radii and shadows correct?

            ## PIXEL-LEVEL ISSUES
            - Sub-pixel rendering artifacts
            - Anti-aliasing problems
            - Retina/display scaling issues

            ## ANIMATION MECHANICS (if applicable)
            - Frame-by-frame position changes
            - Opacity transitions and timing
            - Transform origins and pivot points

            ## ACCESSIBILITY CONCERNS
            - Text contrast ratios
            - Touch target sizes
            - Focus indicators visibility

            Reference frame numbers: "Frame X shows..."
            Conclude with actionable fix recommendations.
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
  let statusUI: RecordingStatusUI?
}

// MARK: - Recording Orchestrator

/// Orchestrates screen recording with UI feedback and duration handling
enum RecordingOrchestrator {

  /// Performs a recording session with optional duration
  /// - Parameters:
  ///   - eventStream: The recording event stream from ScreenRecorder
  ///   - durationSeconds: nil = manual mode (user clicks Stop), Int = timed mode
  ///   - maxDuration: Maximum allowed recording duration (mode-specific)
  ///   - screenRecorder: The screen recorder instance
  /// - Returns: RecordingResult containing URL, status UI, and event stream for cancel monitoring
  static func performRecording(
    eventStream: AsyncStream<ScreenRecorder.RecordingEvent>,
    durationSeconds: Int?,
    maxDuration: Int,
    screenRecorder: ScreenRecorder
  ) async throws -> RecordingResult {
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

    // Timeout for first frame capture (5 seconds)
    // If ScreenCaptureKit doesn't produce frames, we don't want to hang forever
    let firstFrameTimeoutSeconds = 5

    // Process recording events with timeout for first frame
    // We use a task group to race between event processing and timeout
    let recordingResult: (url: URL?, timedOut: Bool) = try await withThrowingTaskGroup(of: (url: URL?, timedOut: Bool).self) { group in

      // Main event processing task
      group.addTask {
        var url: URL?
        var receivedFirstFrame = false

        for await event in eventStream {
          switch event {
          case .started(let startedURL):
            url = startedURL

          case .firstFrameCaptured:
            receivedFirstFrame = true
            // Notify UI that recording has started (timer begins)
            await statusUI.notifyRecordingStarted()

            // Race between duration timer (if timed mode) and UI stop events
            if let uiEvents = uiEvents {
              await withTaskGroup(of: Void.self) { innerGroup in
                // Timer task (only if duration specified - timed mode)
                if let duration = effectiveDuration {
                  innerGroup.addTask {
                    try? await Task.sleep(for: .seconds(duration))
                    _ = try? await screenRecorder.stopRecording()
                  }
                }

                // UI events task (handles Stop button and timeout for manual mode)
                innerGroup.addTask {
                  for await uiEvent in uiEvents {
                    switch uiEvent {
                    case .stopClicked, .timeout:
                      // User explicitly stopped or max duration reached
                      _ = try? await screenRecorder.stopRecording()
                      return
                    case .processExited:
                      // UI process terminated - only stop if in manual mode
                      if effectiveDuration == nil {
                        _ = try? await screenRecorder.stopRecording()
                        return
                      }
                      // In timed mode, ignore and let timer handle it
                      break
                    case .ready, .cancelClicked:
                      break
                    }
                  }
                  // Stream finished without explicit stop - wait indefinitely
                  // (timer task will handle stopping if in timed mode)
                  if effectiveDuration != nil {
                    // In timed mode, just wait - timer will stop recording
                    try? await Task.sleep(for: .seconds(86400))
                  } else {
                    // In manual mode with no UI, stop recording
                    _ = try? await screenRecorder.stopRecording()
                  }
                }

                await innerGroup.next()
                innerGroup.cancelAll()
              }
            } else {
              // No UI available
              if let duration = effectiveDuration {
                try? await Task.sleep(for: .seconds(duration))
                _ = try? await screenRecorder.stopRecording()
              } else {
                try? await Task.sleep(for: .seconds(maxDuration))
                _ = try? await screenRecorder.stopRecording()
              }
            }

          case .stopped(let stoppedURL):
            url = stoppedURL
            await statusUI.notifyAnalyzing()
            return (url: url, timedOut: false)

          case .error(let message):
            await statusUI.notifyError()
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run { statusUI.terminate() }
            throw ToolError.invalidArgument(message)
          }
        }

        // If we get here without receiving first frame, something went wrong
        if !receivedFirstFrame {
          return (url: nil, timedOut: true)
        }

        return (url: url, timedOut: false)
      }

      // Timeout task - only triggers if first frame doesn't arrive
      group.addTask {
        try await Task.sleep(for: .seconds(firstFrameTimeoutSeconds))
        return (url: nil, timedOut: true)
      }

      // Wait for first task to complete
      if let result = try await group.next() {
        group.cancelAll()
        return result
      }

      return (url: nil, timedOut: true)
    }

    // Handle timeout case
    if recordingResult.timedOut {
      FileHandle.standardError.write("Error: Timed out waiting for first frame from ScreenCaptureKit\n".data(using: .utf8)!)
      await statusUI.notifyError()
      try? await Task.sleep(for: .seconds(1.5))
      await MainActor.run { statusUI.terminate() }
      // Try to stop the recording to clean up
      _ = try? await screenRecorder.stopRecording()
      throw ToolError.invalidArgument("Recording failed - screen capture did not start. Please try again.")
    }

    videoURL = recordingResult.url

    guard let finalURL = videoURL else {
      await statusUI.notifyError()
      try? await Task.sleep(for: .seconds(1.5))
      await MainActor.run { statusUI.terminate() }
      throw ToolError.invalidArgument("Recording failed - no output URL")
    }

    return RecordingResult(url: finalURL, statusUI: statusUI)
  }

  /// Performs analysis with cancellation support
  /// - Parameters:
  ///   - videoURL: URL of the recorded video
  ///   - mode: Analysis mode
  ///   - context: Context description for the prompt
  ///   - customPrompt: Optional custom prompt
  ///   - effectiveDuration: Recording duration
  ///   - frameExtractor: Frame extractor instance
  ///   - videoAnalyzer: Video analyzer instance
  ///   - statusUI: Status UI for showing success/error and getting fresh event stream
  /// - Returns: Analysis result or throws if cancelled/failed
  static func performAnalysisWithCancellation(
    videoURL: URL,
    mode: AnalysisMode,
    context: String,
    customPrompt: String?,
    effectiveDuration: Int,
    frameExtractor: VideoFrameExtractor,
    videoAnalyzer: VideoAnalyzer,
    statusUI: RecordingStatusUI?
  ) async throws -> (extraction: VideoFrameExtractor.ExtractionResult, analysis: VideoAnalyzer.VideoAnalysisResult) {
    // Get a fresh event stream from the status UI for analysis phase
    // This is needed because the recording phase consumes/exhausts the original stream
    let uiEventStream = await statusUI?.getAnalysisEventStream()

    // If no UI event stream, just run analysis directly
    guard let uiEventStream = uiEventStream else {
      return try await analyzeVideo(
        url: videoURL,
        mode: mode,
        context: context,
        customPrompt: customPrompt,
        effectiveDuration: effectiveDuration,
        frameExtractor: frameExtractor,
        videoAnalyzer: videoAnalyzer
      )
    }

    // Run analysis with cancellation monitoring
    return try await withThrowingTaskGroup(of: (VideoFrameExtractor.ExtractionResult, VideoAnalyzer.VideoAnalysisResult)?.self) { group in
      // Analysis task
      group.addTask {
        try await analyzeVideo(
          url: videoURL,
          mode: mode,
          context: context,
          customPrompt: customPrompt,
          effectiveDuration: effectiveDuration,
          frameExtractor: frameExtractor,
          videoAnalyzer: videoAnalyzer
        )
      }

      // Cancel monitor task
      group.addTask {
        for await event in uiEventStream {
          if case .cancelClicked = event {
            throw AnalysisCancellationError.cancelledByUser
          }
        }
        return nil // Stream ended without cancel
      }

      // Wait for first result
      while let result = try await group.next() {
        if let analysisResult = result {
          group.cancelAll()
          return analysisResult
        }
      }

      // Should not reach here
      throw ToolError.invalidArgument("Analysis failed unexpectedly")
    }
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

// MARK: - Session Cleanup

/// Kills orphan argus-status and argus-select processes to ensure fresh recording state.
/// This is called at the start of each tool handler to prevent state corruption from
/// incomplete previous operations.
func cleanupOrphanProcesses() {
  let processNames = ["argus-status", "argus-select"]

  for processName in processNames {
    let killProcess = Process()
    killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    killProcess.arguments = ["-9", processName]  // SIGKILL for immediate termination

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

@main
struct ArgusMCPServer: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "argus-mcp",
    abstract: "MCP server for video analysis using OpenAI Vision API",
    version: "1.0.0"
  )

  @Flag(name: .long, help: "Configure Claude Code to use Argus MCP server")
  var setup = false

  mutating func run() async throws {
    // Handle --setup flag
    if setup {
      try runSetup()
      return
    }

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
          Analyze a video file for UI bugs, animation quality, or design-implementation alignment.
          Use to verify recorded UI interactions, validate animations against specs, or
          catch visual bugs before deployment. Supports MP4, MOV, and other common formats.
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
                - 'low': UI Bug Detection (~$0.003) - Scan for layout issues, visual bugs. 4fps, max 30s.
                - 'high': Detailed Analysis (~$0.01) - Pixel-level inspection for design alignment. 8fps, max 30s (150 frame cap).
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
          Record screen and analyze for UI bugs, animation quality, or visual issues.
          Perfect for testing UI changes, validating animations, or catching visual regressions
          in your development workflow. Recording includes a visual status indicator.
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
                - 'low': UI Bug Detection (~$0.003) - Scan for layout issues, visual bugs. 4fps, max 30s.
                - 'high': Detailed Analysis (~$0.01) - Pixel-level inspection for design alignment. 8fps, max 30s (150 frame cap).
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
          Select a screen region with visual crosshair, record it, and analyze.
          Ideal for testing specific UI components - buttons, modals, form fields,
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
                - 'low': UI Bug Detection (~$0.003) - Scan for layout issues, visual bugs. 4fps, max 30s.
                - 'high': Detailed Analysis (~$0.01) - Pixel-level inspection for design alignment. 8fps, max 30s (150 frame cap).
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
  let recordingResult = try await RecordingOrchestrator.performRecording(
    eventStream: eventStream,
    durationSeconds: durationSeconds,
    maxDuration: mode.maxDuration,
    screenRecorder: screenRecorder
  )

  // Analyze video with cancellation support
  do {
    let result = try await RecordingOrchestrator.performAnalysisWithCancellation(
      videoURL: recordingResult.url,
      mode: mode,
      context: "screen recording",
      customPrompt: arguments["custom_prompt"]?.stringValue,
      effectiveDuration: effectiveDuration,
      frameExtractor: frameExtractor,
      videoAnalyzer: videoAnalyzer,
      statusUI: recordingResult.statusUI
    )

    // Finalize UI with success
    if let statusUI = recordingResult.statusUI {
      await RecordingOrchestrator.finalizeWithUI(success: true, statusUI: statusUI)
    }

    let durationText = durationSeconds.map { "\($0) seconds" } ?? "manual (user stopped)"

    return """
      Recording completed and analyzed.
      Video file: \(recordingResult.url.path)
      Duration: \(durationText)

      \(formatAnalysisResult(extraction: result.extraction, analysis: result.analysis))
      """
  } catch let error as AnalysisCancellationError {
    // User cancelled - show cancelled state in UI briefly, then dismiss
    // Do this in background so we can return to Claude Code immediately
    if let statusUI = recordingResult.statusUI {
      Task {
        await statusUI.notifyCancelled()
        try? await Task.sleep(for: .seconds(1))
        await MainActor.run { statusUI.terminate() }
      }
    }
    return error.localizedDescription
  } catch {
    // Analysis failed - show error in UI
    if let statusUI = recordingResult.statusUI {
      await RecordingOrchestrator.finalizeWithUI(success: false, statusUI: statusUI)
    }
    throw ToolError.invalidArgument("Video analysis failed: \(error.localizedDescription)")
  }
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
  let recordingResult = try await RecordingOrchestrator.performRecording(
    eventStream: eventStream,
    durationSeconds: durationSeconds,
    maxDuration: mode.maxDuration,
    screenRecorder: screenRecorder
  )

  // Analyze video with cancellation support
  do {
    let result = try await RecordingOrchestrator.performAnalysisWithCancellation(
      videoURL: recordingResult.url,
      mode: mode,
      context: "iOS Simulator recording",
      customPrompt: arguments["custom_prompt"]?.stringValue,
      effectiveDuration: effectiveDuration,
      frameExtractor: frameExtractor,
      videoAnalyzer: videoAnalyzer,
      statusUI: recordingResult.statusUI
    )

    // Finalize UI with success
    if let statusUI = recordingResult.statusUI {
      await RecordingOrchestrator.finalizeWithUI(success: true, statusUI: statusUI)
    }

    let durationText = durationSeconds.map { "\($0) seconds" } ?? "manual (user stopped)"

    return """
      iOS Simulator recording completed and analyzed.
      Video file: \(recordingResult.url.path)
      Duration: \(durationText)
      Analysis mode: \(mode.rawValue)

      \(formatAnalysisResult(extraction: result.extraction, analysis: result.analysis))
      """
  } catch let error as AnalysisCancellationError {
    // User cancelled - show cancelled state in UI briefly, then dismiss
    // Do this in background so we can return to Claude Code immediately
    if let statusUI = recordingResult.statusUI {
      Task {
        await statusUI.notifyCancelled()
        try? await Task.sleep(for: .seconds(1))
        await MainActor.run { statusUI.terminate() }
      }
    }
    return error.localizedDescription
  } catch {
    // Analysis failed - show error in UI
    if let statusUI = recordingResult.statusUI {
      await RecordingOrchestrator.finalizeWithUI(success: false, statusUI: statusUI)
    }
    throw ToolError.invalidArgument("Video analysis failed: \(error.localizedDescription)")
  }
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
  let recordingResult = try await RecordingOrchestrator.performRecording(
    eventStream: eventStream,
    durationSeconds: durationSeconds,
    maxDuration: mode.maxDuration,
    screenRecorder: screenRecorder
  )

  // Analyze video with cancellation support
  do {
    let result = try await RecordingOrchestrator.performAnalysisWithCancellation(
      videoURL: recordingResult.url,
      mode: mode,
      context: "'\(appName)' recording",
      customPrompt: arguments["custom_prompt"]?.stringValue,
      effectiveDuration: effectiveDuration,
      frameExtractor: frameExtractor,
      videoAnalyzer: videoAnalyzer,
      statusUI: recordingResult.statusUI
    )

    // Finalize UI with success
    if let statusUI = recordingResult.statusUI {
      await RecordingOrchestrator.finalizeWithUI(success: true, statusUI: statusUI)
    }

    let durationText = durationSeconds.map { "\($0) seconds" } ?? "manual (user stopped)"

    return """
      '\(appName)' recording completed and analyzed.
      Video file: \(recordingResult.url.path)
      Duration: \(durationText)
      Analysis mode: \(mode.rawValue)

      \(formatAnalysisResult(extraction: result.extraction, analysis: result.analysis))
      """
  } catch let error as AnalysisCancellationError {
    // User cancelled - show cancelled state in UI briefly, then dismiss
    // Do this in background so we can return to Claude Code immediately
    if let statusUI = recordingResult.statusUI {
      Task {
        await statusUI.notifyCancelled()
        try? await Task.sleep(for: .seconds(1))
        await MainActor.run { statusUI.terminate() }
      }
    }
    return error.localizedDescription
  } catch {
    // Analysis failed - show error in UI
    if let statusUI = recordingResult.statusUI {
      await RecordingOrchestrator.finalizeWithUI(success: false, statusUI: statusUI)
    }
    throw ToolError.invalidArgument("Video analysis failed: \(error.localizedDescription)")
  }
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
  let recordingResult = try await RecordingOrchestrator.performRecording(
    eventStream: eventStream,
    durationSeconds: durationSeconds,
    maxDuration: mode.maxDuration,
    screenRecorder: screenRecorder
  )

  // Analyze video with cancellation support
  do {
    let result = try await RecordingOrchestrator.performAnalysisWithCancellation(
      videoURL: recordingResult.url,
      mode: mode,
      context: "screen recording",
      customPrompt: arguments["custom_prompt"]?.stringValue,
      effectiveDuration: effectiveDuration,
      frameExtractor: frameExtractor,
      videoAnalyzer: videoAnalyzer,
      statusUI: recordingResult.statusUI
    )

    // Finalize UI with success
    if let statusUI = recordingResult.statusUI {
      await RecordingOrchestrator.finalizeWithUI(success: true, statusUI: statusUI)
    }

    let durationText = durationSeconds.map { "\($0) seconds" } ?? "manual (user stopped)"

    return """
      Screen region recording completed and analyzed!

      Selected region: \(selection.x), \(selection.y) - \(selection.width)x\(selection.height)
      Video file: \(recordingResult.url.path)
      Duration: \(durationText)
      Analysis mode: \(mode.rawValue)

      \(formatAnalysisResult(extraction: result.extraction, analysis: result.analysis))
      """
  } catch let error as AnalysisCancellationError {
    // User cancelled - show cancelled state in UI briefly, then dismiss
    // Do this in background so we can return to Claude Code immediately
    if let statusUI = recordingResult.statusUI {
      Task {
        await statusUI.notifyCancelled()
        try? await Task.sleep(for: .seconds(1))
        await MainActor.run { statusUI.terminate() }
      }
    }
    return error.localizedDescription
  } catch {
    // Analysis failed - show error in UI
    if let statusUI = recordingResult.statusUI {
      await RecordingOrchestrator.finalizeWithUI(success: false, statusUI: statusUI)
    }
    throw ToolError.invalidArgument("Video analysis failed: \(error.localizedDescription)")
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
