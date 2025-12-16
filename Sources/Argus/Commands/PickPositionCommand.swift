import AppKit
import ArgumentParser
import Foundation

// MARK: - Pick Position Command

struct PickPositionCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pick-position",
    abstract: "Launch crosshair UI to pick a screen position"
  )

  func run() throws {
    FileHandle.standardError.write("[PickPosition] run() called\n".data(using: .utf8)!)

    // IMPORTANT: We must run AppKit on the main thread.
    // ArgumentParser may call run() on a background thread when using async main,
    // so we use DispatchQueue.main.sync to hop to the main thread.
    // NSApp.run() then blocks until NSApp.stop() is called.
    DispatchQueue.main.sync {
      FileHandle.standardError.write("[PickPosition] Inside DispatchQueue.main.sync\n".data(using: .utf8)!)

      let app = NSApplication.shared
      app.setActivationPolicy(.regular)

      let delegate = PickPositionAppDelegate()
      app.delegate = delegate

      FileHandle.standardError.write("[PickPosition] Calling app.run()\n".data(using: .utf8)!)
      app.run()  // This blocks until NSApp.stop() is called
      FileHandle.standardError.write("[PickPosition] app.run() returned\n".data(using: .utf8)!)
    }
  }
}

// MARK: - Position Result

struct PositionResult: Codable {
  let x: Int
  let y: Int
  let screenWidth: Int
  let screenHeight: Int
  let displayID: UInt32
  let scaleFactor: Double
  let isMain: Bool
  let cancelled: Bool
}

// MARK: - App Delegate

class PickPositionAppDelegate: NSObject, NSApplicationDelegate {
  private var overlayWindow: PickPositionOverlayWindow?

  private func log(_ message: String) {
    let logFile = "/tmp/argus-pick-position.log"
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

  func applicationDidFinishLaunching(_ notification: Notification) {
    log("applicationDidFinishLaunching")

    guard let mainScreen = NSScreen.main else {
      log("ERROR: No main screen!")
      outputResultAndExit(cancelled: true)
      return
    }

    log("Main screen found: \(mainScreen.frame)")

    let window = PickPositionOverlayWindow(screen: mainScreen)
    let view = PickPositionView(frame: mainScreen.frame)

    view.onPositionPicked = { [weak self] position in
      self?.log("onPositionPicked callback triggered at \(position)")
      self?.handlePositionPicked(position, screen: mainScreen)
    }

    view.onCancel = { [weak self] in
      self?.log("onCancel callback triggered")
      self?.handleCancel()
    }

    window.contentView = view
    log("Setting up window")
    window.makeKeyAndOrderFront(nil)
    log("makeKeyAndOrderFront called")
    window.makeFirstResponder(view)
    log("makeFirstResponder called")

    self.overlayWindow = window

    NSApp.activate(ignoringOtherApps: true)
    log("NSApp.activate called")
    NSCursor.crosshair.push()
    log("Crosshair cursor pushed - waiting for user input")
  }

  private func handlePositionPicked(_ position: NSPoint, screen: NSScreen) {
    log("handlePositionPicked called with position \(position)")
    NSCursor.pop()
    overlayWindow?.close()

    let displayID =
      screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
      ?? CGMainDisplayID()

    // Convert Cocoa coordinates (bottom-left origin) to CG coordinates (top-left origin)
    let cgY = screen.frame.height - (position.y - screen.frame.origin.y)
    let cgX = position.x - screen.frame.origin.x

    log("Creating result with x=\(Int(cgX)), y=\(Int(cgY)), cancelled=false")

    let result = PositionResult(
      x: Int(cgX),
      y: Int(cgY),
      screenWidth: Int(screen.frame.width),
      screenHeight: Int(screen.frame.height),
      displayID: displayID,
      scaleFactor: Double(screen.backingScaleFactor),
      isMain: screen == NSScreen.main,
      cancelled: false
    )

    log("Calling outputResult")
    outputResult(result)
    log("Calling NSApp.stop")
    NSApp.stop(nil)
    log("NSApp.stop returned")
  }

  private func handleCancel() {
    log("handleCancel called")
    NSCursor.pop()
    overlayWindow?.close()
    outputResultAndExit(cancelled: true)
  }

  private func outputResultAndExit(cancelled: Bool) {
    let result = PositionResult(
      x: 0,
      y: 0,
      screenWidth: 0,
      screenHeight: 0,
      displayID: 0,
      scaleFactor: 1.0,
      isMain: false,
      cancelled: cancelled
    )
    outputResult(result)
    NSApp.stop(nil)
  }

  private func outputResult(_ result: PositionResult) {
    log("outputResult called with cancelled=\(result.cancelled)")
    let encoder = JSONEncoder()
    if let data = try? encoder.encode(result),
      let json = String(data: data, encoding: .utf8)
    {
      log("JSON output: \(json)")
      // Write directly to stdout and flush immediately to ensure output before any crash
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write("\n".data(using: .utf8)!)
      try? FileHandle.standardOutput.synchronize()
      log("stdout written and flushed")
    } else {
      log("ERROR: Failed to encode JSON")
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }
}

// MARK: - Overlay Window

class PickPositionOverlayWindow: NSWindow {
  convenience init(screen: NSScreen) {
    self.init(
      contentRect: screen.frame,
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )

    self.setFrame(screen.frame, display: true)
    self.level = .screenSaver
    self.isOpaque = false
    self.backgroundColor = NSColor.black.withAlphaComponent(0.3)
    self.ignoresMouseEvents = false
    self.acceptsMouseMovedEvents = true
    self.hasShadow = false
    self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
  }
}

// MARK: - Position View

class PickPositionView: NSView {
  private var crosshairPosition: NSPoint?
  nonisolated(unsafe) private var keyMonitor: Any?

  private let crosshairColor = NSColor.white

  var onPositionPicked: ((NSPoint) -> Void)?
  var onCancel: (() -> Void)?

  override var acceptsFirstResponder: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupTrackingArea()
    setupKeyMonitor()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupTrackingArea()
    setupKeyMonitor()
  }

  deinit {
    if let monitor = keyMonitor {
      NSEvent.removeMonitor(monitor)
    }
  }

  private func setupTrackingArea() {
    let trackingArea = NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
  }

  private func setupKeyMonitor() {
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if event.keyCode == 53 {  // ESC key
        self?.onCancel?()
        return nil  // Consume the event
      }
      return event
    }
  }

  // MARK: - Drawing

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    guard let context = NSGraphicsContext.current?.cgContext else { return }

    // Draw semi-transparent overlay
    context.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
    context.fill(bounds)

    // Draw crosshair at cursor position
    if let position = crosshairPosition {
      drawCrosshair(at: position, in: context)
    }

    // Draw instructions
    drawInstructions(in: context)
  }

  private func drawCrosshair(at point: NSPoint, in context: CGContext) {
    let lineLength: CGFloat = 20
    let gapSize: CGFloat = 10

    context.setStrokeColor(crosshairColor.cgColor)
    context.setLineWidth(1)
    context.setLineDash(phase: 0, lengths: [])

    // Horizontal lines
    context.move(to: CGPoint(x: point.x - lineLength - gapSize, y: point.y))
    context.addLine(to: CGPoint(x: point.x - gapSize, y: point.y))
    context.move(to: CGPoint(x: point.x + gapSize, y: point.y))
    context.addLine(to: CGPoint(x: point.x + lineLength + gapSize, y: point.y))

    // Vertical lines
    context.move(to: CGPoint(x: point.x, y: point.y - lineLength - gapSize))
    context.addLine(to: CGPoint(x: point.x, y: point.y - gapSize))
    context.move(to: CGPoint(x: point.x, y: point.y + gapSize))
    context.addLine(to: CGPoint(x: point.x, y: point.y + lineLength + gapSize))

    context.strokePath()

    // Draw center dot
    context.setFillColor(crosshairColor.cgColor)
    context.fillEllipse(in: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))

    // Draw coordinates
    let coordText = "(\(Int(point.x)), \(Int(point.y)))"
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
      .foregroundColor: NSColor.white,
    ]

    let textSize = coordText.size(withAttributes: attributes)
    let textPoint = NSPoint(x: point.x + 15, y: point.y - textSize.height - 5)

    // Background for coordinates
    let bgRect = NSRect(
      x: textPoint.x - 4,
      y: textPoint.y - 2,
      width: textSize.width + 8,
      height: textSize.height + 4
    )

    NSColor.black.withAlphaComponent(0.6).setFill()
    NSBezierPath(roundedRect: bgRect, xRadius: 3, yRadius: 3).fill()

    coordText.draw(at: textPoint, withAttributes: attributes)
  }

  private func drawInstructions(in context: CGContext) {
    let instructions = "Click to mark position • ESC to cancel"
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 14, weight: .medium),
      .foregroundColor: NSColor.white,
    ]

    let textSize = instructions.size(withAttributes: attributes)
    let textRect = NSRect(
      x: bounds.midX - textSize.width / 2 - 16,
      y: bounds.maxY - 60,
      width: textSize.width + 32,
      height: textSize.height + 16
    )

    context.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
    let bgPath = NSBezierPath(roundedRect: textRect, xRadius: 8, yRadius: 8)
    bgPath.fill()

    instructions.draw(
      at: NSPoint(x: textRect.minX + 16, y: textRect.minY + 8),
      withAttributes: attributes
    )
  }

  // MARK: - Mouse Events

  override func mouseDown(with event: NSEvent) {
    FileHandle.standardError.write("[PickPositionView] mouseDown!\n".data(using: .utf8)!)
    let position = convert(event.locationInWindow, from: nil)
    FileHandle.standardError.write("[PickPositionView] position: \(position)\n".data(using: .utf8)!)
    onPositionPicked?(position)
  }

  override func mouseMoved(with event: NSEvent) {
    crosshairPosition = convert(event.locationInWindow, from: nil)
    needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    crosshairPosition = nil
    needsDisplay = true
  }

  // MARK: - Keyboard Events

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {  // ESC key
      onCancel?()
    }
  }
}
