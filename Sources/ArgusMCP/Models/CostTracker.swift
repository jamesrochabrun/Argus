import Foundation

// MARK: - Cost Tracker

/// Tracks and enforces cost limits for video analysis
public actor CostTracker {

    // MARK: - Types

    /// Cost limits for different modes
    public struct Limits: Sendable {
        public let maxFrames: Int
        public let maxVisionCalls: Int
        public let maxInputTokens: Int
        public let maxOutputTokens: Int

        public init(
            maxFrames: Int,
            maxVisionCalls: Int,
            maxInputTokens: Int,
            maxOutputTokens: Int
        ) {
            self.maxFrames = maxFrames
            self.maxVisionCalls = maxVisionCalls
            self.maxInputTokens = maxInputTokens
            self.maxOutputTokens = maxOutputTokens
        }

        /// Quick mode limits (~$0.003)
        public static let quick = Limits(
            maxFrames: 30,
            maxVisionCalls: 8,
            maxInputTokens: 50_000,
            maxOutputTokens: 8_000
        )

        /// High detail mode limits (~$0.01)
        public static let highDetail = Limits(
            maxFrames: 180,
            maxVisionCalls: 24,
            maxInputTokens: 150_000,
            maxOutputTokens: 16_000
        )

        /// Simple analysis mode
        public static let simple = Limits(
            maxFrames: 120,
            maxVisionCalls: 20,
            maxInputTokens: 100_000,
            maxOutputTokens: 8_000
        )
    }

    /// Cost breakdown for reporting
    public struct CostBreakdown: Codable, Sendable {
        public let framesExtracted: Int
        public let visionCallsMade: Int
        public let inputTokens: Int
        public let outputTokens: Int
        public let estimatedCostUSD: Double

        public var formattedCost: String {
            String(format: "$%.4f", estimatedCostUSD)
        }
    }

    /// Error when limits are exceeded
    public enum CostLimitError: Error, LocalizedError {
        case frameLimitExceeded(current: Int, max: Int)
        case visionCallLimitExceeded(current: Int, max: Int)
        case inputTokenLimitExceeded(current: Int, max: Int)
        case outputTokenLimitExceeded(current: Int, max: Int)

        public var errorDescription: String? {
            switch self {
            case .frameLimitExceeded(let current, let max):
                return "Frame limit exceeded: \(current) > \(max)"
            case .visionCallLimitExceeded(let current, let max):
                return "Vision call limit exceeded: \(current) > \(max)"
            case .inputTokenLimitExceeded(let current, let max):
                return "Input token limit exceeded: \(current) > \(max)"
            case .outputTokenLimitExceeded(let current, let max):
                return "Output token limit exceeded: \(current) > \(max)"
            }
        }
    }

    // MARK: - Properties

    private let limits: Limits
    private var framesUsed: Int = 0
    private var visionCallsMade: Int = 0
    private var inputTokensUsed: Int = 0
    private var outputTokensUsed: Int = 0

    // MARK: - Pricing Constants (GPT-4o-mini as of 2024)

    private let inputTokenPricePerMillion: Double = 0.15  // $0.15 per 1M input tokens
    private let outputTokenPricePerMillion: Double = 0.60  // $0.60 per 1M output tokens

    // MARK: - Initialization

    public init(limits: Limits) {
        self.limits = limits
    }

    // MARK: - Tracking

    /// Record frames extracted
    public func recordFrames(_ count: Int) throws {
        let newTotal = framesUsed + count
        guard newTotal <= limits.maxFrames else {
            throw CostLimitError.frameLimitExceeded(current: newTotal, max: limits.maxFrames)
        }
        framesUsed = newTotal
    }

    /// Check if we can make another vision call
    public func canMakeVisionCall() -> Bool {
        visionCallsMade < limits.maxVisionCalls
    }

    /// Record a vision API call
    public func recordVisionCall(inputTokens: Int, outputTokens: Int) throws {
        let newCallCount = visionCallsMade + 1
        let newInputTokens = inputTokensUsed + inputTokens
        let newOutputTokens = outputTokensUsed + outputTokens

        guard newCallCount <= limits.maxVisionCalls else {
            throw CostLimitError.visionCallLimitExceeded(current: newCallCount, max: limits.maxVisionCalls)
        }

        guard newInputTokens <= limits.maxInputTokens else {
            throw CostLimitError.inputTokenLimitExceeded(current: newInputTokens, max: limits.maxInputTokens)
        }

        guard newOutputTokens <= limits.maxOutputTokens else {
            throw CostLimitError.outputTokenLimitExceeded(current: newOutputTokens, max: limits.maxOutputTokens)
        }

        visionCallsMade = newCallCount
        inputTokensUsed = newInputTokens
        outputTokensUsed = newOutputTokens
    }

    /// Get current usage stats
    public func currentUsage() -> (frames: Int, calls: Int, inputTokens: Int, outputTokens: Int) {
        (framesUsed, visionCallsMade, inputTokensUsed, outputTokensUsed)
    }

    /// Get remaining capacity
    public func remainingCapacity() -> (frames: Int, calls: Int, inputTokens: Int, outputTokens: Int) {
        (
            limits.maxFrames - framesUsed,
            limits.maxVisionCalls - visionCallsMade,
            limits.maxInputTokens - inputTokensUsed,
            limits.maxOutputTokens - outputTokensUsed
        )
    }

    /// Calculate final cost breakdown
    public func finalize() -> CostBreakdown {
        let inputCost = Double(inputTokensUsed) / 1_000_000.0 * inputTokenPricePerMillion
        let outputCost = Double(outputTokensUsed) / 1_000_000.0 * outputTokenPricePerMillion

        return CostBreakdown(
            framesExtracted: framesUsed,
            visionCallsMade: visionCallsMade,
            inputTokens: inputTokensUsed,
            outputTokens: outputTokensUsed,
            estimatedCostUSD: inputCost + outputCost
        )
    }

    /// Reset tracker for reuse
    public func reset() {
        framesUsed = 0
        visionCallsMade = 0
        inputTokensUsed = 0
        outputTokensUsed = 0
    }
}

// MARK: - Convenience Extensions

extension CostTracker.Limits {
    /// Create limits for a specific mode string
    public static func forMode(_ mode: String) -> CostTracker.Limits {
        switch mode.lowercased() {
        case "quick":
            return .quick
        case "high_detail", "highdetail", "high":
            return .highDetail
        case "simple":
            return .simple
        default:
            return .simple
        }
    }
}
