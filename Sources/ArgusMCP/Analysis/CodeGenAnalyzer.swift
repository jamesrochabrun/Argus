import Foundation
@preconcurrency import SwiftOpenAI

// MARK: - Design Extraction Analyzer

/// Two-pass video analyzer for the design_from_video tool
/// Pass A: Global understanding (sparse frames)
/// Pass B: Motion/spec extraction (per segment)
public actor CodeGenAnalyzer {

    // MARK: - Types

    /// Analysis mode
    public enum Mode: String, Sendable {
        case quick
        case highDetail = "high_detail"

        public var samplerMode: FrameSampler.Mode {
            switch self {
            case .quick: return .quick
            case .highDetail: return .highDetail
            }
        }

        public var costLimits: CostTracker.Limits {
            switch self {
            case .quick: return .quick
            case .highDetail: return .highDetail
            }
        }
    }

    /// Configuration for design extraction analysis
    public struct Config: Sendable {
        public let mode: Mode
        public let model: String
        public let focusHint: String?

        public init(
            mode: Mode = .quick,
            model: String = "gpt-4o-mini",
            focusHint: String? = nil
        ) {
            self.mode = mode
            self.model = model
            self.focusHint = focusHint
        }
    }

    /// Result of Pass A (global understanding)
    public struct GlobalAnalysis: Codable, Sendable {
        public let uiElements: [UIElement]
        public let userActions: [UserAction]
        public let transitions: [DetectedTransition]
        public let colorPalette: [String]
        public let layoutPattern: String

        private enum CodingKeys: String, CodingKey {
            case uiElements = "ui_elements"
            case userActions = "user_actions"
            case transitions
            case colorPalette = "color_palette"
            case layoutPattern = "layout_pattern"
        }
    }

    public struct UIElement: Codable, Sendable {
        public let id: String
        public let type: String
        public let position: String
        public let description: String?
    }

    public struct UserAction: Codable, Sendable {
        public let type: String
        public let targetElement: String?
        public let timestamp: Double?

        private enum CodingKeys: String, CodingKey {
            case type
            case targetElement = "target_element"
            case timestamp
        }
    }

    public struct DetectedTransition: Codable, Sendable {
        public let type: String
        public let direction: String?
        public let durationEstimate: Double?

        private enum CodingKeys: String, CodingKey {
            case type
            case direction
            case durationEstimate = "duration_estimate"
        }
    }

    /// Result of Pass B (motion extraction per segment)
    public struct SegmentAnalysis: Codable, Sendable {
        public let segmentIndex: Int
        public let timeRange: TimeRange
        public let elementMotions: [ElementMotion]

        private enum CodingKeys: String, CodingKey {
            case segmentIndex = "segment_index"
            case timeRange = "time_range"
            case elementMotions = "element_motions"
        }
    }

    public struct TimeRange: Codable, Sendable {
        public let start: Double
        public let end: Double
    }

    public struct ElementMotion: Codable, Sendable {
        public let elementId: String
        public let keyframes: [ExtractedKeyframe]

        private enum CodingKeys: String, CodingKey {
            case elementId = "element_id"
            case keyframes
        }
    }

    public struct ExtractedKeyframe: Codable, Sendable {
        public let t: Double
        public let x: Double?
        public let y: Double?
        public let scale: Double?
        public let opacity: Double?
        public let rotation: Double?
        public let curve: String?
    }

    /// Complete two-pass analysis result
    public struct AnalysisResult: Sendable {
        public let globalAnalysis: GlobalAnalysis
        public let segmentAnalyses: [SegmentAnalysis]
        public let featureSummary: String
        public let timeline: [TimelineEvent]
        public let animationSpec: AnimationSpec
        public let analysisTime: Double
    }

    // MARK: - Properties

    private let openAIService: any OpenAIService

    // MARK: - Initialization

    public init(apiKey: String) {
        self.openAIService = OpenAIServiceFactory.service(apiKey: apiKey)
    }

    // MARK: - Analysis

    /// Perform two-pass analysis on extracted frames
    public func analyze(
        frames: [FFmpegProcessor.ExtractedFrame],
        plan: FrameSampler.SamplingPlan,
        config: Config,
        costTracker: CostTracker
    ) async throws -> AnalysisResult {
        let startTime = Date()

        // Pass A: Global understanding
        let globalFrames = plan.globalPassIndices.compactMap { idx -> FFmpegProcessor.ExtractedFrame? in
            guard idx < frames.count else { return nil }
            return frames[idx]
        }

        let globalAnalysis = try await performPassA(
            frames: globalFrames,
            config: config,
            costTracker: costTracker
        )

        // Pass B: Per-segment motion extraction
        var segmentAnalyses: [SegmentAnalysis] = []

        for segment in plan.segments {
            guard await costTracker.canMakeVisionCall() else { break }

            let segmentFrames = segment.frameIndices.compactMap { idx -> FFmpegProcessor.ExtractedFrame? in
                guard idx < frames.count else { return nil }
                return frames[idx]
            }

            if !segmentFrames.isEmpty {
                let segmentAnalysis = try await performPassB(
                    frames: segmentFrames,
                    segment: segment,
                    globalContext: globalAnalysis,
                    config: config,
                    costTracker: costTracker
                )
                segmentAnalyses.append(segmentAnalysis)
            }
        }

        // Synthesize results into AnimationSpec
        let animationSpec = synthesizeSpec(
            globalAnalysis: globalAnalysis,
            segmentAnalyses: segmentAnalyses,
            duration: plan.duration
        )

        // Generate feature summary
        let featureSummary = generateFeatureSummary(
            globalAnalysis: globalAnalysis,
            segmentAnalyses: segmentAnalyses
        )

        // Build timeline
        let timeline = buildTimeline(
            globalAnalysis: globalAnalysis,
            segmentAnalyses: segmentAnalyses,
            duration: plan.duration
        )

        let analysisTime = Date().timeIntervalSince(startTime)

        return AnalysisResult(
            globalAnalysis: globalAnalysis,
            segmentAnalyses: segmentAnalyses,
            featureSummary: featureSummary,
            timeline: timeline,
            animationSpec: animationSpec,
            analysisTime: analysisTime
        )
    }

    // MARK: - Pass A: Global Understanding

    private func performPassA(
        frames: [FFmpegProcessor.ExtractedFrame],
        config: Config,
        costTracker: CostTracker
    ) async throws -> GlobalAnalysis {
        let systemPrompt = """
            Analyze these UI frames to identify the overall structure and interactions.

            ## TASK
            Identify:
            1. UI ELEMENTS: List each distinct element (buttons, labels, images, containers) with approximate position
            2. USER ACTIONS: What interactions occur? (tap, swipe, scroll, long-press)
            3. TRANSITIONS: What animation types? (push, pop, fade, scale, slide)
            4. COLORS: Primary colors used (hex values)
            5. LAYOUT: Overall structure (vertical stack, grid, list, etc.)

            ## OUTPUT FORMAT
            Return ONLY valid JSON matching this schema:
            {
                "ui_elements": [{"id": "string", "type": "string", "position": "string", "description": "string"}],
                "user_actions": [{"type": "string", "target_element": "string", "timestamp": number}],
                "transitions": [{"type": "string", "direction": "string", "duration_estimate": number}],
                "color_palette": ["#hex"],
                "layout_pattern": "string"
            }

            Be precise and consistent with element IDs across the response.
            \(config.focusHint.map { "Focus especially on: \($0)" } ?? "")
            """

        var contentArray: [ChatCompletionParameters.Message.ContentType.MessageContent] = []
        contentArray.append(.text("Analyze these \(frames.count) frames for global understanding:"))

        for frame in frames {
            let imageURL = URL(string: "data:image/jpeg;base64,\(frame.base64Data)")!
            contentArray.append(.imageUrl(.init(url: imageURL, detail: "low")))
            contentArray.append(.text("Frame at \(String(format: "%.2f", frame.timestamp))s"))
        }

        let messages: [ChatCompletionParameters.Message] = [
            .init(role: .system, content: .text(systemPrompt)),
            .init(role: .user, content: .contentArray(contentArray))
        ]

        let parameters = ChatCompletionParameters(
            messages: messages,
            model: .custom(config.model),
            maxTokens: 2000,
            temperature: 0.1
        )

        let response = try await openAIService.startChat(parameters: parameters)

        try await costTracker.recordVisionCall(
            inputTokens: response.usage?.promptTokens ?? 0,
            outputTokens: response.usage?.completionTokens ?? 0
        )

        guard let choice = response.choices?.first,
              let responseText = choice.message?.content else {
            throw CodeGenAnalysisError.noResponse
        }

        // Parse JSON response
        return try parseGlobalAnalysis(from: responseText)
    }

    // MARK: - Pass B: Motion Extraction

    private func performPassB(
        frames: [FFmpegProcessor.ExtractedFrame],
        segment: FrameSampler.Segment,
        globalContext: GlobalAnalysis,
        config: Config,
        costTracker: CostTracker
    ) async throws -> SegmentAnalysis {
        let elementsList = globalContext.uiElements.map { "\($0.id) (\($0.type))" }.joined(separator: ", ")

        let systemPrompt = """
            Extract detailed motion data for animated elements in this segment.

            ## KNOWN ELEMENTS
            \(elementsList)

            ## TASK
            For each element that moves/changes in these frames, provide keyframes with:
            - t: normalized time (0-1) within this segment
            - x, y: normalized position (0-1, where 0.5 is center)
            - scale: scale factor (1.0 = 100%)
            - opacity: 0-1
            - rotation: degrees
            - curve: animation curve ("linear", "easeIn", "easeOut", "easeInOut", "spring")

            ## OUTPUT FORMAT
            Return ONLY valid JSON:
            {
                "segment_index": \(segment.index),
                "time_range": {"start": \(segment.startTime), "end": \(segment.endTime)},
                "element_motions": [
                    {
                        "element_id": "string",
                        "keyframes": [
                            {"t": 0.0, "x": 0.5, "y": 0.5, "scale": 1.0, "opacity": 1.0, "rotation": 0, "curve": "easeOut"}
                        ]
                    }
                ]
            }

            Only include elements that actually animate. Use null for unchanged properties.
            """

        var contentArray: [ChatCompletionParameters.Message.ContentType.MessageContent] = []
        contentArray.append(.text("Segment \(segment.index + 1): \(String(format: "%.2f", segment.startTime))s - \(String(format: "%.2f", segment.endTime))s"))

        for frame in frames {
            let imageURL = URL(string: "data:image/jpeg;base64,\(frame.base64Data)")!
            contentArray.append(.imageUrl(.init(url: imageURL, detail: "low")))
            contentArray.append(.text("t=\(String(format: "%.2f", frame.timestamp))s"))
        }

        let messages: [ChatCompletionParameters.Message] = [
            .init(role: .system, content: .text(systemPrompt)),
            .init(role: .user, content: .contentArray(contentArray))
        ]

        let parameters = ChatCompletionParameters(
            messages: messages,
            model: .custom(config.model),
            maxTokens: 2000,
            temperature: 0.1
        )

        let response = try await openAIService.startChat(parameters: parameters)

        try await costTracker.recordVisionCall(
            inputTokens: response.usage?.promptTokens ?? 0,
            outputTokens: response.usage?.completionTokens ?? 0
        )

        guard let choice = response.choices?.first,
              let responseText = choice.message?.content else {
            throw CodeGenAnalysisError.noResponse
        }

        return try parseSegmentAnalysis(from: responseText)
    }

    // MARK: - Synthesis

    private func synthesizeSpec(
        globalAnalysis: GlobalAnalysis,
        segmentAnalyses: [SegmentAnalysis],
        duration: Double
    ) -> AnimationSpec {
        // Collect all element motions across segments
        var elementKeyframes: [String: [Keyframe]] = [:]

        for segment in segmentAnalyses {
            for motion in segment.elementMotions {
                var keyframes = elementKeyframes[motion.elementId] ?? []

                for kf in motion.keyframes {
                    // Convert segment-relative time to absolute time
                    let absoluteT = (segment.timeRange.start + kf.t * (segment.timeRange.end - segment.timeRange.start)) / duration

                    let keyframe = Keyframe(
                        t: absoluteT,
                        x: kf.x,
                        y: kf.y,
                        scale: kf.scale,
                        opacity: kf.opacity,
                        rotation: kf.rotation,
                        curve: kf.curve.flatMap { parseAnimationCurve($0) }
                    )
                    keyframes.append(keyframe)
                }

                elementKeyframes[motion.elementId] = keyframes
            }
        }

        // Build animated elements
        var animatedElements: [AnimatedElement] = []

        for uiElement in globalAnalysis.uiElements {
            if let keyframes = elementKeyframes[uiElement.id], !keyframes.isEmpty {
                // Sort keyframes by time
                let sortedKeyframes = keyframes.sorted { $0.t < $1.t }

                let element = AnimatedElement(
                    id: uiElement.id,
                    type: ElementType(rawValue: uiElement.type.lowercased()) ?? .custom,
                    content: uiElement.description,
                    keyframes: sortedKeyframes
                )
                animatedElements.append(element)
            }
        }

        // Build transitions
        let transitions = globalAnalysis.transitions.map { detected -> ViewTransition in
            ViewTransition(
                type: TransitionType(rawValue: detected.type.lowercased()) ?? .fade,
                direction: detected.direction.flatMap { TransitionDirection(rawValue: $0.lowercased()) },
                duration: detected.durationEstimate
            )
        }

        return AnimationSpec(
            elements: animatedElements,
            transitions: transitions.isEmpty ? nil : transitions,
            timing: TimingConfig(totalDuration: duration),
            metadata: SpecMetadata(
                generatedAt: ISO8601DateFormatter().string(from: Date())
            )
        )
    }

    private func parseAnimationCurve(_ string: String) -> AnimationCurve {
        switch string.lowercased() {
        case "linear": return .linear
        case "easein": return .easeIn
        case "easeout": return .easeOut
        case "easeinout": return .easeInOut
        case "spring": return .spring(response: 0.5, dampingFraction: 0.825)
        default: return .easeInOut
        }
    }

    private func generateFeatureSummary(
        globalAnalysis: GlobalAnalysis,
        segmentAnalyses: [SegmentAnalysis]
    ) -> String {
        var parts: [String] = []

        // Describe main elements
        let elementTypes = Set(globalAnalysis.uiElements.map { $0.type })
        if !elementTypes.isEmpty {
            parts.append("UI contains: \(elementTypes.joined(separator: ", "))")
        }

        // Describe transitions
        if !globalAnalysis.transitions.isEmpty {
            let transitionTypes = globalAnalysis.transitions.map { $0.type }
            parts.append("Transitions: \(transitionTypes.joined(separator: ", "))")
        }

        // Describe animations
        let animatedCount = segmentAnalyses.reduce(0) { $0 + $1.elementMotions.count }
        if animatedCount > 0 {
            parts.append("\(animatedCount) animated element(s) detected")
        }

        return parts.isEmpty ? "Video analyzed" : parts.joined(separator: ". ")
    }

    private func buildTimeline(
        globalAnalysis: GlobalAnalysis,
        segmentAnalyses: [SegmentAnalysis],
        duration: Double
    ) -> [TimelineEvent] {
        var events: [TimelineEvent] = []

        // Add user actions as events
        for action in globalAnalysis.userActions {
            events.append(TimelineEvent(
                timestamp: action.timestamp ?? 0,
                type: .userAction,
                description: action.type,
                involvedElements: action.targetElement.map { [$0] } ?? []
            ))
        }

        // Add animation start/end events from segments
        for segment in segmentAnalyses {
            if !segment.elementMotions.isEmpty {
                let elementIds = segment.elementMotions.map { $0.elementId }

                events.append(TimelineEvent(
                    timestamp: segment.timeRange.start,
                    type: .animationStart,
                    description: "Animation begins",
                    involvedElements: elementIds
                ))

                events.append(TimelineEvent(
                    timestamp: segment.timeRange.end,
                    type: .animationEnd,
                    description: "Animation completes",
                    involvedElements: elementIds
                ))
            }
        }

        return events.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - JSON Parsing

    private func parseGlobalAnalysis(from text: String) throws -> GlobalAnalysis {
        // Extract JSON from response (may be wrapped in markdown code blocks)
        let jsonString = extractJSON(from: text)

        guard let data = jsonString.data(using: .utf8) else {
            throw CodeGenAnalysisError.invalidJSON("Cannot convert to data")
        }

        do {
            return try JSONDecoder().decode(GlobalAnalysis.self, from: data)
        } catch {
            throw CodeGenAnalysisError.invalidJSON("Failed to decode: \(error.localizedDescription)")
        }
    }

    private func parseSegmentAnalysis(from text: String) throws -> SegmentAnalysis {
        let jsonString = extractJSON(from: text)

        guard let data = jsonString.data(using: .utf8) else {
            throw CodeGenAnalysisError.invalidJSON("Cannot convert to data")
        }

        do {
            return try JSONDecoder().decode(SegmentAnalysis.self, from: data)
        } catch {
            throw CodeGenAnalysisError.invalidJSON("Failed to decode segment: \(error.localizedDescription)")
        }
    }

    private func extractJSON(from text: String) -> String {
        // Try to find JSON in code blocks
        if let jsonMatch = text.range(of: "```json\n", options: .caseInsensitive),
           let endMatch = text.range(of: "\n```", options: .caseInsensitive, range: jsonMatch.upperBound..<text.endIndex) {
            return String(text[jsonMatch.upperBound..<endMatch.lowerBound])
        }

        // Try to find raw JSON (starts with {)
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }

        return text
    }
}

// MARK: - Errors

public enum CodeGenAnalysisError: Error, LocalizedError {
    case noResponse
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .noResponse:
            return "No response from API"
        case .invalidJSON(let reason):
            return "Invalid JSON response: \(reason)"
        }
    }
}
