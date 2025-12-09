import Foundation

// MARK: - Message Types (shared with ArgusRecordingStatus)

/// Commands sent to the UI process via stdin
struct StatusCommand: Codable {
  enum CommandType: String, Codable {
    case configure   // Initial configuration
    case recording   // First frame captured, start timer
    case stop        // Recording stopped, close UI
    case analyzing   // Show analyzing spinner
    case success     // Show success checkmark (brief)
    case error       // Show error state (brief)
    case cancelled   // Show cancelled state (brief)
  }

  let type: CommandType
  let durationSeconds: Int?
}

/// Responses received from UI process via stdout
struct StatusResponse: Codable {
  enum ResponseType: String, Codable {
    case ready         // UI is displayed and ready
    case stopClicked   // User clicked stop button
    case timeout       // Max duration (30s) reached
    case cancelClicked // User clicked cancel button during analysis
  }

  let type: ResponseType
}

// MARK: - Recording Status UI Manager

/// Manages the recording status UI subprocess
@MainActor
public final class RecordingStatusUI {

  /// Events from the UI
  public enum UIEvent: Sendable {
    case ready         // UI is displayed
    case stopClicked   // User clicked Stop button
    case timeout       // Max duration reached
    case cancelClicked // User clicked Cancel button during analysis
    case processExited // UI process terminated
  }

  /// Configuration for launching the UI
  public struct Config: Sendable {
    public let durationSeconds: Int?

    public init(durationSeconds: Int? = nil) {
      self.durationSeconds = durationSeconds
    }
  }

  private var process: Process?
  private var inputPipe: Pipe?
  private var outputPipe: Pipe?
  private var eventContinuation: AsyncStream<UIEvent>.Continuation?
  private var analysisContinuation: AsyncStream<UIEvent>.Continuation?
  private var isRunning = false

  public init() {}

  /// Launch the UI and return an event stream
  public func launch(config: Config) async throws -> AsyncStream<UIEvent> {
    guard !isRunning else {
      throw RecordingStatusUIError.alreadyRunning
    }

    let executablePath = try getExecutablePath()

    process = Process()
    process?.executableURL = URL(fileURLWithPath: executablePath)

    inputPipe = Pipe()
    outputPipe = Pipe()
    process?.standardInput = inputPipe
    process?.standardOutput = outputPipe
    process?.standardError = FileHandle.nullDevice

    let (stream, continuation) = AsyncStream<UIEvent>.makeStream()
    self.eventContinuation = continuation

    // Handle process termination
    process?.terminationHandler = { [weak self] _ in
      Task { @MainActor in
        self?.eventContinuation?.yield(.processExited)
        self?.eventContinuation?.finish()
        self?.isRunning = false
      }
    }

    try process?.run()
    isRunning = true

    // Start reading responses in background
    startReadingOutput()

    // Send initial configuration
    let configCommand = StatusCommand(
      type: .configure,
      durationSeconds: config.durationSeconds
    )
    try await sendCommand(configCommand)

    return stream
  }

  /// Notify UI that recording has started (first frame captured)
  public func notifyRecordingStarted() async {
    let command = StatusCommand(type: .recording, durationSeconds: nil)
    try? await sendCommand(command)
  }

  /// Notify UI that recording has stopped
  public func notifyRecordingStopped() async {
    let command = StatusCommand(type: .stop, durationSeconds: nil)
    try? await sendCommand(command)
  }

  /// Notify UI to show analyzing state
  public func notifyAnalyzing() async {
    let command = StatusCommand(type: .analyzing, durationSeconds: nil)
    try? await sendCommand(command)
  }

  /// Notify UI to show success state
  public func notifySuccess() async {
    let command = StatusCommand(type: .success, durationSeconds: nil)
    try? await sendCommand(command)
  }

  /// Notify UI to show error state
  public func notifyError() async {
    let command = StatusCommand(type: .error, durationSeconds: nil)
    try? await sendCommand(command)
  }

  /// Notify UI to show cancelled state
  public func notifyCancelled() async {
    let command = StatusCommand(type: .cancelled, durationSeconds: nil)
    try? await sendCommand(command)
  }

  /// Get a fresh event stream for analysis phase
  /// This creates a new continuation that will receive cancelClicked events
  public func getAnalysisEventStream() -> AsyncStream<UIEvent> {
    let (stream, continuation) = AsyncStream<UIEvent>.makeStream()
    self.analysisContinuation = continuation
    return stream
  }

  /// Terminate the UI process
  public func terminate() {
    guard isRunning else { return }

    process?.terminate()
    process = nil
    inputPipe = nil
    outputPipe = nil
    isRunning = false

    eventContinuation?.finish()
    eventContinuation = nil
    analysisContinuation?.finish()
    analysisContinuation = nil
  }

  // MARK: - Private

  private func getExecutablePath() throws -> String {
    // Check common locations for argus-status executable

    // 1. Same directory as argus-mcp executable (for CLI tools, Bundle.main.executablePath is the path)
    if let execPath = Bundle.main.executablePath {
      let execDir = (execPath as NSString).deletingLastPathComponent
      let siblingPath = execDir + "/argus-status"
      if FileManager.default.fileExists(atPath: siblingPath) {
        return siblingPath
      }
    }

    // 2. Check relative to current working directory's .build/debug
    let cwdBuildPath = FileManager.default.currentDirectoryPath + "/.build/debug/argus-status"
    if FileManager.default.fileExists(atPath: cwdBuildPath) {
      return cwdBuildPath
    }

    // 3. /usr/local/bin
    if FileManager.default.fileExists(atPath: "/usr/local/bin/argus-status") {
      return "/usr/local/bin/argus-status"
    }

    // 4. ~/.local/bin
    let homeLocalPath = NSHomeDirectory() + "/.local/bin/argus-status"
    if FileManager.default.fileExists(atPath: homeLocalPath) {
      return homeLocalPath
    }

    // 5. Current working directory
    let cwdPath = FileManager.default.currentDirectoryPath + "/argus-status"
    if FileManager.default.fileExists(atPath: cwdPath) {
      return cwdPath
    }

    // 6. Try using 'which' to find it
    let whichProcess = Process()
    whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    whichProcess.arguments = ["argus-status"]
    let pipe = Pipe()
    whichProcess.standardOutput = pipe

    try? whichProcess.run()
    whichProcess.waitUntilExit()

    if whichProcess.terminationStatus == 0 {
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
         !path.isEmpty {
        return path
      }
    }

    throw RecordingStatusUIError.executableNotFound
  }

  private func sendCommand(_ command: StatusCommand) async throws {
    guard let inputPipe = inputPipe else {
      throw RecordingStatusUIError.notRunning
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys

    let data = try encoder.encode(command)
    let dataWithNewline = data + "\n".data(using: .utf8)!

    inputPipe.fileHandleForWriting.write(dataWithNewline)
  }

  private func startReadingOutput() {
    guard let outputPipe = outputPipe else { return }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let fileHandle = outputPipe.fileHandleForReading
      var buffer = Data()

      while true {
        let data = fileHandle.availableData
        guard !data.isEmpty else {
          // Pipe closed
          return
        }

        buffer.append(data)

        // Process complete lines (newline-delimited JSON)
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
          let lineData = Data(buffer.prefix(upTo: newlineIndex))
          buffer = Data(buffer.suffix(from: buffer.index(after: newlineIndex)))

          // Parse JSON response from this line
          if let response = try? JSONDecoder().decode(StatusResponse.self, from: lineData) {
            Task { @MainActor [weak self] in
              switch response.type {
              case .ready:
                self?.eventContinuation?.yield(.ready)
              case .stopClicked:
                self?.eventContinuation?.yield(.stopClicked)
              case .timeout:
                self?.eventContinuation?.yield(.timeout)
              case .cancelClicked:
                // Yield to BOTH continuations so analysis phase can receive cancel events
                self?.eventContinuation?.yield(.cancelClicked)
                self?.analysisContinuation?.yield(.cancelClicked)
              }
            }
          }
        }
      }
    }
  }
}

// MARK: - Errors

public enum RecordingStatusUIError: Error, LocalizedError {
  case executableNotFound
  case alreadyRunning
  case notRunning

  public var errorDescription: String? {
    switch self {
    case .executableNotFound:
      return "Could not find argus-status executable"
    case .alreadyRunning:
      return "Recording status UI is already running"
    case .notRunning:
      return "Recording status UI is not running"
    }
  }
}
