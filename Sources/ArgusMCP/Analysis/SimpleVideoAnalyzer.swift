import Foundation
@preconcurrency import SwiftOpenAI

// MARK: - Simple Video Analyzer

/// Single-pass video analyzer for the analyze_video tool
/// Produces natural language descriptions of video content
public actor SimpleVideoAnalyzer {

    // MARK: - Types

    /// Configuration for simple analysis
    public struct Config: Sendable {
        public let model: String
        public let maxTokensPerBatch: Int
        public let batchSize: Int
        public let temperature: Double
        public let imageDetail: String
        public let systemPrompt: String

        public init(
            model: String = "gpt-4o-mini",
            maxTokensPerBatch: Int = 1000,
            batchSize: Int = 8,
            temperature: Double = 0.2,
            imageDetail: String = "low",
            systemPrompt: String? = nil
        ) {
            self.model = model
            self.maxTokensPerBatch = maxTokensPerBatch
            self.batchSize = batchSize
            self.temperature = temperature
            self.imageDetail = imageDetail
            self.systemPrompt = systemPrompt ?? Self.defaultSystemPrompt
        }

        public static let `default` = Config()

        public static let defaultSystemPrompt = """
            You are a visual observer providing detailed descriptions of this video. Describe what you see:

            ## VISUAL ELEMENTS
            - UI components: buttons, text fields, labels, icons, images
            - Layout: arrangement, spacing, alignment of elements
            - Design: colors, typography, shadows, borders, corner radii
            - Content: any text, numbers, or media visible

            ## MOTION & ANIMATION (if movement detected)
            - Position changes between frames
            - Opacity/fade transitions
            - Scale, rotation, or transform effects
            - Timing and easing characteristics

            ## STATE & CONTEXT
            - Current screen state and apparent purpose
            - Interactive elements and their visual states
            - Progress indicators, loading states, or feedback
            - Visual hierarchy and focus areas

            Reference frames as: "Frame X shows..."
            Describe objectively and thoroughly, like a designer documenting their work.
            """
    }

    /// Result of a batch analysis
    public struct BatchResult: Sendable {
        public let batchIndex: Int
        public let analysis: String
        public let timestampRange: ClosedRange<Double>
        public let tokensUsed: Int
        public let promptTokens: Int
        public let completionTokens: Int
    }

    /// Complete analysis result
    public struct AnalysisResult: Sendable {
        public let summary: String
        public let batchResults: [BatchResult]
        public let frameCount: Int
        public let totalTokensUsed: Int
        public let totalPromptTokens: Int
        public let totalCompletionTokens: Int
        public let analysisTime: Double
    }

    // MARK: - Properties

    private let openAIService: any OpenAIService

    // MARK: - Initialization

    public init(apiKey: String) {
        self.openAIService = OpenAIServiceFactory.service(apiKey: apiKey)
    }

    // MARK: - Analysis

    /// Analyze extracted frames and produce a description
    public func analyze(
        frames: [FFmpegProcessor.ExtractedFrame],
        config: Config = .default
    ) async throws -> AnalysisResult {
        let startTime = Date()

        guard !frames.isEmpty else {
            throw AnalysisError.noFramesToAnalyze
        }

        // Split frames into batches
        let batches = frames.chunked(into: config.batchSize)
        var batchResults: [BatchResult] = []

        var totalPromptTokens = 0
        var totalCompletionTokens = 0

        for (batchIndex, batch) in batches.enumerated() {
            let result = try await analyzeBatch(
                batch: batch,
                batchIndex: batchIndex,
                totalBatches: batches.count,
                config: config
            )
            batchResults.append(result)

            totalPromptTokens += result.promptTokens
            totalCompletionTokens += result.completionTokens
        }

        // Generate summary from all batch results
        let summary = try await generateSummary(
            batchResults: batchResults,
            config: config,
            promptTokens: &totalPromptTokens,
            completionTokens: &totalCompletionTokens
        )

        let analysisTime = Date().timeIntervalSince(startTime)

        return AnalysisResult(
            summary: summary,
            batchResults: batchResults,
            frameCount: frames.count,
            totalTokensUsed: totalPromptTokens + totalCompletionTokens,
            totalPromptTokens: totalPromptTokens,
            totalCompletionTokens: totalCompletionTokens,
            analysisTime: analysisTime
        )
    }

    // MARK: - Private Methods

    private func analyzeBatch(
        batch: [FFmpegProcessor.ExtractedFrame],
        batchIndex: Int,
        totalBatches: Int,
        config: Config
    ) async throws -> BatchResult {
        guard !batch.isEmpty else {
            throw AnalysisError.emptyBatch
        }

        // Build content array with frames
        var contentArray: [ChatCompletionParameters.Message.ContentType.MessageContent] = []

        // Add batch context
        let startTime = batch.first?.timestamp ?? 0
        let endTime = batch.last?.timestamp ?? 0
        contentArray.append(.text("Batch \(batchIndex + 1)/\(totalBatches): Analyzing frames from \(String(format: "%.1f", startTime))s to \(String(format: "%.1f", endTime))s"))

        // Add frames as images
        for frame in batch {
            let imageURL = URL(string: "data:image/jpeg;base64,\(frame.base64Data)")!
            contentArray.append(.imageUrl(.init(url: imageURL, detail: config.imageDetail)))
            contentArray.append(.text("Frame at \(String(format: "%.1f", frame.timestamp))s"))
        }

        // Create messages
        let messages: [ChatCompletionParameters.Message] = [
            .init(role: .system, content: .text(config.systemPrompt)),
            .init(role: .user, content: .contentArray(contentArray))
        ]

        // Call OpenAI
        let parameters = ChatCompletionParameters(
            messages: messages,
            model: .custom(config.model),
            maxTokens: config.maxTokensPerBatch,
            temperature: config.temperature
        )

        let response = try await openAIService.startChat(parameters: parameters)

        guard let choice = response.choices?.first,
              let analysis = choice.message?.content else {
            throw AnalysisError.apiError("No response from API")
        }

        return BatchResult(
            batchIndex: batchIndex,
            analysis: analysis,
            timestampRange: startTime...endTime,
            tokensUsed: response.usage?.totalTokens ?? 0,
            promptTokens: response.usage?.promptTokens ?? 0,
            completionTokens: response.usage?.completionTokens ?? 0
        )
    }

    private func generateSummary(
        batchResults: [BatchResult],
        config: Config,
        promptTokens: inout Int,
        completionTokens: inout Int
    ) async throws -> String {
        // Combine all batch analyses
        let combinedAnalysis = batchResults
            .map { "[\(String(format: "%.1f", $0.timestampRange.lowerBound))s-\(String(format: "%.1f", $0.timestampRange.upperBound))s]\n\($0.analysis)" }
            .joined(separator: "\n\n")

        let summaryPrompt = """
            Based on the following frame-by-frame analysis of a video, provide a cohesive summary that:
            1. Describes the overall content and purpose of the video
            2. Identifies key UI elements, interactions, and transitions
            3. Notes any animations or visual effects observed
            4. Provides a clear narrative of what happens throughout the video

            Frame Analysis:
            \(combinedAnalysis)

            Provide a clear, well-organized summary.
            """

        let messages: [ChatCompletionParameters.Message] = [
            .init(role: .system, content: .text("You are a technical writer summarizing video analysis.")),
            .init(role: .user, content: .text(summaryPrompt))
        ]

        let parameters = ChatCompletionParameters(
            messages: messages,
            model: .custom(config.model),
            maxTokens: 2000,
            temperature: config.temperature
        )

        let response = try await openAIService.startChat(parameters: parameters)

        promptTokens += response.usage?.promptTokens ?? 0
        completionTokens += response.usage?.completionTokens ?? 0

        guard let choice = response.choices?.first,
              let summary = choice.message?.content else {
            throw AnalysisError.apiError("No summary response from API")
        }

        return summary
    }
}

// MARK: - Errors

public enum AnalysisError: Error, LocalizedError {
    case noFramesToAnalyze
    case emptyBatch
    case apiError(String)

    public var errorDescription: String? {
        switch self {
        case .noFramesToAnalyze:
            return "No frames to analyze"
        case .emptyBatch:
            return "Empty batch provided"
        case .apiError(let message):
            return "API error: \(message)"
        }
    }
}

// MARK: - Array Extension

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
