// Sources/ArgusMCP/Capture/PositionPicker.swift

import CoreGraphics
import Foundation

/// Displays a crosshair overlay for the user to click and mark a position.
/// Used by CursorContextCapture to let users select exactly what they want to capture.
///
/// This spawns the `argus pick-position` subprocess which handles the UI,
/// avoiding blocking the MCP server's event loop.
public enum PositionPicker {

  // MARK: - Errors

  public enum PickerError: Error, LocalizedError {
    case cancelled
    case noScreenFound
    case pickingFailed(String)
    case executableNotFound

    public var errorDescription: String? {
      switch self {
      case .cancelled:
        return "Position picking was cancelled"
      case .noScreenFound:
        return "No screen found"
      case .pickingFailed(let reason):
        return "Position picking failed: \(reason)"
      case .executableNotFound:
        return "Could not find argus executable"
      }
    }
  }

  // MARK: - Result

  public struct PickResult: Sendable {
    /// Position in CG coordinates (top-left origin) relative to the screen
    public let position: CGPoint
    /// The screen where the position was picked
    public let screenFrame: CGRect
    /// Display ID of the screen
    public let displayID: CGDirectDisplayID
    /// Scale factor of the screen
    public let scaleFactor: Double
    /// Whether this is the main screen
    public let isMain: Bool
  }

  // MARK: - Internal Result (matches PickPositionCommand output)

  private struct SubprocessResult: Codable {
    let x: Int
    let y: Int
    let screenWidth: Int
    let screenHeight: Int
    let displayID: UInt32
    let scaleFactor: Double
    let isMain: Bool
    let cancelled: Bool
  }

  // MARK: - Public API

  /// Shows a crosshair overlay and waits for the user to click a position.
  /// - Returns: The picked position and screen info
  /// - Throws: `PickerError.cancelled` if user presses ESC
  public static func pickPosition() async throws -> PickResult {
    // Find the argus executable path
    let executablePath = ProcessInfo.processInfo.arguments[0]

    FileHandle.standardError.write("[PositionPicker] Launching subprocess: \(executablePath) pick-position\n".data(using: .utf8)!)

    // Run the subprocess
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = ["pick-position"]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    do {
      try process.run()
      FileHandle.standardError.write("[PositionPicker] Subprocess launched with PID \(process.processIdentifier)\n".data(using: .utf8)!)
    } catch {
      throw PickerError.pickingFailed("Failed to launch picker: \(error.localizedDescription)")
    }

    // Helper to write to log file
    func logToFile(_ message: String) {
      let logFile = "/tmp/argus-position-picker-mcp.log"
      let timestamp = ISO8601DateFormatter().string(from: Date())
      let line = "[\(timestamp)] \(message)\n"
      if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFile) {
          if let handle = FileHandle(forWritingAtPath: logFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
          }
        } else {
          FileManager.default.createFile(atPath: logFile, contents: data)
        }
      }
    }

    // Wait for completion asynchronously
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        logToFile("Waiting for process to exit...")
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        logToFile("Process exited with status \(process.terminationStatus)")
        logToFile("stderr: \(String(data: errorData, encoding: .utf8) ?? "nil")")
        logToFile("stdout: \(String(data: outputData, encoding: .utf8) ?? "nil")")

        // Try to parse JSON output first - if we got valid output with cancelled=false,
        // treat it as success even if the process crashed during cleanup (non-zero exit code).
        // This handles the case where AppKit crashes after NSApp.stop() but output was written.
        if let outputString = String(data: outputData, encoding: .utf8),
          !outputString.isEmpty
        {
          do {
            let decoder = JSONDecoder()
            logToFile("Attempting to decode JSON...")
            let result = try decoder.decode(SubprocessResult.self, from: outputData)
            logToFile("Decoded result: cancelled=\(result.cancelled), x=\(result.x), y=\(result.y)")

            if result.cancelled {
              logToFile("Result shows cancelled=true, throwing cancelled error")
              continuation.resume(throwing: PickerError.cancelled)
              return
            }
            logToFile("Result shows cancelled=false, creating PickResult")

            // Success! We got valid output with cancelled=false
            let pickResult = PickResult(
              position: CGPoint(x: result.x, y: result.y),
              screenFrame: CGRect(
                x: 0, y: 0,
                width: result.screenWidth,
                height: result.screenHeight
              ),
              displayID: CGDirectDisplayID(result.displayID),
              scaleFactor: result.scaleFactor,
              isMain: result.isMain
            )

            if process.terminationStatus != 0 {
              logToFile("Note: Process exited with status \(process.terminationStatus) but output was valid")
            }

            continuation.resume(returning: pickResult)
            return
          } catch {
            logToFile("Failed to parse JSON: \(error.localizedDescription)")
            // Fall through to check exit status
          }
        }

        // No valid output - check exit status for error details
        guard process.terminationStatus == 0 else {
          let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
          continuation.resume(
            throwing: PickerError.pickingFailed("Process failed with status \(process.terminationStatus): \(errorString)"))
          return
        }

        // Process succeeded but no output
        continuation.resume(throwing: PickerError.pickingFailed("No output from picker"))
      }
    }
  }
}
