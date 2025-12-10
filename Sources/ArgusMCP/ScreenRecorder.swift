import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

/// Screen recorder using ScreenCaptureKit for macOS
/// Captures screen content and saves to video file
@available(macOS 14.0, *)
public actor ScreenRecorder {

  /// Recording configuration
  public struct RecordingConfig: Sendable {
    /// Target width for recording
    public let width: Int
    /// Target height for recording
    public let height: Int
    /// Frames per second
    public let fps: Int
    /// Whether to capture cursor
    public let showsCursor: Bool
    /// Whether to capture audio
    public let capturesAudio: Bool
    /// Quality preset
    public let quality: Quality

    public enum Quality: String, Sendable {
      case low
      case medium
      case high

      var videoBitrate: Int {
        switch self {
        case .low: return 2_000_000
        case .medium: return 5_000_000
        case .high: return 10_000_000
        }
      }
    }

    public init(
      width: Int = 1920,
      height: Int = 1080,
      fps: Int = 30,
      showsCursor: Bool = true,
      capturesAudio: Bool = false,
      quality: Quality = .medium
    ) {
      self.width = width
      self.height = height
      self.fps = fps
      self.showsCursor = showsCursor
      self.capturesAudio = capturesAudio
      self.quality = quality
    }

    public static let `default` = RecordingConfig()
  }

  /// Recording state
  public enum RecordingState: Sendable {
    case idle
    case preparing
    case recording
    case stopping
    case finished(URL)
    case error(String)
  }

  /// Events emitted during recording lifecycle for duration synchronization
  public enum RecordingEvent: Sendable {
    case started(URL)           // Recording infrastructure ready, returns output URL
    case firstFrameCaptured     // First actual frame has been captured - start timer here
    case stopped(URL)           // Recording stopped successfully
    case error(String)          // Error occurred
  }

  /// Available display info
  public struct DisplayInfo: Sendable {
    public let displayID: CGDirectDisplayID
    public let width: Int
    public let height: Int
    public let isMain: Bool
  }

  /// Available window info
  public struct WindowInfo: Sendable {
    public let windowID: CGWindowID
    public let title: String?
    public let ownerName: String?
    public let frame: CGRect
  }

  private var stream: SCStream?
  private var streamOutput: StreamOutput?
  private var assetWriter: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var outputURL: URL?
  private var state: RecordingState = .idle
  private var eventContinuation: AsyncStream<RecordingEvent>.Continuation?

  public init() {}

  /// Get available displays
  public func getAvailableDisplays() async throws -> [DisplayInfo] {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

    return content.displays.map { display in
      DisplayInfo(
        displayID: display.displayID,
        width: display.width,
        height: display.height,
        isMain: display.displayID == CGMainDisplayID()
      )
    }
  }

  /// Get available windows
  public func getAvailableWindows() async throws -> [WindowInfo] {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)

    return content.windows.compactMap { window -> WindowInfo? in
      // Filter out windows without titles or from system processes
      guard window.title != nil || window.owningApplication?.applicationName != nil else {
        return nil
      }

      return WindowInfo(
        windowID: window.windowID,
        title: window.title,
        ownerName: window.owningApplication?.applicationName,
        frame: window.frame
      )
    }
  }

  /// Start recording the main display
  public func startRecording(
    config: RecordingConfig = .default,
    outputPath: String? = nil
  ) async throws -> URL {
    guard case .idle = state else {
      throw RecorderError.alreadyRecording
    }

    state = .preparing

    // Get the main display
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
      throw RecorderError.noDisplayAvailable
    }

    return try await startRecording(display: mainDisplay, config: config, outputPath: outputPath)
  }

  /// Start recording a specific display
  public func startRecording(
    displayID: CGDirectDisplayID,
    config: RecordingConfig = .default,
    outputPath: String? = nil
  ) async throws -> URL {
    guard case .idle = state else {
      throw RecorderError.alreadyRecording
    }

    state = .preparing

    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
      throw RecorderError.displayNotFound
    }

    return try await startRecording(display: display, config: config, outputPath: outputPath)
  }

  /// Start recording a specific window
  public func startRecording(
    windowID: CGWindowID,
    config: RecordingConfig = .default,
    outputPath: String? = nil
  ) async throws -> URL {
    guard case .idle = state else {
      throw RecorderError.alreadyRecording
    }

    state = .preparing

    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
      throw RecorderError.windowNotFound
    }

    return try await startRecording(window: window, config: config, outputPath: outputPath)
  }

  /// Start recording a window by app name (e.g., "Simulator", "Safari")
  public func startRecording(
    appName: String,
    config: RecordingConfig = .default,
    outputPath: String? = nil
  ) async throws -> URL {
    guard case .idle = state else {
      throw RecorderError.alreadyRecording
    }

    state = .preparing

    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

    // Find windows matching the app name (case-insensitive)
    let matchingWindows = content.windows.filter { window in
      guard let ownerName = window.owningApplication?.applicationName else { return false }
      return ownerName.localizedCaseInsensitiveContains(appName)
    }

    // Prefer windows with content (non-zero size)
    guard let window = matchingWindows.first(where: { $0.frame.width > 0 && $0.frame.height > 0 })
            ?? matchingWindows.first else {
      state = .idle
      throw RecorderError.appNotFound(appName)
    }

    return try await startRecording(window: window, config: config, outputPath: outputPath)
  }

  /// Start recording a specific region of the screen
  public func startRecording(
    region: CGRect,
    config: RecordingConfig = .default,
    outputPath: String? = nil
  ) async throws -> URL {
    guard case .idle = state else {
      throw RecorderError.alreadyRecording
    }

    state = .preparing

    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
      throw RecorderError.noDisplayAvailable
    }

    // Create content filter with crop rect
    let filter = SCContentFilter(display: mainDisplay, excludingWindows: [])

    // Adjust config for the region size
    let regionConfig = RecordingConfig(
      width: Int(region.width),
      height: Int(region.height),
      fps: config.fps,
      showsCursor: config.showsCursor,
      capturesAudio: config.capturesAudio,
      quality: config.quality
    )

    return try await setupAndStartRecording(
      filter: filter,
      config: regionConfig,
      outputPath: outputPath,
      cropRect: region
    )
  }

  // MARK: - Event-Based Recording Methods (for duration synchronization)

  /// Start recording the main display with event stream for duration synchronization
  /// The stream yields .firstFrameCaptured when the first frame is captured - start timer there
  public func startRecordingWithEvents(
    config: RecordingConfig = .default,
    outputPath: String? = nil
  ) async throws -> AsyncStream<RecordingEvent> {
    guard case .idle = state else {
      throw RecorderError.alreadyRecording
    }

    state = .preparing

    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let mainDisplayID = CGMainDisplayID()
    guard let mainDisplay = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
      throw RecorderError.noDisplayAvailable
    }

    let filter = SCContentFilter(display: mainDisplay, excludingWindows: [])
    return try await setupAndStartRecordingWithEvents(filter: filter, config: config, outputPath: outputPath, cropRect: nil)
  }

  /// Start recording a window by app name with event stream for duration synchronization
  public func startRecordingWithEvents(
    appName: String,
    config: RecordingConfig = .default,
    outputPath: String? = nil
  ) async throws -> AsyncStream<RecordingEvent> {
    guard case .idle = state else {
      throw RecorderError.alreadyRecording
    }

    state = .preparing

    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

    // Find windows matching the app name (case-insensitive)
    let matchingWindows = content.windows.filter { window in
      guard let ownerName = window.owningApplication?.applicationName else { return false }
      return ownerName.localizedCaseInsensitiveContains(appName)
    }

    // Prefer windows with content (non-zero size)
    guard let window = matchingWindows.first(where: { $0.frame.width > 0 && $0.frame.height > 0 })
            ?? matchingWindows.first else {
      state = .idle
      throw RecorderError.appNotFound(appName)
    }

    let filter = SCContentFilter(desktopIndependentWindow: window)

    // Use window dimensions if config has 0 width/height
    let effectiveConfig: RecordingConfig
    if config.width == 0 || config.height == 0 {
      effectiveConfig = RecordingConfig(
        width: Int(window.frame.width),
        height: Int(window.frame.height),
        fps: config.fps,
        showsCursor: config.showsCursor,
        capturesAudio: config.capturesAudio,
        quality: config.quality
      )
    } else {
      effectiveConfig = config
    }

    return try await setupAndStartRecordingWithEvents(filter: filter, config: effectiveConfig, outputPath: outputPath, cropRect: nil)
  }

  /// Start recording a specific region with event stream for duration synchronization
  public func startRecordingWithEvents(
    region: CGRect,
    config: RecordingConfig = .default,
    outputPath: String? = nil
  ) async throws -> AsyncStream<RecordingEvent> {
    guard case .idle = state else {
      throw RecorderError.alreadyRecording
    }

    state = .preparing

    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let mainDisplayID = CGMainDisplayID()
    guard let mainDisplay = content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first else {
      throw RecorderError.noDisplayAvailable
    }

    let filter = SCContentFilter(display: mainDisplay, excludingWindows: [])

    // Adjust config for the region size
    let regionConfig = RecordingConfig(
      width: Int(region.width),
      height: Int(region.height),
      fps: config.fps,
      showsCursor: config.showsCursor,
      capturesAudio: config.capturesAudio,
      quality: config.quality
    )

    return try await setupAndStartRecordingWithEvents(
      filter: filter,
      config: regionConfig,
      outputPath: outputPath,
      cropRect: region
    )
  }

  /// Find the iOS Simulator window
  public func findSimulatorWindow() async throws -> WindowInfo {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

    // Look for Simulator windows
    let simulatorWindows = content.windows.filter { window in
      guard let ownerName = window.owningApplication?.applicationName else { return false }
      return ownerName == "Simulator"
    }

    // Find the main simulator window (has content, not a menu)
    guard let window = simulatorWindows.first(where: {
      $0.frame.width > 100 && $0.frame.height > 100
    }) else {
      throw RecorderError.appNotFound("Simulator")
    }

    return WindowInfo(
      windowID: window.windowID,
      title: window.title,
      ownerName: window.owningApplication?.applicationName,
      frame: window.frame
    )
  }

  private func startRecording(
    display: SCDisplay,
    config: RecordingConfig,
    outputPath: String?
  ) async throws -> URL {
    // Create content filter for the display
    let filter = SCContentFilter(display: display, excludingWindows: [])

    return try await setupAndStartRecording(filter: filter, config: config, outputPath: outputPath, cropRect: nil)
  }

  private func startRecording(
    window: SCWindow,
    config: RecordingConfig,
    outputPath: String?
  ) async throws -> URL {
    // Create content filter for the window
    let filter = SCContentFilter(desktopIndependentWindow: window)

    // Use window dimensions if config has 0 width/height
    let effectiveConfig: RecordingConfig
    if config.width == 0 || config.height == 0 {
      effectiveConfig = RecordingConfig(
        width: Int(window.frame.width),
        height: Int(window.frame.height),
        fps: config.fps,
        showsCursor: config.showsCursor,
        capturesAudio: config.capturesAudio,
        quality: config.quality
      )
    } else {
      effectiveConfig = config
    }

    return try await setupAndStartRecording(filter: filter, config: effectiveConfig, outputPath: outputPath, cropRect: nil)
  }

  private func setupAndStartRecording(
    filter: SCContentFilter,
    config: RecordingConfig,
    outputPath: String?,
    cropRect: CGRect?
  ) async throws -> URL {
    // Setup output URL
    let url: URL
    if let path = outputPath {
      url = URL(fileURLWithPath: path)
    } else {
      let tempDir = FileManager.default.temporaryDirectory
      let fileName = "screen_recording_\(Date().timeIntervalSince1970).mp4"
      url = tempDir.appendingPathComponent(fileName)
    }
    outputURL = url

    // Remove existing file if present
    try? FileManager.default.removeItem(at: url)

    // Setup stream configuration
    let streamConfig = SCStreamConfiguration()
    streamConfig.width = config.width
    streamConfig.height = config.height
    streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
    streamConfig.showsCursor = config.showsCursor
    streamConfig.capturesAudio = config.capturesAudio
    streamConfig.pixelFormat = kCVPixelFormatType_32BGRA

    // Apply crop rect if specified
    if let rect = cropRect {
      streamConfig.sourceRect = rect
      streamConfig.width = Int(rect.width)
      streamConfig.height = Int(rect.height)
    }

    // Setup asset writer
    assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)

    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: config.width,
      AVVideoHeightKey: config.height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: config.quality.videoBitrate,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoMaxKeyFrameIntervalKey: config.fps * 2
      ]
    ]

    videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput?.expectsMediaDataInRealTime = true

    let pixelBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: config.width,
      kCVPixelBufferHeightKey as String: config.height
    ]

    pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: videoInput!,
      sourcePixelBufferAttributes: pixelBufferAttributes
    )

    assetWriter?.add(videoInput!)

    // Setup stream output handler
    let output = StreamOutput(
      assetWriter: assetWriter!,
      videoInput: videoInput!,
      adaptor: pixelBufferAdaptor!
    )
    streamOutput = output

    // Create and start stream
    stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
    try stream?.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.argus.screenrecorder"))

    assetWriter?.startWriting()
    assetWriter?.startSession(atSourceTime: .zero)

    try await stream?.startCapture()

    state = .recording
    return url
  }

  /// Setup and start recording with event stream for duration synchronization
  private func setupAndStartRecordingWithEvents(
    filter: SCContentFilter,
    config: RecordingConfig,
    outputPath: String?,
    cropRect: CGRect?
  ) async throws -> AsyncStream<RecordingEvent> {
    // Setup output URL
    let url: URL
    if let path = outputPath {
      url = URL(fileURLWithPath: path)
    } else {
      let tempDir = FileManager.default.temporaryDirectory
      let fileName = "screen_recording_\(Date().timeIntervalSince1970).mp4"
      url = tempDir.appendingPathComponent(fileName)
    }
    outputURL = url

    // Remove existing file if present
    try? FileManager.default.removeItem(at: url)

    // Setup stream configuration
    let streamConfig = SCStreamConfiguration()
    streamConfig.width = config.width
    streamConfig.height = config.height
    streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
    streamConfig.showsCursor = config.showsCursor
    streamConfig.capturesAudio = config.capturesAudio
    streamConfig.pixelFormat = kCVPixelFormatType_32BGRA

    // Apply crop rect if specified
    if let rect = cropRect {
      streamConfig.sourceRect = rect
      streamConfig.width = Int(rect.width)
      streamConfig.height = Int(rect.height)
    }

    // Setup asset writer
    assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)

    let videoSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: config.width,
      AVVideoHeightKey: config.height,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: config.quality.videoBitrate,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoMaxKeyFrameIntervalKey: config.fps * 2
      ]
    ]

    videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoInput?.expectsMediaDataInRealTime = true

    let pixelBufferAttributes: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: config.width,
      kCVPixelBufferHeightKey as String: config.height
    ]

    pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: videoInput!,
      sourcePixelBufferAttributes: pixelBufferAttributes
    )

    assetWriter?.add(videoInput!)

    // Create the async stream for events
    let (stream, continuation) = AsyncStream<RecordingEvent>.makeStream()
    self.eventContinuation = continuation

    // Capture continuation for first-frame callback (must be thread-safe)
    let capturedContinuation = continuation

    // Setup stream output handler with first-frame callback
    let output = StreamOutput(
      assetWriter: assetWriter!,
      videoInput: videoInput!,
      adaptor: pixelBufferAdaptor!,
      onFirstFrame: { [weak self] in
        // This runs on the DispatchQueue, hop to the actor's context
        Task {
          guard let self = self else { return }
          // Only yield if we're still recording
          let currentState = await self.getState()
          if case .recording = currentState {
            capturedContinuation.yield(.firstFrameCaptured)
          }
        }
      }
    )
    streamOutput = output

    // Create and start stream
    self.stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
    try self.stream?.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "com.argus.screenrecorder"))

    assetWriter?.startWriting()
    assetWriter?.startSession(atSourceTime: .zero)

    try await self.stream?.startCapture()
    FileHandle.standardError.write("Debug: startCapture() succeeded, assetWriter status: \(assetWriter?.status.rawValue ?? -1)\n".data(using: .utf8)!)

    state = .recording

    // Yield started event
    continuation.yield(.started(url))

    return stream
  }

  /// Stop the current recording
  public func stopRecording() async throws -> URL {
    guard case .recording = state else {
      throw RecorderError.notRecording
    }

    state = .stopping

    // Stop accepting frames immediately to prevent late frames
    streamOutput?.stopWriting()

    // Stop the stream
    try await stream?.stopCapture()

    // Finish writing
    videoInput?.markAsFinished()

    // Only wait for finishWriting if we have an active asset writer
    // Without this check, if assetWriter is nil the continuation is never resumed (leak!)
    if let writer = assetWriter {
      await withCheckedContinuation { continuation in
        writer.finishWriting {
          continuation.resume()
        }
      }
    }

    // Cleanup
    stream = nil
    streamOutput = nil
    assetWriter = nil
    videoInput = nil
    pixelBufferAdaptor = nil

    guard let url = outputURL else {
      // Signal error through event stream if active
      eventContinuation?.yield(.error("No output URL"))
      eventContinuation?.finish()
      eventContinuation = nil
      state = .error("No output URL")
      throw RecorderError.noOutputURL
    }

    // Signal completion through event stream if active
    eventContinuation?.yield(.stopped(url))
    eventContinuation?.finish()
    eventContinuation = nil

    state = .finished(url)
    outputURL = nil

    // Reset state for next recording
    state = .idle

    return url
  }

  /// Get current recording state
  public func getState() -> RecordingState {
    return state
  }

  /// Force reset the recorder to idle state, cleaning up any partial state.
  /// Call this before starting a new recording to ensure clean state.
  /// This handles cases where the recorder got stuck in preparing/stopping states.
  public func forceReset() async {
    // Stop stream output writing first to prevent any late frames
    streamOutput?.stopWriting()

    // Stop any active stream - log errors instead of silently ignoring
    if let activeStream = self.stream {
      do {
        try await activeStream.stopCapture()
      } catch {
        FileHandle.standardError.write("Warning: Failed to stop capture during reset: \(error.localizedDescription)\n".data(using: .utf8)!)
      }

      // Try to remove the output handler to fully release the stream
      if let output = streamOutput {
        do {
          try activeStream.removeStreamOutput(output, type: .screen)
        } catch {
          // This might fail if stream is already stopped, that's OK
        }
      }
    }

    // Cancel video input
    videoInput?.markAsFinished()

    // Cancel asset writer if active
    if let writer = assetWriter, writer.status == .writing {
      writer.cancelWriting()
    }

    // Finish any pending event stream
    eventContinuation?.finish()

    // Clear all references
    stream = nil
    streamOutput = nil
    assetWriter = nil
    videoInput = nil
    pixelBufferAdaptor = nil
    outputURL = nil
    eventContinuation = nil

    // Force state to idle
    state = .idle

    // Small delay to allow ScreenCaptureKit to fully release resources
    // This helps prevent issues when starting a new capture immediately after
    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
  }

  public enum RecorderError: Error, LocalizedError {
    case alreadyRecording
    case notRecording
    case noDisplayAvailable
    case displayNotFound
    case windowNotFound
    case appNotFound(String)
    case noOutputURL
    case streamError(String)

    public var errorDescription: String? {
      switch self {
      case .alreadyRecording:
        return "Recording is already in progress"
      case .notRecording:
        return "No recording in progress"
      case .noDisplayAvailable:
        return "No display available for recording"
      case .displayNotFound:
        return "Specified display not found"
      case .windowNotFound:
        return "Specified window not found"
      case .appNotFound(let name):
        return "Application '\(name)' not found or has no visible windows"
      case .noOutputURL:
        return "No output URL available"
      case .streamError(let message):
        return "Stream error: \(message)"
      }
    }
  }
}

// MARK: - Stream Output Handler

@available(macOS 14.0, *)
private class StreamOutput: NSObject, SCStreamOutput {
  private let assetWriter: AVAssetWriter
  private let videoInput: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private var firstTimestamp: CMTime?

  // First-frame callback for duration synchronization
  private let onFirstFrame: (@Sendable () -> Void)?
  private var hasNotifiedFirstFrame = false
  private let notificationLock = NSLock()

  // Stop flag to prevent writing frames after stop is requested
  private var isStopped = false
  private let stoppedLock = NSLock()

  init(
    assetWriter: AVAssetWriter,
    videoInput: AVAssetWriterInput,
    adaptor: AVAssetWriterInputPixelBufferAdaptor,
    onFirstFrame: (@Sendable () -> Void)? = nil
  ) {
    self.assetWriter = assetWriter
    self.videoInput = videoInput
    self.adaptor = adaptor
    self.onFirstFrame = onFirstFrame
    super.init()
  }

  /// Signal that recording should stop - no more frames will be written
  func stopWriting() {
    stoppedLock.lock()
    isStopped = true
    stoppedLock.unlock()
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen else { return }

    // Check if stopped (thread-safe)
    stoppedLock.lock()
    let stopped = isStopped
    stoppedLock.unlock()
    guard !stopped else { return }

    guard assetWriter.status == .writing else {
      FileHandle.standardError.write("Debug: Frame dropped - assetWriter status: \(assetWriter.status.rawValue)\n".data(using: .utf8)!)
      return
    }
    guard videoInput.isReadyForMoreMediaData else {
      FileHandle.standardError.write("Debug: Frame dropped - videoInput not ready\n".data(using: .utf8)!)
      return
    }

    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

    if firstTimestamp == nil {
      firstTimestamp = timestamp

      // Thread-safe first frame notification (only once)
      if let callback = onFirstFrame {
        notificationLock.lock()
        let shouldNotify = !hasNotifiedFirstFrame
        hasNotifiedFirstFrame = true
        notificationLock.unlock()

        if shouldNotify {
          callback()
        }
      }
    }

    let relativeTime = CMTimeSubtract(timestamp, firstTimestamp!)

    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

    adaptor.append(pixelBuffer, withPresentationTime: relativeTime)
  }
}
