import Foundation

// MARK: - Frame Sampler

/// Determines which frames to extract based on mode and video duration
/// Uses fixed sampling strategy (no motion detection)
public struct FrameSampler: Sendable {

    // MARK: - Types

    /// Sampling mode configuration
    public enum Mode: Sendable {
        /// Simple analysis: 1 FPS, descriptive output
        case simple

        /// Quick code generation: 12-30 frames total
        case quick

        /// High detail code generation: 80-180 frames total
        case highDetail

        /// Custom sampling
        case custom(framesPerSecond: Double, maxFrames: Int)
    }

    /// Sampling plan with calculated timestamps
    public struct SamplingPlan: Sendable {
        /// All timestamps to extract
        public let timestamps: [Double]

        /// Indices for global pass (Pass A) - sparse sampling
        public let globalPassIndices: [Int]

        /// Segments for motion pass (Pass B)
        public let segments: [Segment]

        /// Video duration
        public let duration: Double

        /// Sampling mode used
        public let mode: Mode
    }

    /// A video segment for Pass B analysis
    public struct Segment: Sendable {
        public let index: Int
        public let startTime: Double
        public let endTime: Double
        public let frameIndices: [Int]

        public var duration: Double {
            endTime - startTime
        }
    }

    // MARK: - Public API

    /// Create a sampling plan for the given video duration and mode
    public static func createPlan(
        duration: Double,
        mode: Mode
    ) -> SamplingPlan {
        switch mode {
        case .simple:
            return createSimplePlan(duration: duration)
        case .quick:
            return createQuickPlan(duration: duration)
        case .highDetail:
            return createHighDetailPlan(duration: duration)
        case .custom(let fps, let maxFrames):
            return createCustomPlan(duration: duration, fps: fps, maxFrames: maxFrames)
        }
    }

    // MARK: - Simple Mode (analyze_video)

    /// Simple mode: 1 FPS, up to 120 frames, single pass
    private static func createSimplePlan(duration: Double) -> SamplingPlan {
        let fps: Double = 1.0
        let maxFrames = 120

        let interval = 1.0 / fps
        var timestamps: [Double] = []
        var t = 0.0

        while t < duration && timestamps.count < maxFrames {
            timestamps.append(t)
            t += interval
        }

        // For simple mode, all frames are global pass (single pass analysis)
        let globalIndices = Array(0..<timestamps.count)

        return SamplingPlan(
            timestamps: timestamps,
            globalPassIndices: globalIndices,
            segments: [],  // No segments for simple mode
            duration: duration,
            mode: .simple
        )
    }

    // MARK: - Quick Mode (design_from_video quick)

    /// Quick mode: 12-30 frames per 60s video
    /// Samples at segment boundaries + midpoints
    private static func createQuickPlan(duration: Double) -> SamplingPlan {
        // targetFrames calculation (reserved for future adaptive sampling)
        _ = min(30, max(12, Int(duration * 0.5)))

        // Determine segment count (aim for 3-6 segments)
        let segmentCount = min(6, max(3, Int(duration / 10)))
        let segmentDuration = duration / Double(segmentCount)

        var timestamps: [Double] = []
        var segments: [Segment] = []

        for segIdx in 0..<segmentCount {
            let segStart = Double(segIdx) * segmentDuration
            let segEnd = min(segStart + segmentDuration, duration)

            // Sample: start, 33%, 66%, end of segment
            let segTimestamps = [
                segStart,
                segStart + segmentDuration * 0.33,
                segStart + segmentDuration * 0.66,
                segEnd - 0.01  // Just before end
            ].filter { $0 >= 0 && $0 < duration }

            let startIdx = timestamps.count
            timestamps.append(contentsOf: segTimestamps)
            let endIdx = timestamps.count

            segments.append(Segment(
                index: segIdx,
                startTime: segStart,
                endTime: segEnd,
                frameIndices: Array(startIdx..<endIdx)
            ))
        }

        // Global pass: sample sparse frames (start, 25%, 50%, 75%, end)
        let globalIndices = selectGlobalIndices(from: timestamps, count: min(6, timestamps.count))

        return SamplingPlan(
            timestamps: timestamps,
            globalPassIndices: globalIndices,
            segments: segments,
            duration: duration,
            mode: .quick
        )
    }

    // MARK: - High Detail Mode (design_from_video high_detail)

    /// High detail mode: 80-180 frames per 120s video
    /// Denser sampling for precise animation extraction
    private static func createHighDetailPlan(duration: Double) -> SamplingPlan {
        let targetFrames = min(180, max(80, Int(duration * 1.5)))

        // More segments for detailed analysis (6-12)
        let segmentCount = min(12, max(6, Int(duration / 10)))
        let segmentDuration = duration / Double(segmentCount)

        // Calculate frames per segment
        let framesPerSegment = max(10, targetFrames / segmentCount)
        let segmentFPS = Double(framesPerSegment) / segmentDuration

        var timestamps: [Double] = []
        var segments: [Segment] = []

        for segIdx in 0..<segmentCount {
            let segStart = Double(segIdx) * segmentDuration
            let segEnd = min(segStart + segmentDuration, duration)

            // Sample at calculated FPS within segment
            let interval = 1.0 / segmentFPS
            var t = segStart
            let startIdx = timestamps.count

            while t < segEnd && timestamps.count < targetFrames {
                timestamps.append(t)
                t += interval
            }

            let endIdx = timestamps.count

            segments.append(Segment(
                index: segIdx,
                startTime: segStart,
                endTime: segEnd,
                frameIndices: Array(startIdx..<endIdx)
            ))
        }

        // Global pass: 8 frames spread across video
        let globalIndices = selectGlobalIndices(from: timestamps, count: min(8, timestamps.count))

        return SamplingPlan(
            timestamps: timestamps,
            globalPassIndices: globalIndices,
            segments: segments,
            duration: duration,
            mode: .highDetail
        )
    }

    // MARK: - Custom Mode

    private static func createCustomPlan(
        duration: Double,
        fps: Double,
        maxFrames: Int
    ) -> SamplingPlan {
        let interval = 1.0 / fps
        var timestamps: [Double] = []
        var t = 0.0

        while t < duration && timestamps.count < maxFrames {
            timestamps.append(t)
            t += interval
        }

        // Create segments of ~10 seconds each
        let segmentDuration = 10.0
        let segmentCount = max(1, Int(ceil(duration / segmentDuration)))
        var segments: [Segment] = []

        for segIdx in 0..<segmentCount {
            let segStart = Double(segIdx) * segmentDuration
            let segEnd = min(segStart + segmentDuration, duration)

            let frameIndices = timestamps.enumerated()
                .filter { $0.element >= segStart && $0.element < segEnd }
                .map { $0.offset }

            segments.append(Segment(
                index: segIdx,
                startTime: segStart,
                endTime: segEnd,
                frameIndices: frameIndices
            ))
        }

        let globalIndices = selectGlobalIndices(from: timestamps, count: min(8, timestamps.count))

        return SamplingPlan(
            timestamps: timestamps,
            globalPassIndices: globalIndices,
            segments: segments,
            duration: duration,
            mode: .custom(framesPerSecond: fps, maxFrames: maxFrames)
        )
    }

    // MARK: - Helpers

    /// Select evenly distributed indices for global pass
    private static func selectGlobalIndices(from timestamps: [Double], count: Int) -> [Int] {
        guard !timestamps.isEmpty else { return [] }
        guard count > 0 else { return [] }

        if timestamps.count <= count {
            return Array(0..<timestamps.count)
        }

        var indices: [Int] = []
        let step = Double(timestamps.count - 1) / Double(count - 1)

        for i in 0..<count {
            let idx = Int(round(Double(i) * step))
            indices.append(min(idx, timestamps.count - 1))
        }

        return indices
    }
}

// MARK: - Extensions

extension FrameSampler.SamplingPlan {
    /// Get timestamps for global pass (Pass A)
    public var globalPassTimestamps: [Double] {
        globalPassIndices.map { timestamps[$0] }
    }

    /// Total frame count
    public var frameCount: Int {
        timestamps.count
    }

    /// Estimated cost based on frame count
    public var estimatedCost: String {
        switch mode {
        case .simple:
            return "~$0.001-0.003"
        case .quick:
            return "~$0.003"
        case .highDetail:
            return "~$0.01"
        case .custom:
            let frames = timestamps.count
            if frames <= 30 {
                return "~$0.003"
            } else if frames <= 100 {
                return "~$0.005"
            } else {
                return "~$0.01"
            }
        }
    }
}
