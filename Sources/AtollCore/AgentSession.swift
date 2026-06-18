import Foundation

public enum SessionState: String, Codable, CaseIterable, Sendable {
    case running
    case done
    case waitingForInput
    case waitingForPermission
    case unknown

    public var displayName: String {
        switch self {
        case .running:
            "Running"
        case .done:
            "Done"
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
        case .done:
            4
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
    public var updatedAt: Date
    public var startedAt: Date?
    public var sourcePath: String
    public var processID: Int32?
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
        startedAt: Date? = nil,
        sourcePath: String,
        processID: Int32? = nil,
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
        self.startedAt = startedAt
        self.sourcePath = sourcePath
        self.processID = processID
        self.confidence = confidence
    }
}
