import Foundation
@preconcurrency import SwiftOpenAI

/// High-performance video analyzer that processes frames in batches
/// and sends them to OpenAI's vision API for analysis
public final class VideoAnalyzer: @unchecked Sendable {

  /// Configuration for video analysis
  public struct AnalysisConfig: Sendable {
    /// Number of frames to send in each batch to the LLM
    public let batchSize: Int
    /// Model to use for vision analysis
    public let model: String
    /// Maximum tokens for each batch response
    public let maxTokensPerBatch: Int
    /// System prompt for analysis
    public let systemPrompt: String
    /// Detail level for images (low, high, auto)
    public let imageDetail: String
    /// Temperature for responses
    public let temperature: Double

    public init(
      batchSize: Int = 5,
      model: String = "gpt-4o-mini",
      maxTokensPerBatch: Int = 1000,
      systemPrompt: String = Self.defaultSystemPrompt,
      imageDetail: String = "auto",
      temperature: Double = 0.3
    ) {
      self.batchSize = batchSize
      self.model = model
      self.maxTokensPerBatch = maxTokensPerBatch
      self.systemPrompt = systemPrompt
      self.imageDetail = imageDetail
      self.temperature = temperature
    }

    public static let defaultSystemPrompt = """
      You are an expert video analyst. You will receive frames from a video in sequence.
      Analyze each frame carefully and provide:
      1. A description of what's happening in each frame
      2. Any important visual elements, text, or UI components
      3. Changes between consecutive frames
      4. Overall narrative or flow of the content

      Be concise but thorough. Focus on actionable insights.
      """

    public static let `default` = AnalysisConfig()

    /// Detailed analysis config
    public static let detailed = AnalysisConfig(
      batchSize: 3,
      maxTokensPerBatch: 2000,
      imageDetail: "high"
    )

    /// Fast analysis config
    public static let fast = AnalysisConfig(
      batchSize: 8,
      maxTokensPerBatch: 500,
      imageDetail: "low"
    )
  }

  /// Result of analyzing a batch of frames
  public struct BatchAnalysisResult: Sendable {
    public let batchIndex: Int
    public let frameRange: ClosedRange<Int>
    public let timestampRange: ClosedRange<Double>
    public let analysis: String
    public let tokensUsed: Int
  }

  /// Complete video analysis result
  public struct VideoAnalysisResult: Sendable {
    public let batchResults: [BatchAnalysisResult]
    public let summary: String
    public let totalTokensUsed: Int
    public let analysisTime: TimeInterval
    public let frameCount: Int
    public let videoDuration: Double
  }

  private let openAIService: any OpenAIService

  public init(apiKey: String) {
    self.openAIService = OpenAIServiceFactory.service(apiKey: apiKey)
  }

  public init(service: any OpenAIService) {
    self.openAIService = service
  }

  /// Analyze extracted video frames
  /// - Parameters:
  ///   - extractionResult: Result from VideoFrameExtractor
  ///   - config: Analysis configuration
  ///   - progressHandler: Optional handler for progress updates
  /// - Returns: Complete analysis result
  public func analyze(
    extractionResult: VideoFrameExtractor.ExtractionResult,
    config: AnalysisConfig = .default,
    progressHandler: (@Sendable (Double, String) -> Void)? = nil
  ) async throws -> VideoAnalysisResult {
    let startTime = Date()

    let frames = extractionResult.frames
    guard !frames.isEmpty else {
      throw AnalysisError.noFramesToAnalyze
    }

    // Split frames into batches
    let batches = stride(from: 0, to: frames.count, by: config.batchSize).map { startIndex in
      let endIndex = min(startIndex + config.batchSize, frames.count)
      return Array(frames[startIndex..<endIndex])
    }

    progressHandler?(0.0, "Starting analysis of \(frames.count) frames in \(batches.count) batches")

    // Process batches sequentially to avoid rate limits and maintain order
    var batchResults: [BatchAnalysisResult] = []
    var totalTokensUsed = 0

    for (batchIndex, batch) in batches.enumerated() {
      let result = try await analyzeBatch(
        batch: batch,
        batchIndex: batchIndex,
        totalBatches: batches.count,
        config: config
      )
      batchResults.append(result)
      totalTokensUsed += result.tokensUsed

      let progress = Double(batchIndex + 1) / Double(batches.count)
      progressHandler?(progress * 0.9, "Processed \(batchIndex + 1)/\(batches.count) batches")
    }

    // Generate summary from all batch analyses
    progressHandler?(0.95, "Generating summary...")
    let (summary, summaryTokens) = try await generateSummary(
      batchResults: batchResults,
      config: config,
      videoDuration: extractionResult.videoDuration
    )
    totalTokensUsed += summaryTokens

    let analysisTime = Date().timeIntervalSince(startTime)
    progressHandler?(1.0, "Analysis complete")

    return VideoAnalysisResult(
      batchResults: batchResults,
      summary: summary,
      totalTokensUsed: totalTokensUsed,
      analysisTime: analysisTime,
      frameCount: frames.count,
      videoDuration: extractionResult.videoDuration
    )
  }

  private func analyzeBatch(
    batch: [VideoFrameExtractor.ExtractedFrame],
    batchIndex: Int,
    totalBatches: Int,
    config: AnalysisConfig
  ) async throws -> BatchAnalysisResult {
    guard let firstFrame = batch.first, let lastFrame = batch.last else {
      throw AnalysisError.emptyBatch
    }

    // Build content array with images and context
    var contentArray: [ChatCompletionParameters.Message.ContentType.MessageContent] = [
      .text("Batch \(batchIndex + 1)/\(totalBatches): Analyzing frames \(firstFrame.index + 1) to \(lastFrame.index + 1) (timestamps \(String(format: "%.1f", firstFrame.timestamp))s to \(String(format: "%.1f", lastFrame.timestamp))s)")
    ]

    // Add each frame as an image
    for frame in batch {
      let imageURL = URL(string: "data:image/jpeg;base64,\(frame.base64Data)")!
      contentArray.append(.imageUrl(.init(url: imageURL, detail: config.imageDetail)))
      contentArray.append(.text("Frame \(frame.index + 1) at \(String(format: "%.1f", frame.timestamp))s"))
    }

    let messages: [ChatCompletionParameters.Message] = [
      .init(role: .system, content: .text(config.systemPrompt)),
      .init(role: .user, content: .contentArray(contentArray))
    ]

    let parameters = ChatCompletionParameters(
      messages: messages,
      model: .custom(config.model),
      maxTokens: config.maxTokensPerBatch,
      temperature: config.temperature
    )

    let response = try await openAIService.startChat(parameters: parameters)

    let analysis = response.choices?.first?.message?.content ?? "No analysis generated"
    let tokensUsed = response.usage?.totalTokens ?? 0

    return BatchAnalysisResult(
      batchIndex: batchIndex,
      frameRange: firstFrame.index...lastFrame.index,
      timestampRange: firstFrame.timestamp...lastFrame.timestamp,
      analysis: analysis,
      tokensUsed: tokensUsed
    )
  }

  private func generateSummary(
    batchResults: [BatchAnalysisResult],
    config: AnalysisConfig,
    videoDuration: Double
  ) async throws -> (String, Int) {
    let batchSummaries = batchResults.map { result in
      "[\(String(format: "%.1f", result.timestampRange.lowerBound))s - \(String(format: "%.1f", result.timestampRange.upperBound))s]: \(result.analysis)"
    }.joined(separator: "\n\n")

    let summaryPrompt = """
      Based on the following frame-by-frame analysis of a \(String(format: "%.1f", videoDuration)) second video,
      provide a comprehensive summary that:
      1. Describes the overall content and purpose of the video
      2. Highlights key moments and transitions
      3. Notes any important text, UI elements, or visual information
      4. Provides actionable insights or conclusions

      Frame analyses:
      \(batchSummaries)
      """

    let messages: [ChatCompletionParameters.Message] = [
      .init(role: .system, content: .text("You are an expert at synthesizing video analysis into clear, actionable summaries.")),
      .init(role: .user, content: .text(summaryPrompt))
    ]

    let parameters = ChatCompletionParameters(
      messages: messages,
      model: .custom(config.model),
      maxTokens: 2000,
      temperature: 0.3
    )

    let response = try await openAIService.startChat(parameters: parameters)
    let summary = response.choices?.first?.message?.content ?? "No summary generated"
    let tokensUsed = response.usage?.totalTokens ?? 0

    return (summary, tokensUsed)
  }

  public enum AnalysisError: Error, LocalizedError {
    case noFramesToAnalyze
    case emptyBatch
    case apiError(String)

    public var errorDescription: String? {
      switch self {
      case .noFramesToAnalyze:
        return "No frames available to analyze"
      case .emptyBatch:
        return "Empty batch encountered during analysis"
      case .apiError(let message):
        return "OpenAI API error: \(message)"
      }
    }
  }
}
