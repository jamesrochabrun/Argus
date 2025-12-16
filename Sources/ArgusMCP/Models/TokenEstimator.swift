import Foundation

// MARK: - Token Estimator

/// Estimates input tokens for video analysis BEFORE making API calls
/// Used for preflight checks to prevent wasted API calls that exceed limits
public struct TokenEstimator: Sendable {

    // MARK: - OpenAI Vision Token Constants

    /// Base tokens per image at "low" detail level (OpenAI documented: 85 tokens)
    /// However, empirical data shows ~2300 tokens per frame in practice
    /// Based on real API response: 180,324 tokens for ~78 frames = ~2,312 tokens/frame
    /// Using conservative estimate of 2500 to ensure we catch edge cases
    public static let tokensPerFrame: Int = 2500

    /// System prompt tokens for Pass A (global understanding)
    public static let systemPromptTokensPassA: Int = 800

    /// System prompt tokens for Pass B (motion extraction per segment)
    public static let systemPromptTokensPassB: Int = 600

    /// Text overhead per frame (timestamps, formatting)
    public static let textOverheadPerFrame: Int = 30

    /// Base overhead per vision call (message structure, JSON formatting)
    public static let baseOverheadPerCall: Int = 200

    // MARK: - Types

    /// Detailed token estimate with breakdown
    public struct Estimate: Sendable {
        /// Total estimated input tokens
        public let inputTokens: Int

        /// Breakdown by component
        public let breakdown: Breakdown

        /// Confidence level based on estimation accuracy
        public let confidence: Confidence

        /// Percentage of the mode's token limit
        public func percentageOfLimit(_ limit: Int) -> Double {
            guard limit > 0 else { return 100.0 }
            return Double(inputTokens) / Double(limit) * 100.0
        }

        /// Whether this estimate exceeds the given limit
        public func exceedsLimit(_ limit: Int) -> Bool {
            inputTokens > limit
        }

        /// Whether this estimate is close to the limit (>80%)
        public func nearLimit(_ limit: Int) -> Bool {
            percentageOfLimit(limit) > 80.0
        }
    }

    /// Token breakdown by component
    public struct Breakdown: Sendable {
        public let imageTokens: Int
        public let systemPromptTokens: Int
        public let textOverhead: Int
        public let visionCallOverhead: Int

        public var total: Int {
            imageTokens + systemPromptTokens + textOverhead + visionCallOverhead
        }
    }

    /// Confidence level for the estimate
    public enum Confidence: String, Sendable {
        case high = "high"       // Based on calibrated data
        case medium = "medium"   // Using default estimates
        case low = "low"         // Significant uncertainty
    }

    // MARK: - Estimation

    /// Estimate tokens for a video analysis based on sampling plan
    public static func estimate(
        frameCount: Int,
        segmentCount: Int,
        globalPassFrameCount: Int
    ) -> Estimate {
        // Vision calls: 1 global pass + 1 per segment
        let visionCalls = 1 + segmentCount

        // Image tokens (all frames processed across all calls)
        let imageTokens = frameCount * tokensPerFrame

        // System prompt tokens
        let systemPromptTokens = systemPromptTokensPassA + (segmentCount * systemPromptTokensPassB)

        // Text overhead (timestamps, etc.)
        let textOverhead = frameCount * textOverheadPerFrame

        // Per-call base overhead
        let callOverhead = visionCalls * baseOverheadPerCall

        let breakdown = Breakdown(
            imageTokens: imageTokens,
            systemPromptTokens: systemPromptTokens,
            textOverhead: textOverhead,
            visionCallOverhead: callOverhead
        )

        return Estimate(
            inputTokens: breakdown.total,
            breakdown: breakdown,
            confidence: .medium  // Using default estimates
        )
    }

    /// Estimate tokens from a FrameSampler.SamplingPlan
    public static func estimate(from plan: FrameSampler.SamplingPlan) -> Estimate {
        estimate(
            frameCount: plan.frameCount,
            segmentCount: plan.segments.count,
            globalPassFrameCount: plan.globalPassIndices.count
        )
    }

    /// Estimate maximum recommended duration for a given mode's token limit
    public static func maxDurationForMode(_ mode: FrameSampler.Mode, limit: Int) -> Double {
        // Work backwards from token limit to frame count
        // Total tokens ≈ frames * tokensPerFrame + overhead
        // Solve for frames, then convert to duration based on mode

        let overheadPerVisionCall = baseOverheadPerCall + systemPromptTokensPassB
        let tokensPerFrameWithOverhead = tokensPerFrame + textOverheadPerFrame

        // Rough estimate: assume average of 8 vision calls
        let estimatedOverhead = 8 * overheadPerVisionCall + systemPromptTokensPassA

        let availableForFrames = limit - estimatedOverhead
        let maxFrames = max(1, availableForFrames / tokensPerFrameWithOverhead)

        // Convert frames to duration based on mode
        switch mode {
        case .simple:
            // 1 FPS
            return Double(min(maxFrames, 120))

        case .quick:
            // ~0.5 frames per second (30 frames / 60s)
            return Double(maxFrames) * 2.0

        case .highDetail:
            // ~1.5 frames per second (180 frames / 120s)
            return Double(maxFrames) / 1.5

        case .custom(let fps, _):
            return Double(maxFrames) / fps
        }
    }
}

// MARK: - Convenience Extensions

extension TokenEstimator.Estimate: CustomStringConvertible {
    public var description: String {
        """
        Estimated Input Tokens: \(inputTokens)
        Confidence: \(confidence.rawValue)
        Breakdown:
          - Images: \(breakdown.imageTokens) tokens
          - System Prompts: \(breakdown.systemPromptTokens) tokens
          - Text Overhead: \(breakdown.textOverhead) tokens
          - Call Overhead: \(breakdown.visionCallOverhead) tokens
        """
    }
}
