import AppKit
import SwiftUI

// MARK: - Message Types

/// Commands received from MCP server via stdin
struct StatusCommand: Codable {
  enum CommandType: String, Codable {
    case configure   // Initial configuration
    case recording   // First frame captured, start timer
    case stop        // Recording stopped, close UI
    case analyzing   // Show analyzing spinner
    case success     // Show success checkmark
    case error       // Show error state
    case cancelled   // Show cancelled state briefly
  }

  let type: CommandType
  let durationSeconds: Int?  // nil = count-up mode, non-nil = countdown mode
}

/// Responses sent to MCP server via stdout
struct StatusResponse: Codable {
  enum ResponseType: String, Codable {
    case ready         // UI is displayed and ready
    case stopClicked   // User clicked stop button
    case timeout       // Max duration (30s) reached
    case cancelClicked // User clicked cancel button during analysis
  }

  let type: ResponseType
}

// MARK: - Recording State

enum RecordingState: Equatable {
  case waiting
  case recording
  case analyzing
  case success
  case error
  case cancelled
}

// MARK: - State Manager

@MainActor
class RecordingStateManager: ObservableObject {
  @Published var state: RecordingState = .waiting
  @Published var elapsedSeconds: Int = 0
  @Published var targetDuration: Int?

  private var timer: Timer?
  private let maxDuration: Int = 30
  private let warningThreshold: Int = 25
  @Published var showWarning: Bool = false

  var onStopClicked: (() -> Void)?
  var onTimeout: (() -> Void)?
  var onCancelClicked: (() -> Void)?

  var timerText: String {
    let displaySeconds: Int
    if let target = targetDuration {
      displaySeconds = max(0, target - elapsedSeconds)
    } else {
      displaySeconds = elapsedSeconds
    }
    let minutes = displaySeconds / 60
    let seconds = displaySeconds % 60
    return String(format: "%02d:%02d", minutes, seconds)
  }

  func configure(durationSeconds: Int?) {
    targetDuration = durationSeconds
    state = .waiting
    elapsedSeconds = 0
    showWarning = false
  }

  func startRecording() {
    state = .recording
    elapsedSeconds = 0
    showWarning = false
    startTimer()
  }

  func setAnalyzing() {
    stopTimer()
    state = .analyzing
  }

  func setSuccess() {
    state = .success
  }

  func setError() {
    state = .error
  }

  func setCancelled() {
    state = .cancelled
  }

  func stop() {
    stopTimer()
    // Brief delay before closing
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      NSApp.terminate(nil)
    }
  }

  private func startTimer() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.timerTick()
      }
    }
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  private func timerTick() {
    elapsedSeconds += 1

    // Check for warning threshold (count-up mode only)
    if targetDuration == nil && elapsedSeconds == warningThreshold {
      showWarning = true
      // Reset warning after animation
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
        self?.showWarning = false
      }
    }

    // Check for max duration (count-up mode)
    if targetDuration == nil && elapsedSeconds >= maxDuration {
      onTimeout?()
      stopTimer()
    }
  }

  func handleStopClicked() {
    onStopClicked?()
  }

  func handleCancelClicked() {
    onCancelClicked?()
  }
}

// MARK: - Visual Effect Blur (Fallback for pre-macOS 26)

struct VisualEffectBlur: NSViewRepresentable {
  let material: NSVisualEffectView.Material
  let blendingMode: NSVisualEffectView.BlendingMode

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = blendingMode
    view.state = .active
    view.wantsLayer = true
    view.layer?.cornerRadius = 16
    view.layer?.masksToBounds = true
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Pulsing Dot View

struct PulsingDot: View {
  let color: Color
  let isPulsing: Bool

  @State private var opacity: Double = 1.0

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 12, height: 12)
      .opacity(opacity)
      .onChange(of: isPulsing) { _, newValue in
        if newValue {
          withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
            opacity = 0.3
          }
        } else {
          withAnimation(.easeInOut(duration: 0.2)) {
            opacity = 1.0
          }
        }
      }
      .onAppear {
        if isPulsing {
          withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
            opacity = 0.3
          }
        }
      }
  }
}

// MARK: - Recording Status View

struct RecordingStatusView: View {
  @ObservedObject var stateManager: RecordingStateManager

  var body: some View {
    ZStack {
      // Glass background with fallback
      glassBackground()

      // Content
      HStack(spacing: 12) {
        // Status indicator
        statusIndicator()

        // Status label
        statusLabel()

        Spacer()

        // Timer (only shown during waiting/recording)
        if stateManager.state == .waiting || stateManager.state == .recording {
          Text(stateManager.timerText)
            .font(.system(size: 18, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.white)
            .opacity(stateManager.state == .waiting ? 0.5 : 1.0)
            .contentTransition(.numericText())
            .animation(.easeInOut(duration: 0.2), value: stateManager.timerText)
        }

        // Stop button (only during waiting/recording)
        if stateManager.state == .waiting || stateManager.state == .recording {
          Button(action: {
            stateManager.handleStopClicked()
          }) {
            Text("Stop")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(.white)
              .padding(.horizontal, 14)
              .padding(.vertical, 6)
              .background(Color.red.opacity(0.8))
              .clipShape(RoundedRectangle(cornerRadius: 8))
          }
          .buttonStyle(.plain)
        }

        // Cancel button (during analyzing/error states)
        if stateManager.state == .analyzing || stateManager.state == .error {
          Button(action: {
            stateManager.handleCancelClicked()
          }) {
            Text("Cancel")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(.white)
              .padding(.horizontal, 14)
              .padding(.vertical, 6)
              .background(Color.orange.opacity(0.8))
              .clipShape(RoundedRectangle(cornerRadius: 8))
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .frame(height: 56)
    .fixedSize(horizontal: true, vertical: false)
    .clipShape(RoundedRectangle(cornerRadius: 16))
    .overlay(
      RoundedRectangle(cornerRadius: 16)
        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
    )
    .overlay(
      // Warning flash overlay
      RoundedRectangle(cornerRadius: 16)
        .fill(Color.orange.opacity(stateManager.showWarning ? 0.3 : 0))
        .animation(.easeInOut(duration: 0.3), value: stateManager.showWarning)
    )
    .animation(.spring(duration: 0.3), value: stateManager.state)
  }

  @ViewBuilder
  private func glassBackground() -> some View {
    if #available(macOS 26, *) {
      // Liquid Glass on macOS 26+
      RoundedRectangle(cornerRadius: 16)
        .fill(.ultraThinMaterial)
        .glassEffect(.regular)
    } else {
      // Fallback to NSVisualEffectView
      VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
    }
  }

  @ViewBuilder
  private func statusIndicator() -> some View {
    switch stateManager.state {
    case .waiting:
      Circle()
        .fill(Color.gray)
        .frame(width: 12, height: 12)

    case .recording:
      PulsingDot(color: .red, isPulsing: true)

    case .analyzing:
      ProgressView()
        .progressViewStyle(.circular)
        .scaleEffect(0.7)
        .tint(.blue)

    case .success:
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(.green)
        .transition(.scale.combined(with: .opacity))

    case .error:
      Image(systemName: "exclamationmark.circle.fill")
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(.red)
        .transition(.scale.combined(with: .opacity))

    case .cancelled:
      Image(systemName: "xmark.circle.fill")
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(.orange)
        .transition(.scale.combined(with: .opacity))
    }
  }

  @ViewBuilder
  private func statusLabel() -> some View {
    Text(statusText)
      .font(.system(size: 14, weight: .medium))
      .foregroundStyle(.white)
      .contentTransition(.interpolate)
  }

  private var statusText: String {
    switch stateManager.state {
    case .waiting:
      return "Waiting..."
    case .recording:
      return "Recording"
    case .analyzing:
      return "Analyzing..."
    case .success:
      return "Complete"
    case .error:
      return "Error"
    case .cancelled:
      return "Cancelled"
    }
  }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow?
  let stateManager = RecordingStateManager()

  nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
    Task { @MainActor in
      await self.setupApp()
    }
  }

  private func setupApp() {
    // Hide dock icon
    NSApp.setActivationPolicy(.accessory)

    // Create the SwiftUI view
    let contentView = RecordingStatusView(stateManager: stateManager)
    let hostingView = NSHostingView(rootView: contentView)
    hostingView.setFrameSize(hostingView.fittingSize)

    // Create window
    window = NSWindow(
      contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )

    window?.isOpaque = false
    window?.backgroundColor = .clear
    window?.level = .floating
    window?.hasShadow = true
    window?.isMovableByWindowBackground = true
    window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    window?.contentView = hostingView

    // Position at top-center
    positionWindowAtTopCenter()
    window?.makeKeyAndOrderFront(nil)

    // Setup callbacks
    stateManager.onStopClicked = { [weak self] in
      self?.sendResponse(.stopClicked)
    }

    stateManager.onTimeout = { [weak self] in
      self?.sendResponse(.timeout)
    }

    stateManager.onCancelClicked = { [weak self] in
      self?.sendResponse(.cancelClicked)
    }

    // Signal ready and start reading input
    sendResponse(.ready)
    startReadingInput()
  }

  private func positionWindowAtTopCenter() {
    guard let screen = NSScreen.main, let window = window else { return }
    let screenFrame = screen.visibleFrame
    let x = screenFrame.midX - window.frame.width / 2
    let y = screenFrame.maxY - window.frame.height - 20
    window.setFrameOrigin(NSPoint(x: x, y: y))
  }

  private func startReadingInput() {
    Task.detached {
      let stdin = FileHandle.standardInput
      var buffer = Data()

      while true {
        let data = stdin.availableData
        guard !data.isEmpty else {
          // stdin closed, exit
          await MainActor.run {
            NSApp.terminate(nil)
          }
          return
        }

        buffer.append(data)

        // Process complete lines (newline-delimited JSON)
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
          let lineData = Data(buffer.prefix(upTo: newlineIndex))
          buffer = Data(buffer.suffix(from: buffer.index(after: newlineIndex)))

          if let command = try? JSONDecoder().decode(StatusCommand.self, from: lineData) {
            await MainActor.run {
              (NSApp.delegate as? AppDelegate)?.handleCommand(command)
            }
          }
        }
      }
    }
  }

  private func handleCommand(_ command: StatusCommand) {
    switch command.type {
    case .configure:
      stateManager.configure(durationSeconds: command.durationSeconds)

    case .recording:
      stateManager.startRecording()

    case .analyzing:
      stateManager.setAnalyzing()

    case .success:
      stateManager.setSuccess()

    case .error:
      stateManager.setError()

    case .stop:
      stateManager.stop()

    case .cancelled:
      stateManager.setCancelled()
    }
  }

  private func sendResponse(_ type: StatusResponse.ResponseType) {
    let response = StatusResponse(type: type)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys

    if let data = try? encoder.encode(response),
       let json = String(data: data, encoding: .utf8) {
      print(json)
      fflush(stdout)
    }
  }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
