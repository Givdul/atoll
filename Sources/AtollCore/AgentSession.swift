import Foundation

public enum SessionState: String, Codable, CaseIterable, Sendable {
    case running
    case done
    case failed
    case cancelled
    case waitingForInput
    case waitingForPermission
    case unknown

    public var displayName: String {
        switch self {
        case .running:
            "Running"
        case .done:
            "Done"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        case .waitingForInput:
            "Needs Input"
        case .waitingForPermission:
            "Needs Approval"
        case .unknown:
            "Unknown"
        }
    }

    public var sortRank: Int {
        switch self {
        case .waitingForPermission:
            0
        case .waitingForInput:
            1
        case .running:
            2
        case .unknown:
            3
        case .done, .failed, .cancelled:
            4
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .done, .failed, .cancelled:
            true
        case .running, .waitingForInput, .waitingForPermission, .unknown:
            false
        }
    }
}

public enum SessionConfidence: String, Codable, Sendable {
    case live
    case inferred
    case historical
}

public struct AgentSession: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var harness: AgentHarness
    public var title: String
    public var detail: String
    public var prompt: String?
    public var lastToolCall: String?
    public var projectPath: String?
    public var model: String?
    public var state: SessionState
    /// Provider transition time clamped no later than Atoll's receipt time for
    /// stable presentation and sorting. The registry retains the raw source time.
    public var updatedAt: Date
    /// Local time when Atoll observed the current lifecycle state.
    public var observedAt: Date?
    public var startedAt: Date?
    public var sourcePath: String
    public var processID: Int32?
    public var originProcessID: Int32?
    public var originBundleIdentifier: String?
    public var confidence: SessionConfidence

    public init(
        id: String,
        harness: AgentHarness,
        title: String,
        detail: String,
        prompt: String? = nil,
        lastToolCall: String? = nil,
        projectPath: String? = nil,
        model: String? = nil,
        state: SessionState,
        updatedAt: Date,
        observedAt: Date? = nil,
        startedAt: Date? = nil,
        sourcePath: String,
        processID: Int32? = nil,
        originProcessID: Int32? = nil,
        originBundleIdentifier: String? = nil,
        confidence: SessionConfidence
    ) {
        self.id = id
        self.harness = harness
        self.title = title
        self.detail = detail
        self.prompt = prompt
        self.lastToolCall = lastToolCall
        self.projectPath = projectPath
        self.model = model
        self.state = state
        self.updatedAt = updatedAt
        self.observedAt = observedAt
        self.startedAt = startedAt
        self.sourcePath = sourcePath
        self.processID = processID
        self.originProcessID = originProcessID
        self.originBundleIdentifier = originBundleIdentifier
        self.confidence = confidence
    }
}
