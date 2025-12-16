// Sources/ArgusMCP/Capture/CursorContextCapture.swift

import AppKit
import Foundation

/// Captures cursor context with both a focused region and full screen
/// for visual UI understanding in designer workflows.
public actor CursorContextCapture {

  // MARK: - Types

  /// Result of a cursor context capture
  public struct CaptureResult: Sendable {
    /// Path to JPEG of the region centered on cursor
    public let regionImagePath: URL
    /// Path to JPEG of the full screen
    public let fullScreenImagePath: URL
    /// Cursor position in screen coordinates (CG origin - top-left)
    public let cursorPosition: CGPoint
    /// The screen where cursor is located
    public let screenInfo: ScreenInfo
    /// The actual capture rect used (may differ from ideal due to edge clamping)
    public let actualRegionRect: CGRect
    /// Time taken for capture in seconds
    public let captureTime: Double
  }

  /// Information about the screen
  public struct ScreenInfo: Sendable {
    public let displayID: CGDirectDisplayID
    public let width: Int
    public let height: Int
    public let scaleFactor: Double
    public let isMain: Bool
  }

  // MARK: - Errors

  public enum CaptureError: Error, LocalizedError {
    case noScreenFound
    case screencaptureFailed(String)
    case imageEncodingFailed
    case cursorNotOnAnyScreen
    case positionPickerCancelled

    public var errorDescription: String? {
      switch self {
      case .noScreenFound:
        return "No screen found"
      case .screencaptureFailed(let reason):
        return "Screenshot capture failed: \(reason)"
      case .imageEncodingFailed:
        return "Failed to encode image to JPEG"
      case .cursorNotOnAnyScreen:
        return "Cursor position not on any detected screen"
      case .positionPickerCancelled:
        return "Position picking was cancelled by user"
      }
    }
  }

  // MARK: - Configuration

  /// Region size in points (not pixels)
  private let regionSize: CGFloat = 200

  // MARK: - Initialization

  public init() {}

  // MARK: - Public API

  /// Screen properties extracted on main actor (Sendable)
  private struct ScreenProperties: Sendable {
    let frame: CGRect
    let scaleFactor: Double
    let isMain: Bool
    let displayID: CGDirectDisplayID
  }

  /// Capture cursor context - region around cursor and full screen
  /// - Parameter usePositionPicker: If true (default), shows a crosshair UI for the user to click
  ///   and mark the position they want to capture. If false, captures at current cursor position.
  public func capture(usePositionPicker: Bool = true) async throws -> CaptureResult {
    let startTime = Date()

    let cursorLocationCG: CGPoint
    let screenProps: ScreenProperties

    if usePositionPicker {
      // Show crosshair UI and wait for user to click
      do {
        let pickResult = try await PositionPicker.pickPosition()
        cursorLocationCG = pickResult.position
        screenProps = ScreenProperties(
          frame: pickResult.screenFrame,
          scaleFactor: pickResult.scaleFactor,
          isMain: pickResult.isMain,
          displayID: pickResult.displayID
        )
      } catch PositionPicker.PickerError.cancelled {
        // Only convert explicit cancellation to our cancelled error
        throw CaptureError.positionPickerCancelled
      } catch let error as PositionPicker.PickerError {
        // Re-throw other picker errors with their actual message
        throw CaptureError.screencaptureFailed(error.localizedDescription)
      }
    } else {
      // Get current cursor position without UI
      guard let (cursorLocationCocoa, props) = await getScreenPropertiesAtCursor() else {
        throw CaptureError.cursorNotOnAnyScreen
      }
      cursorLocationCG = cocoaToCG(cursorLocationCocoa, screenFrame: props.frame)
      screenProps = props
    }

    // Calculate clamped capture region
    let screenBounds = CGRect(origin: .zero, size: screenProps.frame.size)
    let captureRect = clampedCaptureRect(
      center: cursorLocationCG,
      size: regionSize,
      screenBounds: screenBounds
    )

    // Capture both images using screencapture CLI in parallel
    async let regionCapture = captureRegion(rect: captureRect, displayID: screenProps.displayID)
    async let fullScreenCapture = captureFullScreen(displayID: screenProps.displayID)

    let (regionURL, fullScreenURL) = try await (regionCapture, fullScreenCapture)

    let captureTime = Date().timeIntervalSince(startTime)

    return CaptureResult(
      regionImagePath: regionURL,
      fullScreenImagePath: fullScreenURL,
      cursorPosition: cursorLocationCG,
      screenInfo: ScreenInfo(
        displayID: screenProps.displayID,
        width: Int(screenProps.frame.width),
        height: Int(screenProps.frame.height),
        scaleFactor: screenProps.scaleFactor,
        isMain: screenProps.isMain
      ),
      actualRegionRect: captureRect,
      captureTime: captureTime
    )
  }

  // MARK: - Private Methods

  /// Get cursor position and screen properties in a single MainActor call
  @MainActor
  private func getScreenPropertiesAtCursor() -> (NSPoint, ScreenProperties)? {
    let cursorLocation = NSEvent.mouseLocation

    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursorLocation) }) else {
      return nil
    }

    let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
      ?? CGMainDisplayID()

    let props = ScreenProperties(
      frame: screen.frame,
      scaleFactor: Double(screen.backingScaleFactor),
      isMain: screen == NSScreen.main,
      displayID: displayID
    )

    return (cursorLocation, props)
  }

  /// Convert Cocoa coordinates (bottom-left origin) to CG coordinates (top-left origin)
  private func cocoaToCG(_ point: NSPoint, screenFrame: CGRect) -> CGPoint {
    // Cocoa Y is from bottom, CG Y is from top
    let cgY = screenFrame.height - (point.y - screenFrame.origin.y)
    let cgX = point.x - screenFrame.origin.x
    return CGPoint(x: cgX, y: cgY)
  }

  /// Calculate capture rect clamped to screen bounds
  private func clampedCaptureRect(center: CGPoint, size: CGFloat, screenBounds: CGRect) -> CGRect {
    let halfSize = size / 2

    var rect = CGRect(
      x: center.x - halfSize,
      y: center.y - halfSize,
      width: size,
      height: size
    )

    // Clamp to screen bounds
    if rect.minX < screenBounds.minX {
      rect.origin.x = screenBounds.minX
    }
    if rect.minY < screenBounds.minY {
      rect.origin.y = screenBounds.minY
    }
    if rect.maxX > screenBounds.maxX {
      rect.origin.x = max(screenBounds.minX, screenBounds.maxX - size)
    }
    if rect.maxY > screenBounds.maxY {
      rect.origin.y = max(screenBounds.minY, screenBounds.maxY - size)
    }

    // Constrain size if screen is smaller than region size
    rect.size.width = min(rect.width, screenBounds.width)
    rect.size.height = min(rect.height, screenBounds.height)

    return rect.intersection(screenBounds)
  }

  /// Capture a region of the screen using screencapture CLI
  private func captureRegion(rect: CGRect, displayID: CGDirectDisplayID) async throws -> URL {
    let tempFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("argus-region-\(UUID().uuidString).jpg")

    // screencapture -R x,y,w,h -C -t jpg -x outputfile
    // -R: region capture
    // -C: include cursor
    // -t jpg: JPEG format
    // -x: no sound
    // -D: display ID
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = [
      "-R",
      "\(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height))",
      "-C",
      "-t", "jpg",
      "-x",
      "-D", "\(displayID)",
      tempFile.path,
    ]

    let errorPipe = Pipe()
    process.standardError = errorPipe
    process.standardOutput = FileHandle.nullDevice

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
      let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
      throw CaptureError.screencaptureFailed(errorString.isEmpty ? "Exit code \(process.terminationStatus)" : errorString)
    }

    guard FileManager.default.fileExists(atPath: tempFile.path) else {
      throw CaptureError.screencaptureFailed("Output file missing")
    }

    return tempFile
  }

  /// Capture full screen using screencapture CLI
  private func captureFullScreen(displayID: CGDirectDisplayID) async throws -> URL {
    let tempFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("argus-fullscreen-\(UUID().uuidString).jpg")

    // screencapture -C -t jpg -x -D displayID outputfile
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = [
      "-C",
      "-t", "jpg",
      "-x",
      "-D", "\(displayID)",
      tempFile.path,
    ]

    let errorPipe = Pipe()
    process.standardError = errorPipe
    process.standardOutput = FileHandle.nullDevice

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
      let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
      throw CaptureError.screencaptureFailed(errorString.isEmpty ? "Exit code \(process.terminationStatus)" : errorString)
    }

    guard FileManager.default.fileExists(atPath: tempFile.path) else {
      throw CaptureError.screencaptureFailed("Output file missing")
    }

    return tempFile
  }
}
