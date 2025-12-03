import AppKit
import Foundation

// MARK: - Selection Result

struct SelectionResult: Codable {
  let x: Int
  let y: Int
  let width: Int
  let height: Int
  let screenWidth: Int
  let screenHeight: Int
  let cancelled: Bool
}

// MARK: - Selection Overlay Window

class SelectionOverlayWindow: NSWindow {
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

// MARK: - Selection View

class SelectionView: NSView {
  private var startPoint: NSPoint?
  private var currentPoint: NSPoint?
  private var isSelecting = false
  private var crosshairPosition: NSPoint?

  private let selectionColor = NSColor.systemBlue
  private let crosshairColor = NSColor.white
  private let gridColor = NSColor.white.withAlphaComponent(0.3)

  var onSelectionComplete: ((NSRect) -> Void)?
  var onCancel: (() -> Void)?

  override var acceptsFirstResponder: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setupTrackingArea()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupTrackingArea()
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

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)

    guard let context = NSGraphicsContext.current?.cgContext else { return }

    // Draw semi-transparent overlay
    context.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
    context.fill(bounds)

    // Draw selection rectangle if selecting
    if let start = startPoint, let current = currentPoint, isSelecting {
      let selectionRect = rectFromPoints(start, current)

      // Clear the selection area (make it transparent)
      context.setBlendMode(.clear)
      context.fill(selectionRect)
      context.setBlendMode(.normal)

      // Draw selection border with animated dash
      context.setStrokeColor(selectionColor.cgColor)
      context.setLineWidth(2)
      context.setLineDash(phase: 0, lengths: [8, 4])
      context.stroke(selectionRect)

      // Draw white inner border
      context.setStrokeColor(NSColor.white.cgColor)
      context.setLineWidth(1)
      context.setLineDash(phase: 4, lengths: [8, 4])
      context.stroke(selectionRect.insetBy(dx: 1, dy: 1))

      // Draw corner handles
      let handleSize: CGFloat = 8
      context.setFillColor(NSColor.white.cgColor)
      context.setLineDash(phase: 0, lengths: [])

      let corners = [
        NSPoint(x: selectionRect.minX, y: selectionRect.minY),
        NSPoint(x: selectionRect.maxX, y: selectionRect.minY),
        NSPoint(x: selectionRect.minX, y: selectionRect.maxY),
        NSPoint(x: selectionRect.maxX, y: selectionRect.maxY)
      ]

      for corner in corners {
        let handleRect = NSRect(
          x: corner.x - handleSize / 2,
          y: corner.y - handleSize / 2,
          width: handleSize,
          height: handleSize
        )
        context.fillEllipse(in: handleRect)
        context.setStrokeColor(selectionColor.cgColor)
        context.strokeEllipse(in: handleRect)
      }

      // Draw dimensions label
      let width = Int(selectionRect.width)
      let height = Int(selectionRect.height)
      let dimensionText = "\(width) × \(height)"

      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.white
      ]

      let textSize = dimensionText.size(withAttributes: attributes)
      let textRect = NSRect(
        x: selectionRect.midX - textSize.width / 2 - 8,
        y: selectionRect.maxY + 8,
        width: textSize.width + 16,
        height: textSize.height + 8
      )

      // Background for text
      context.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
      let textBgPath = NSBezierPath(roundedRect: textRect, xRadius: 4, yRadius: 4)
      textBgPath.fill()

      dimensionText.draw(
        at: NSPoint(x: textRect.minX + 8, y: textRect.minY + 4),
        withAttributes: attributes
      )
    }

    // Draw crosshair when not selecting
    if !isSelecting, let position = crosshairPosition {
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
      .foregroundColor: NSColor.white
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
    let instructions = "Drag to select region • ESC to cancel"
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 14, weight: .medium),
      .foregroundColor: NSColor.white
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

  private func rectFromPoints(_ p1: NSPoint, _ p2: NSPoint) -> NSRect {
    let x = min(p1.x, p2.x)
    let y = min(p1.y, p2.y)
    let width = abs(p2.x - p1.x)
    let height = abs(p2.y - p1.y)
    return NSRect(x: x, y: y, width: width, height: height)
  }

  // MARK: - Mouse Events

  override func mouseDown(with event: NSEvent) {
    startPoint = convert(event.locationInWindow, from: nil)
    currentPoint = startPoint
    isSelecting = true
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    currentPoint = convert(event.locationInWindow, from: nil)
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    guard let start = startPoint, let end = currentPoint else { return }

    let selectionRect = rectFromPoints(start, end)

    // Minimum selection size
    if selectionRect.width >= 10 && selectionRect.height >= 10 {
      onSelectionComplete?(selectionRect)
    } else {
      // Reset if too small
      isSelecting = false
      startPoint = nil
      currentPoint = nil
      needsDisplay = true
    }
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
    if event.keyCode == 53 { // ESC key
      onCancel?()
    }
  }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
  var overlayWindows: [SelectionOverlayWindow] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Hide dock icon
    NSApp.setActivationPolicy(.accessory)

    // Create overlay on main screen
    guard let mainScreen = NSScreen.main else {
      outputError("No main screen found")
      NSApp.terminate(nil)
      return
    }

    let window = SelectionOverlayWindow(screen: mainScreen)
    let selectionView = SelectionView(frame: mainScreen.frame)

    selectionView.onSelectionComplete = { [weak self] rect in
      self?.completeSelection(rect: rect, screen: mainScreen)
    }

    selectionView.onCancel = {
      self.cancelSelection()
    }

    window.contentView = selectionView
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(selectionView)

    overlayWindows.append(window)

    // Activate app
    NSApp.activate(ignoringOtherApps: true)

    // Set crosshair cursor
    NSCursor.crosshair.set()
  }

  @MainActor
  private func completeSelection(rect: NSRect, screen: NSScreen) {
    // Convert to screen coordinates (flip Y axis for standard coordinate system)
    let screenHeight = screen.frame.height
    let flippedY = screenHeight - rect.maxY

    let result = SelectionResult(
      x: Int(rect.minX),
      y: Int(flippedY),
      width: Int(rect.width),
      height: Int(rect.height),
      screenWidth: Int(screen.frame.width),
      screenHeight: Int(screen.frame.height),
      cancelled: false
    )

    outputResult(result)
    NSApp.terminate(nil)
  }

  @MainActor
  private func cancelSelection() {
    let result = SelectionResult(
      x: 0,
      y: 0,
      width: 0,
      height: 0,
      screenWidth: 0,
      screenHeight: 0,
      cancelled: true
    )

    outputResult(result)
    NSApp.terminate(nil)
  }

  private func outputResult(_ result: SelectionResult) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys

    if let data = try? encoder.encode(result),
       let json = String(data: data, encoding: .utf8) {
      print(json)
    }
  }

  private func outputError(_ message: String) {
    FileHandle.standardError.write("Error: \(message)\n".data(using: .utf8)!)
  }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
