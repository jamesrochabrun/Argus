import Foundation

// MARK: - Animation DSL Types

/// Complete animation specification from video analysis
public struct AnimationSpec: Codable, Sendable {
    public let elements: [AnimatedElement]
    public let transitions: [ViewTransition]?
    public let timing: TimingConfig
    public let metadata: SpecMetadata?

    public init(
        elements: [AnimatedElement],
        transitions: [ViewTransition]? = nil,
        timing: TimingConfig,
        metadata: SpecMetadata? = nil
    ) {
        self.elements = elements
        self.transitions = transitions
        self.timing = timing
        self.metadata = metadata
    }
}

// MARK: - Animated Element

/// An animated UI element with keyframes
public struct AnimatedElement: Codable, Sendable {
    public let id: String
    public let type: ElementType
    public let content: String?
    public let style: ElementStyle?
    public let keyframes: [Keyframe]
    public let dependsOn: ElementDependency?

    public init(
        id: String,
        type: ElementType,
        content: String? = nil,
        style: ElementStyle? = nil,
        keyframes: [Keyframe],
        dependsOn: ElementDependency? = nil
    ) {
        self.id = id
        self.type = type
        self.content = content
        self.style = style
        self.keyframes = keyframes
        self.dependsOn = dependsOn
    }
}

/// Type of UI element
public enum ElementType: String, Codable, Sendable {
    case button
    case text
    case image
    case container
    case shape
    case icon
    case card
    case list
    case custom
}

/// Element styling properties
public struct ElementStyle: Codable, Sendable {
    public let width: Double?
    public let height: Double?
    public let backgroundColor: String?
    public let foregroundColor: String?
    public let cornerRadius: Double?
    public let fontSize: Double?
    public let fontWeight: String?
    public let padding: Double?
    public let borderWidth: Double?
    public let borderColor: String?

    public init(
        width: Double? = nil,
        height: Double? = nil,
        backgroundColor: String? = nil,
        foregroundColor: String? = nil,
        cornerRadius: Double? = nil,
        fontSize: Double? = nil,
        fontWeight: String? = nil,
        padding: Double? = nil,
        borderWidth: Double? = nil,
        borderColor: String? = nil
    ) {
        self.width = width
        self.height = height
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.cornerRadius = cornerRadius
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.padding = padding
        self.borderWidth = borderWidth
        self.borderColor = borderColor
    }
}

/// Dependency on another element's animation
public struct ElementDependency: Codable, Sendable {
    public let elementId: String
    public let condition: DependencyCondition
    public let progress: Double?
    public let delay: Double?

    public init(
        elementId: String,
        condition: DependencyCondition,
        progress: Double? = nil,
        delay: Double? = nil
    ) {
        self.elementId = elementId
        self.condition = condition
        self.progress = progress
        self.delay = delay
    }
}

public enum DependencyCondition: String, Codable, Sendable {
    case afterStart
    case afterEnd
    case atProgress
}

// MARK: - Keyframe

/// A single keyframe in an animation
public struct Keyframe: Codable, Sendable {
    /// Normalized time (0-1) within the animation
    public let t: Double

    /// Normalized X position (0-1)
    public let x: Double?

    /// Normalized Y position (0-1)
    public let y: Double?

    /// Scale factor (1.0 = 100%)
    public let scale: Double?

    /// Separate X scale
    public let scaleX: Double?

    /// Separate Y scale
    public let scaleY: Double?

    /// Opacity (0-1)
    public let opacity: Double?

    /// Rotation in degrees
    public let rotation: Double?

    /// 3D rotation
    public let rotation3D: Rotation3D?

    /// Blur radius
    public let blur: Double?

    /// Corner radius
    public let cornerRadius: Double?

    /// Background color (hex)
    public let backgroundColor: String?

    /// Foreground/text color (hex)
    public let foregroundColor: String?

    /// Shadow radius
    public let shadowRadius: Double?

    /// Shadow offset
    public let shadowOffset: Point?

    /// Animation curve to this keyframe
    public let curve: AnimationCurve?

    public init(
        t: Double,
        x: Double? = nil,
        y: Double? = nil,
        scale: Double? = nil,
        scaleX: Double? = nil,
        scaleY: Double? = nil,
        opacity: Double? = nil,
        rotation: Double? = nil,
        rotation3D: Rotation3D? = nil,
        blur: Double? = nil,
        cornerRadius: Double? = nil,
        backgroundColor: String? = nil,
        foregroundColor: String? = nil,
        shadowRadius: Double? = nil,
        shadowOffset: Point? = nil,
        curve: AnimationCurve? = nil
    ) {
        self.t = t
        self.x = x
        self.y = y
        self.scale = scale
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.opacity = opacity
        self.rotation = rotation
        self.rotation3D = rotation3D
        self.blur = blur
        self.cornerRadius = cornerRadius
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.shadowRadius = shadowRadius
        self.shadowOffset = shadowOffset
        self.curve = curve
    }
}

/// 3D rotation specification
public struct Rotation3D: Codable, Sendable {
    public let angle: Double
    public let axisX: Double
    public let axisY: Double
    public let axisZ: Double
    public let perspective: Double?

    public init(
        angle: Double,
        axisX: Double = 0,
        axisY: Double = 1,
        axisZ: Double = 0,
        perspective: Double? = nil
    ) {
        self.angle = angle
        self.axisX = axisX
        self.axisY = axisY
        self.axisZ = axisZ
        self.perspective = perspective
    }
}

/// 2D point
public struct Point: Codable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

// MARK: - Animation Curve

/// Animation timing curve
public enum AnimationCurve: Codable, Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case spring(response: Double, dampingFraction: Double)
    case interpolatingSpring(stiffness: Double, damping: Double, mass: Double)
    case bezier(cp1: Point, cp2: Point)

    private enum CodingKeys: String, CodingKey {
        case type
        case response
        case dampingFraction
        case stiffness
        case damping
        case mass
        case cp1
        case cp2
    }

    public init(from decoder: Decoder) throws {
        // Try string first (simple curves)
        if let container = try? decoder.singleValueContainer(),
           let typeString = try? container.decode(String.self) {
            switch typeString.lowercased() {
            case "linear": self = .linear
            case "easein": self = .easeIn
            case "easeout": self = .easeOut
            case "easeinout": self = .easeInOut
            case "spring": self = .spring(response: 0.5, dampingFraction: 0.825)
            default: self = .easeInOut
            }
            return
        }

        // Try object (complex curves)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type.lowercased() {
        case "linear":
            self = .linear
        case "easein":
            self = .easeIn
        case "easeout":
            self = .easeOut
        case "easeinout":
            self = .easeInOut
        case "spring":
            let response = try container.decodeIfPresent(Double.self, forKey: .response) ?? 0.5
            let dampingFraction = try container.decodeIfPresent(Double.self, forKey: .dampingFraction) ?? 0.825
            self = .spring(response: response, dampingFraction: dampingFraction)
        case "interpolatingspring":
            let stiffness = try container.decode(Double.self, forKey: .stiffness)
            let damping = try container.decode(Double.self, forKey: .damping)
            let mass = try container.decodeIfPresent(Double.self, forKey: .mass) ?? 1.0
            self = .interpolatingSpring(stiffness: stiffness, damping: damping, mass: mass)
        case "bezier":
            let cp1 = try container.decode(Point.self, forKey: .cp1)
            let cp2 = try container.decode(Point.self, forKey: .cp2)
            self = .bezier(cp1: cp1, cp2: cp2)
        default:
            self = .easeInOut
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .linear:
            try container.encode("linear", forKey: .type)
        case .easeIn:
            try container.encode("easeIn", forKey: .type)
        case .easeOut:
            try container.encode("easeOut", forKey: .type)
        case .easeInOut:
            try container.encode("easeInOut", forKey: .type)
        case .spring(let response, let dampingFraction):
            try container.encode("spring", forKey: .type)
            try container.encode(response, forKey: .response)
            try container.encode(dampingFraction, forKey: .dampingFraction)
        case .interpolatingSpring(let stiffness, let damping, let mass):
            try container.encode("interpolatingSpring", forKey: .type)
            try container.encode(stiffness, forKey: .stiffness)
            try container.encode(damping, forKey: .damping)
            try container.encode(mass, forKey: .mass)
        case .bezier(let cp1, let cp2):
            try container.encode("bezier", forKey: .type)
            try container.encode(cp1, forKey: .cp1)
            try container.encode(cp2, forKey: .cp2)
        }
    }

    /// Check if this curve is complex (requires LLM for code generation)
    public var isComplex: Bool {
        switch self {
        case .linear, .easeIn, .easeOut, .easeInOut:
            return false
        case .spring:
            return false  // Basic spring is supported
        case .interpolatingSpring, .bezier:
            return true
        }
    }
}

// MARK: - View Transition

/// View transition (push, modal, fade, etc.)
public struct ViewTransition: Codable, Sendable {
    public let type: TransitionType
    public let direction: TransitionDirection?
    public let duration: Double?
    public let curve: AnimationCurve?
    public let matchedGeometryId: String?

    public init(
        type: TransitionType,
        direction: TransitionDirection? = nil,
        duration: Double? = nil,
        curve: AnimationCurve? = nil,
        matchedGeometryId: String? = nil
    ) {
        self.type = type
        self.direction = direction
        self.duration = duration
        self.curve = curve
        self.matchedGeometryId = matchedGeometryId
    }
}

public enum TransitionType: String, Codable, Sendable {
    case push
    case pop
    case modal
    case fade
    case slide
    case scale
    case matched
}

public enum TransitionDirection: String, Codable, Sendable {
    case leading
    case trailing
    case top
    case bottom
}

// MARK: - Timing Config

/// Overall timing configuration
public struct TimingConfig: Codable, Sendable {
    public let totalDuration: Double
    public let stagger: Double?
    public let looping: Bool?
    public let autoReverse: Bool?

    public init(
        totalDuration: Double,
        stagger: Double? = nil,
        looping: Bool? = nil,
        autoReverse: Bool? = nil
    ) {
        self.totalDuration = totalDuration
        self.stagger = stagger
        self.looping = looping
        self.autoReverse = autoReverse
    }
}

// MARK: - Metadata

/// Metadata about the generated spec
public struct SpecMetadata: Codable, Sendable {
    public let name: String?
    public let description: String?
    public let sourceVideo: String?
    public let generatedAt: String?
    public let confidence: Double?

    public init(
        name: String? = nil,
        description: String? = nil,
        sourceVideo: String? = nil,
        generatedAt: String? = nil,
        confidence: Double? = nil
    ) {
        self.name = name
        self.description = description
        self.sourceVideo = sourceVideo
        self.generatedAt = generatedAt
        self.confidence = confidence
    }
}

// MARK: - Timeline Event

/// An event in the animation timeline
public struct TimelineEvent: Codable, Sendable {
    public let timestamp: Double
    public let type: EventType
    public let description: String
    public let involvedElements: [String]

    public init(
        timestamp: Double,
        type: EventType,
        description: String,
        involvedElements: [String]
    ) {
        self.timestamp = timestamp
        self.type = type
        self.description = description
        self.involvedElements = involvedElements
    }
}

public enum EventType: String, Codable, Sendable {
    case animationStart = "animation_start"
    case animationEnd = "animation_end"
    case userAction = "user_action"
    case transitionStart = "transition_start"
    case transitionEnd = "transition_end"
    case stateChange = "state_change"
    case overshoot
    case settle
}

