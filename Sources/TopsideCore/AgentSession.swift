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

public struct AgentSession: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var harness: AgentHarness
    public var label: String
    public var state: SessionState
    /// Presentation-only task text. The durable registry never stores it.
    public var taskLabel: String? = nil

    /// The single label shown for this session in the island row.
    public var presentationLabel: String {
        taskLabel ?? label
    }

    /// Provider transition time clamped no later than Topside's receipt time for
    /// stable presentation and sorting. The registry retains the raw source time.
    public var updatedAt: Date
    /// Local time when Topside observed the current lifecycle state.
    public var observedAt: Date?
    public var startedAt: Date?
    public var originProcessID: Int32?
    public var originBundleIdentifier: String?

    public init(
        id: String,
        harness: AgentHarness,
        label: String,
        state: SessionState,
        updatedAt: Date,
        taskLabel: String? = nil,
        observedAt: Date? = nil,
        startedAt: Date? = nil,
        originProcessID: Int32? = nil,
        originBundleIdentifier: String? = nil
    ) {
        self.id = id
        self.harness = harness
        self.label = label
        self.state = state
        self.updatedAt = updatedAt
        self.taskLabel = taskLabel
        self.observedAt = observedAt
        self.startedAt = startedAt
        self.originProcessID = originProcessID
        self.originBundleIdentifier = originBundleIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case harness
        case label
        case state
        case updatedAt
        case observedAt
        case startedAt
        case originProcessID
        case originBundleIdentifier
    }
}
