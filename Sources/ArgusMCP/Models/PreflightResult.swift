import Foundation

// MARK: - Preflight Result

/// Result of a preflight check before video analysis
public enum PreflightResult: Sendable {
    /// Safe to proceed - estimate is well within limits
    case safe

    /// Needs user confirmation - estimate exceeds or approaches limits
    case needsConfirmation(PreflightInfo)
}

// MARK: - Preflight Info

/// Detailed information when preflight check needs user confirmation
public struct PreflightInfo: Sendable {

    /// Video duration in seconds
    public let duration: Double

    /// Number of frames that will be extracted
    public let frameCount: Int

    /// Number of vision API calls that will be made
    public let visionCalls: Int

    /// Estimated input tokens
    public let estimatedTokens: Int

    /// Token limit for the requested mode
    public let limit: Int

    /// The mode that was requested
    public let requestedMode: String

    /// Percentage of limit (can exceed 100%)
    public var percentageOfLimit: Double {
        guard limit > 0 else { return 100.0 }
        return Double(estimatedTokens) / Double(limit) * 100.0
    }

    /// Whether estimate exceeds the limit
    public var exceedsLimit: Bool {
        estimatedTokens > limit
    }

    /// Recommended actions for the user
    public let recommendations: [Recommendation]

    /// Estimated cost in USD if processing proceeds
    public let estimatedCostUSD: Double

    // MARK: - Initialization

    public init(
        duration: Double,
        frameCount: Int,
        visionCalls: Int,
        estimatedTokens: Int,
        limit: Int,
        requestedMode: String,
        recommendations: [Recommendation],
        estimatedCostUSD: Double
    ) {
        self.duration = duration
        self.frameCount = frameCount
        self.visionCalls = visionCalls
        self.estimatedTokens = estimatedTokens
        self.limit = limit
        self.requestedMode = requestedMode
        self.recommendations = recommendations
        self.estimatedCostUSD = estimatedCostUSD
    }
}

// MARK: - Recommendation

/// A recommended action for the user when preflight check fails
public struct Recommendation: Sendable {
    /// Type of recommendation
    public let type: RecommendationType

    /// Human-readable description
    public let description: String

    /// Estimated tokens if this recommendation is followed
    public let estimatedTokensAfter: Int?

    /// Whether this option would be within limits
    public var wouldBeWithinLimit: Bool {
        guard let tokens = estimatedTokensAfter else { return false }
        return tokens <= (type.suggestedLimit ?? Int.max)
    }
}

/// Types of recommendations
public enum RecommendationType: Sendable {
    /// Switch to quick mode
    case useQuickMode

    /// Reduce video duration
    case reduceDuration(maxSeconds: Int)

    /// Reduce video resolution before processing
    case reduceResolution

    /// Split into multiple shorter videos
    case splitVideo

    /// Force proceed (user accepts risk)
    case forceProceed

    /// Suggested token limit for this recommendation type
    var suggestedLimit: Int? {
        switch self {
        case .useQuickMode:
            return CostTracker.Limits.quick.maxInputTokens
        case .reduceDuration, .reduceResolution, .splitVideo:
            return nil  // Depends on context
        case .forceProceed:
            return nil  // User accepts any outcome
        }
    }
}

// MARK: - Preflight Check

/// Performs preflight checks for video analysis
public struct PreflightCheck: Sendable {

    /// Threshold percentage - warn if estimate exceeds this % of limit
    public static let warningThreshold: Double = 80.0

    /// Perform preflight check for design_from_video
    public static func check(
        duration: Double,
        mode: FrameSampler.Mode,
        limits: CostTracker.Limits
    ) -> PreflightResult {
        // Create sampling plan to get frame counts
        let plan = FrameSampler.createPlan(duration: duration, mode: mode)

        // Estimate tokens
        let estimate = TokenEstimator.estimate(from: plan)

        // Check against limits
        let percentage = estimate.percentageOfLimit(limits.maxInputTokens)

        // If well within limits, safe to proceed
        if percentage < warningThreshold {
            return .safe
        }

        // Build recommendations
        var recommendations: [Recommendation] = []

        // Recommendation 1: Try quick mode if not already using it
        if case .highDetail = mode {
            let quickPlan = FrameSampler.createPlan(duration: duration, mode: .quick)
            let quickEstimate = TokenEstimator.estimate(from: quickPlan)

            recommendations.append(Recommendation(
                type: .useQuickMode,
                description: "Use quick mode instead (~\(quickEstimate.inputTokens) tokens)",
                estimatedTokensAfter: quickEstimate.inputTokens
            ))
        }

        // Recommendation 2: Reduce duration
        let maxDuration = TokenEstimator.maxDurationForMode(mode, limit: limits.maxInputTokens)
        if maxDuration < duration {
            recommendations.append(Recommendation(
                type: .reduceDuration(maxSeconds: Int(maxDuration)),
                description: "Trim video to \(Int(maxDuration)) seconds or less",
                estimatedTokensAfter: nil
            ))
        }

        // Recommendation 3: Force proceed (always available)
        recommendations.append(Recommendation(
            type: .forceProceed,
            description: "Proceed anyway with force_proceed: true (may fail mid-analysis)",
            estimatedTokensAfter: nil
        ))

        // Calculate estimated cost
        let inputCost = Double(estimate.inputTokens) / 1_000_000.0 * 0.15
        let estimatedOutputTokens = limits.maxOutputTokens / 2  // Rough estimate
        let outputCost = Double(estimatedOutputTokens) / 1_000_000.0 * 0.60
        let estimatedCost = inputCost + outputCost

        let modeString: String
        switch mode {
        case .simple: modeString = "simple"
        case .quick: modeString = "quick"
        case .highDetail: modeString = "high_detail"
        case .custom: modeString = "custom"
        }

        return .needsConfirmation(PreflightInfo(
            duration: duration,
            frameCount: plan.frameCount,
            visionCalls: plan.segments.count + 1,
            estimatedTokens: estimate.inputTokens,
            limit: limits.maxInputTokens,
            requestedMode: modeString,
            recommendations: recommendations,
            estimatedCostUSD: estimatedCost
        ))
    }

    /// Perform preflight check for analyze_video (simple mode)
    public static func checkSimple(duration: Double) -> PreflightResult {
        check(duration: duration, mode: .simple, limits: .simple)
    }
}

// MARK: - Formatted Output

extension PreflightInfo {
    /// Format as user-friendly message for MCP response
    public func formattedMessage() -> String {
        var message = """
        PREFLIGHT CHECK - Action Required

        This video will likely exceed \(requestedMode) mode limits.

        Estimates:
        - Video duration: \(String(format: "%.1f", duration))s
        - Frames to extract: \(frameCount)
        - Vision API calls: \(visionCalls)
        - Estimated input tokens: ~\(estimatedTokens)
        - Mode limit: \(limit) tokens
        - Usage: \(String(format: "%.0f", percentageOfLimit))% of limit
        - Estimated cost: $\(String(format: "%.4f", estimatedCostUSD))

        Recommendations:
        """

        for (index, rec) in recommendations.enumerated() {
            message += "\n\(index + 1). \(rec.description)"
        }

        return message
    }
}
