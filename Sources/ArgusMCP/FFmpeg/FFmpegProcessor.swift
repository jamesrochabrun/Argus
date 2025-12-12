import Foundation

// MARK: - FFmpeg Processor

/// FFmpeg-based video processing for frame extraction
/// Uses shell commands to invoke ffmpeg/ffprobe
public actor FFmpegProcessor {

    // MARK: - Types

    /// Video metadata extracted from ffprobe
    public struct VideoMetadata: Sendable {
        public let duration: Double
        public let width: Int
        public let height: Int
        public let fps: Double
        public let codec: String
        public let bitrate: Int?
        public let isVariableFrameRate: Bool

        public var resolution: String {
            "\(width)x\(height)"
        }
    }

    /// Frame extraction configuration
    public struct ExtractionConfig: Sendable {
        public let targetWidth: Int
        public let jpegQuality: Int  // 1-31, lower is better
        public let maxFrames: Int

        public init(targetWidth: Int = 720, jpegQuality: Int = 5, maxFrames: Int = 30) {
            self.targetWidth = targetWidth
            self.jpegQuality = jpegQuality
            self.maxFrames = maxFrames
        }

        /// Quick mode: 480p, optimized for token efficiency
        public static let quick = ExtractionConfig(targetWidth: 480, jpegQuality: 10, maxFrames: 30)

        /// High detail mode: 480p, slightly better quality, more frames
        public static let highDetail = ExtractionConfig(targetWidth: 480, jpegQuality: 8, maxFrames: 180)

        /// Simple analysis mode: 480p, 1 FPS equivalent
        public static let simple = ExtractionConfig(targetWidth: 480, jpegQuality: 10, maxFrames: 120)
    }

    /// Extracted frame with metadata
    public struct ExtractedFrame: Sendable {
        public let path: URL
        public let timestamp: Double
        public let index: Int
        public let sizeBytes: Int
        public let base64Data: String
    }

    /// Result of frame extraction
    public struct ExtractionResult: Sendable {
        public let frames: [ExtractedFrame]
        public let metadata: VideoMetadata
        public let tempDirectory: URL
        public let extractionTime: Double
    }

    /// Quality validation result
    public struct QualityResult: Sendable {
        public let isValid: Bool
        public let reason: String?
        public let blurScore: Double?
    }

    // MARK: - Errors

    public enum FFmpegError: Error, LocalizedError {
        case ffmpegNotFound
        case ffprobeNotFound
        case invalidVideoFile(String)
        case metadataParsingFailed(String)
        case frameExtractionFailed(String)
        case videoTooLong(duration: Double, maxDuration: Double)
        case resolutionTooLow(width: Int, height: Int)
        case noFramesExtracted

        public var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "ffmpeg not found. Install with: brew install ffmpeg"
            case .ffprobeNotFound:
                return "ffprobe not found. Install with: brew install ffmpeg"
            case .invalidVideoFile(let reason):
                return "Invalid video file: \(reason)"
            case .metadataParsingFailed(let reason):
                return "Failed to parse video metadata: \(reason)"
            case .frameExtractionFailed(let reason):
                return "Frame extraction failed: \(reason)"
            case .videoTooLong(let duration, let maxDuration):
                return "Video too long: \(String(format: "%.1f", duration))s (max: \(String(format: "%.0f", maxDuration))s)"
            case .resolutionTooLow(let width, let height):
                return "Resolution too low: \(width)x\(height) (minimum: 320x240)"
            case .noFramesExtracted:
                return "No frames were extracted from the video"
            }
        }
    }

    // MARK: - Properties

    private let ffmpegPath: String
    private let ffprobePath: String

    // MARK: - Initialization

    public init() async throws {
        // Find ffmpeg and ffprobe
        self.ffmpegPath = try await Self.findExecutable("ffmpeg")
        self.ffprobePath = try await Self.findExecutable("ffprobe")
    }

    private static func findExecutable(_ name: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            if name == "ffmpeg" {
                throw FFmpegError.ffmpegNotFound
            } else {
                throw FFmpegError.ffprobeNotFound
            }
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            if name == "ffmpeg" {
                throw FFmpegError.ffmpegNotFound
            } else {
                throw FFmpegError.ffprobeNotFound
            }
        }

        return path
    }

    // MARK: - Metadata Extraction

    /// Get video metadata using ffprobe
    public func getMetadata(from videoURL: URL) async throws -> VideoMetadata {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            videoURL.path
        ]

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            throw FFmpegError.invalidVideoFile(errorString)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return try parseMetadata(from: data)
    }

    private func parseMetadata(from data: Data) throws -> VideoMetadata {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FFmpegError.metadataParsingFailed("Invalid JSON")
        }

        // Find video stream
        guard let streams = json["streams"] as? [[String: Any]],
              let videoStream = streams.first(where: { ($0["codec_type"] as? String) == "video" }) else {
            throw FFmpegError.metadataParsingFailed("No video stream found")
        }

        // Extract dimensions
        guard let width = videoStream["width"] as? Int,
              let height = videoStream["height"] as? Int else {
            throw FFmpegError.metadataParsingFailed("Missing dimensions")
        }

        // Extract duration from format or stream
        var duration: Double = 0
        if let format = json["format"] as? [String: Any],
           let durationStr = format["duration"] as? String,
           let dur = Double(durationStr) {
            duration = dur
        } else if let durationStr = videoStream["duration"] as? String,
                  let dur = Double(durationStr) {
            duration = dur
        }

        // Extract FPS from r_frame_rate or avg_frame_rate
        var fps: Double = 30.0
        var isVFR = false
        if let rFrameRate = videoStream["r_frame_rate"] as? String,
           let avgFrameRate = videoStream["avg_frame_rate"] as? String {
            let rFps = parseFraction(rFrameRate)
            let avgFps = parseFraction(avgFrameRate)
            fps = avgFps > 0 ? avgFps : (rFps > 0 ? rFps : 30.0)

            // Check for variable frame rate
            if rFps > 0 && avgFps > 0 && abs(rFps - avgFps) > 1.0 {
                isVFR = true
            }
        }

        // Extract codec
        let codec = videoStream["codec_name"] as? String ?? "unknown"

        // Extract bitrate
        var bitrate: Int?
        if let format = json["format"] as? [String: Any],
           let bitrateStr = format["bit_rate"] as? String {
            bitrate = Int(bitrateStr)
        }

        return VideoMetadata(
            duration: duration,
            width: width,
            height: height,
            fps: fps,
            codec: codec,
            bitrate: bitrate,
            isVariableFrameRate: isVFR
        )
    }

    private func parseFraction(_ fraction: String) -> Double {
        let parts = fraction.split(separator: "/")
        guard parts.count == 2,
              let num = Double(parts[0]),
              let den = Double(parts[1]),
              den > 0 else {
            return 0
        }
        return num / den
    }

    // MARK: - Validation

    /// Validate video for analysis
    public func validate(_ metadata: VideoMetadata, maxDuration: Double = 120) throws {
        // Check duration
        guard metadata.duration <= maxDuration else {
            throw FFmpegError.videoTooLong(duration: metadata.duration, maxDuration: maxDuration)
        }

        // Check resolution
        guard metadata.width >= 320 && metadata.height >= 240 else {
            throw FFmpegError.resolutionTooLow(width: metadata.width, height: metadata.height)
        }
    }

    // MARK: - Frame Extraction

    /// Extract frames at specified timestamps
    public func extractFrames(
        from videoURL: URL,
        at timestamps: [Double],
        config: ExtractionConfig
    ) async throws -> ExtractionResult {
        let startTime = Date()

        // Get metadata first
        let metadata = try await getMetadata(from: videoURL)

        // Create temp directory
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("argus-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Limit timestamps to maxFrames
        let limitedTimestamps = Array(timestamps.prefix(config.maxFrames))

        var frames: [ExtractedFrame] = []

        for (index, timestamp) in limitedTimestamps.enumerated() {
            let outputPath = tempDir.appendingPathComponent("frame_\(String(format: "%04d", index)).jpg")

            // Extract single frame at timestamp
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpegPath)
            process.arguments = [
                "-ss", String(format: "%.3f", timestamp),
                "-i", videoURL.path,
                "-vframes", "1",
                "-vf", "scale=\(config.targetWidth):-1",
                "-q:v", String(config.jpegQuality),
                "-y",  // Overwrite
                outputPath.path
            ]

            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            try process.run()
            process.waitUntilExit()

            // Read frame and convert to base64
            if FileManager.default.fileExists(atPath: outputPath.path),
               let data = try? Data(contentsOf: outputPath) {
                let base64 = data.base64EncodedString()
                let frame = ExtractedFrame(
                    path: outputPath,
                    timestamp: timestamp,
                    index: index,
                    sizeBytes: data.count,
                    base64Data: base64
                )
                frames.append(frame)
            }
        }

        guard !frames.isEmpty else {
            throw FFmpegError.noFramesExtracted
        }

        let extractionTime = Date().timeIntervalSince(startTime)

        return ExtractionResult(
            frames: frames,
            metadata: metadata,
            tempDirectory: tempDir,
            extractionTime: extractionTime
        )
    }

    /// Extract frames at fixed FPS
    public func extractFramesAtFPS(
        from videoURL: URL,
        fps: Double,
        config: ExtractionConfig
    ) async throws -> ExtractionResult {
        // Get metadata to calculate timestamps
        let metadata = try await getMetadata(from: videoURL)

        // Calculate timestamps based on FPS
        let interval = 1.0 / fps
        var timestamps: [Double] = []
        var t = 0.0
        while t < metadata.duration && timestamps.count < config.maxFrames {
            timestamps.append(t)
            t += interval
        }

        return try await extractFrames(from: videoURL, at: timestamps, config: config)
    }

    // MARK: - Cleanup

    /// Clean up extracted frames
    public func cleanup(_ result: ExtractionResult) {
        try? FileManager.default.removeItem(at: result.tempDirectory)
    }
}
