import AVFoundation
import CoreImage
import Foundation

/// High-performance video frame extractor using AVFoundation
/// Extracts frames from video files at specified intervals
public final class VideoFrameExtractor: Sendable {

  /// Configuration for frame extraction
  public struct ExtractionConfig: Sendable {
    /// Target frames per second to extract (e.g., 1 = one frame per second)
    public let framesPerSecond: Double
    /// Maximum number of frames to extract
    public let maxFrames: Int
    /// Target image size (width). Height is calculated to maintain aspect ratio
    public let targetWidth: Int
    /// JPEG compression quality (0.0 to 1.0)
    public let compressionQuality: Double

    public init(
      framesPerSecond: Double = 1.0,
      maxFrames: Int = 30,
      targetWidth: Int = 1024,
      compressionQuality: Double = 0.8
    ) {
      self.framesPerSecond = framesPerSecond
      self.maxFrames = maxFrames
      self.targetWidth = targetWidth
      self.compressionQuality = compressionQuality
    }

    public static let `default` = ExtractionConfig()

    /// High quality config for detailed analysis
    public static let highQuality = ExtractionConfig(
      framesPerSecond: 2.0,
      maxFrames: 60,
      targetWidth: 1920,
      compressionQuality: 0.9
    )

    /// Fast config for quick analysis
    public static let fast = ExtractionConfig(
      framesPerSecond: 0.5,
      maxFrames: 15,
      targetWidth: 512,
      compressionQuality: 0.7
    )

    /// Animation testing config - captures every frame for short clips
    /// Best for 1-3 second animations at 60fps
    public static let animation = ExtractionConfig(
      framesPerSecond: 60.0,
      maxFrames: 180,  // 3 seconds at 60fps
      targetWidth: 1024,
      compressionQuality: 0.7
    )

    /// Full frame capture - captures all frames up to limit
    /// Use for detailed animation analysis
    public static let fullCapture = ExtractionConfig(
      framesPerSecond: 120.0,  // Will capture at video's native rate up to this
      maxFrames: 300,  // 5 seconds at 60fps
      targetWidth: 1280,
      compressionQuality: 0.75
    )
  }

  /// Extracted frame with metadata
  public struct ExtractedFrame: Sendable {
    /// Base64 encoded JPEG image data
    public let base64Data: String
    /// Timestamp in the video (seconds)
    public let timestamp: Double
    /// Frame index
    public let index: Int
    /// Original frame size
    public let originalSize: CGSize
    /// Processed frame size
    public let processedSize: CGSize
  }

  /// Extraction result
  public struct ExtractionResult: Sendable {
    /// Extracted frames
    public let frames: [ExtractedFrame]
    /// Total video duration in seconds
    public let videoDuration: Double
    /// Video dimensions
    public let videoSize: CGSize
    /// Frames per second of source video
    public let videoFPS: Float
    /// Total frame count in source video
    public let totalFrameCount: Int
    /// Time taken to extract frames
    public let extractionTime: TimeInterval
  }

  public init() {}

  /// Extract frames from a video file
  /// - Parameters:
  ///   - url: URL to the video file
  ///   - config: Extraction configuration
  /// - Returns: Extraction result with frames and metadata
  public func extractFrames(
    from url: URL,
    config: ExtractionConfig = .default
  ) async throws -> ExtractionResult {
    let startTime = Date()

    let asset = AVURLAsset(url: url, options: [
      AVURLAssetPreferPreciseDurationAndTimingKey: true
    ])

    // Load asset properties
    let duration = try await asset.load(.duration)
    let tracks = try await asset.loadTracks(withMediaType: .video)

    guard let videoTrack = tracks.first else {
      throw ExtractionError.noVideoTrack
    }

    let naturalSize = try await videoTrack.load(.naturalSize)
    let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
    let durationSeconds = CMTimeGetSeconds(duration)
    let totalFrameCount = Int(durationSeconds * Double(nominalFrameRate))

    // Calculate frame timestamps to extract
    let frameInterval = 1.0 / config.framesPerSecond
    var timestamps: [Double] = []
    var currentTime = 0.0

    while currentTime < durationSeconds && timestamps.count < config.maxFrames {
      timestamps.append(currentTime)
      currentTime += frameInterval
    }

    // Create image generator
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)

    // Calculate target size maintaining aspect ratio
    let aspectRatio = naturalSize.height / naturalSize.width
    let targetHeight = Int(Double(config.targetWidth) * aspectRatio)
    generator.maximumSize = CGSize(width: config.targetWidth, height: targetHeight)

    // Create CIContext for JPEG encoding (use Metal if available)
    let ciContext: CIContext
    if let metalDevice = MTLCreateSystemDefaultDevice() {
      ciContext = CIContext(mtlDevice: metalDevice)
    } else {
      ciContext = CIContext()
    }

    // Extract frames sequentially to avoid concurrency issues with AVAssetImageGenerator
    var extractedFrames: [ExtractedFrame] = []

    for (index, timestamp) in timestamps.enumerated() {
      if let frame = try await extractSingleFrame(
        generator: generator,
        ciContext: ciContext,
        timestamp: timestamp,
        index: index,
        config: config,
        originalSize: naturalSize
      ) {
        extractedFrames.append(frame)
      }
    }

    let extractionTime = Date().timeIntervalSince(startTime)

    return ExtractionResult(
      frames: extractedFrames,
      videoDuration: durationSeconds,
      videoSize: naturalSize,
      videoFPS: nominalFrameRate,
      totalFrameCount: totalFrameCount,
      extractionTime: extractionTime
    )
  }

  private func extractSingleFrame(
    generator: AVAssetImageGenerator,
    ciContext: CIContext,
    timestamp: Double,
    index: Int,
    config: ExtractionConfig,
    originalSize: CGSize
  ) async throws -> ExtractedFrame? {
    let time = CMTime(seconds: timestamp, preferredTimescale: 600)

    do {
      let (cgImage, actualTime) = try await generator.image(at: time)

      // Convert to JPEG data using CIContext
      let ciImage = CIImage(cgImage: cgImage)

      guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let jpegData = ciContext.jpegRepresentation(
              of: ciImage,
              colorSpace: colorSpace,
              options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: config.compressionQuality]
            ) else {
        return nil
      }

      let base64String = jpegData.base64EncodedString()

      return ExtractedFrame(
        base64Data: base64String,
        timestamp: CMTimeGetSeconds(actualTime),
        index: index,
        originalSize: originalSize,
        processedSize: CGSize(width: cgImage.width, height: cgImage.height)
      )
    } catch {
      // Log error but don't fail entire extraction for single frame failures
      print("Failed to extract frame at \(timestamp)s: \(error)")
      return nil
    }
  }

  /// Extract frames from video data
  /// - Parameters:
  ///   - data: Video data
  ///   - config: Extraction configuration
  /// - Returns: Extraction result
  public func extractFrames(
    from data: Data,
    config: ExtractionConfig = .default
  ) async throws -> ExtractionResult {
    // Write to temporary file
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("mp4")

    defer {
      try? FileManager.default.removeItem(at: tempURL)
    }

    try data.write(to: tempURL)
    return try await extractFrames(from: tempURL, config: config)
  }

  public enum ExtractionError: Error, LocalizedError {
    case noVideoTrack
    case invalidVideoData
    case frameExtractionFailed(String)

    public var errorDescription: String? {
      switch self {
      case .noVideoTrack:
        return "No video track found in the asset"
      case .invalidVideoData:
        return "Invalid video data provided"
      case .frameExtractionFailed(let reason):
        return "Frame extraction failed: \(reason)"
      }
    }
  }
}
