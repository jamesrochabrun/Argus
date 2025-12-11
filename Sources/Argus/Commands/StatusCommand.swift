import AppKit
import ArgumentParser
import Foundation
import SwiftUI

// MARK: - Status Command

/// Status UI command - launched synchronously, blocks until user stops or timer ends
struct StatusCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Launch recording status UI (blocks until stopped)"
  )

  @Option(name: .long, help: "Recording duration in seconds (omit for manual stop mode)")
  var duration: Int?

  func run() throws {
    // IMPORTANT: We must run AppKit on the main thread.
    // ArgumentParser may call run() on a background thread when using async main,
    // so we use DispatchQueue.main.sync to hop to the main thread.
    // NSApp.run() then blocks until NSApp.terminate() is called.
    DispatchQueue.main.sync {
      let app = NSApplication.shared
      app.setActivationPolicy(.regular)

      let delegate = StatusAppDelegate(durationSeconds: duration)
      app.delegate = delegate
      app.run()  // This blocks until NSApp.terminate() is called
    }
  }
}

// MARK: - Status UI Result (Output)

/// Result output when status UI exits
struct StatusUIResult: Codable {
  enum ResultType: String, Codable {
    case stopped    // User clicked stop button
    case timeout    // Max duration reached
    case cancelled  // User cancelled
  }

  let result: ResultType
  let elapsed: Int
}

// MARK: - Recording State

enum RecordingState: Equatable {
  case recording
  case analyzing  // New state: recording done, analysis in progress
  case success
  case error
  case cancelled
}

// MARK: - State Manager

@MainActor
class RecordingStateManager: ObservableObject {
  @Published var state: RecordingState = .recording
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

  func startRecording(durationSeconds: Int?) {
    targetDuration = durationSeconds
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
    stopTimer()
    state = .success
  }

  func setError() {
    stopTimer()
    state = .error
  }

  func setCancelled() {
    stopTimer()
    state = .cancelled
  }

  private func startTimer() {
    timer?.invalidate()
    // Use target/selector pattern which works reliably with MainActor
    timer = Timer.scheduledTimer(
      timeInterval: 1.0,
      target: self,
      selector: #selector(timerFired),
      userInfo: nil,
      repeats: true
    )
    // Ensure timer fires during UI interactions
    if let timer = timer {
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  @objc private func timerFired() {
    timerTick()
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
  }

  private func timerTick() {
    elapsedSeconds += 1

    // Check for countdown completion (timed mode)
    if let target = targetDuration, elapsedSeconds >= target {
      onTimeout?()
      stopTimer()
      return
    }

    // Check for warning threshold (manual mode only)
    if targetDuration == nil && elapsedSeconds == warningThreshold {
      showWarning = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
        self?.showWarning = false
      }
    }

    // Check for max duration (manual mode)
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

// MARK: - Visual Effect Blur

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
      // Glass background
      VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)

      // Content
      HStack(spacing: 12) {
        // Status indicator
        statusIndicator()

        // Status label
        Text(statusText)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.white)
          .contentTransition(.interpolate)

        Spacer()

        // Timer (during recording)
        if stateManager.state == .recording {
          Text(stateManager.timerText)
            .font(.system(size: 18, weight: .semibold, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.white)
            .contentTransition(.numericText())
            .animation(.easeInOut(duration: 0.2), value: stateManager.timerText)
        }

        // Stop button (during recording)
        if stateManager.state == .recording {
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
  private func statusIndicator() -> some View {
    switch stateManager.state {
    case .recording:
      PulsingDot(color: .red, isPulsing: true)

    case .analyzing:
      // Pulsing blue dot for analysis
      PulsingDot(color: .blue, isPulsing: true)

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

  private var statusText: String {
    switch stateManager.state {
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

// MARK: - Status App Delegate

@MainActor
class StatusAppDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow?
  let stateManager = RecordingStateManager()
  let durationSeconds: Int?
  private var stdinSource: DispatchSourceRead?

  init(durationSeconds: Int?) {
    self.durationSeconds = durationSeconds
    super.init()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    setupApp()
  }

  private func setupApp() {
    // Hide dock icon but allow UI
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

    // Activate the app to bring window to front
    NSApp.activate(ignoringOtherApps: true)

    // Setup callbacks
    stateManager.onStopClicked = { [weak self] in
      self?.transitionToAnalyzing(result: .stopped)
    }

    stateManager.onTimeout = { [weak self] in
      self?.transitionToAnalyzing(result: .timeout)
    }

    stateManager.onCancelClicked = { [weak self] in
      self?.exitImmediately(result: .cancelled)
    }

    // Start listening for stdin commands (for analysis completion signals)
    setupStdinListener()

    // Start recording immediately
    stateManager.startRecording(durationSeconds: durationSeconds)
  }

  private func setupStdinListener() {
    // Listen for commands from parent process on stdin
    // Commands: "success\n" or "error\n"
    let stdinFD = FileHandle.standardInput.fileDescriptor
    stdinSource = DispatchSource.makeReadSource(fileDescriptor: stdinFD, queue: .main)

    stdinSource?.setEventHandler { [weak self] in
      guard let self = self else { return }

      let data = FileHandle.standardInput.availableData
      guard !data.isEmpty, let command = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        return
      }

      // Handle commands from parent process
      switch command {
      case "success":
        self.showSuccessAndExit()
      case "error":
        self.showErrorAndExit()
      default:
        break
      }
    }

    stdinSource?.resume()
  }

  private func positionWindowAtTopCenter() {
    guard let screen = NSScreen.main, let window = window else { return }
    let screenFrame = screen.visibleFrame
    let x = screenFrame.midX - window.frame.width / 2
    let y = screenFrame.maxY - window.frame.height - 20
    window.setFrameOrigin(NSPoint(x: x, y: y))
  }

  /// Transition to analyzing state - output result but keep UI running
  private func transitionToAnalyzing(result: StatusUIResult.ResultType) {
    // Output the recording result to stdout so parent process knows recording stopped
    let statusResult = StatusUIResult(result: result, elapsed: stateManager.elapsedSeconds)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys

    if let data = try? encoder.encode(statusResult),
      let json = String(data: data, encoding: .utf8)
    {
      print(json)
      fflush(stdout)
    }

    // Transition to analyzing state - UI stays visible
    stateManager.setAnalyzing()
  }

  /// Show success state briefly, then exit
  private func showSuccessAndExit() {
    stateManager.setSuccess()

    // Brief delay to show success state
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      Darwin.exit(0)
    }
  }

  /// Show error state briefly, then exit
  private func showErrorAndExit() {
    stateManager.setError()

    // Brief delay to show error state
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      Darwin.exit(1)
    }
  }

  /// Exit immediately without showing intermediate states (for cancel)
  private func exitImmediately(result: StatusUIResult.ResultType) {
    let statusResult = StatusUIResult(result: result, elapsed: stateManager.elapsedSeconds)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys

    if let data = try? encoder.encode(statusResult),
      let json = String(data: data, encoding: .utf8)
    {
      print(json)
      fflush(stdout)
    }

    Darwin.exit(0)
  }
}
