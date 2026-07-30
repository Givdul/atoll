import Foundation

public struct ApplicationIdentity: Equatable, Sendable {
    public var processID: Int32
    public var bundleIdentifier: String

    public init?(processID: Int32, bundleIdentifier: String?) {
        let bundleIdentifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard processID > 0, let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }

        self.processID = processID
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct SessionNotification: Equatable, Sendable {
    public var identifier: String
    public var title: String
}

public enum NotificationAuthorizationState: Sendable {
    case notDetermined
    case authorized
    case denied
}

public enum SessionNotificationPolicy {
    public static func notifications(
        previousSessions: [AgentSession]?,
        currentSessions: [AgentSession],
        isEnabled: Bool,
        frontmostApplication: ApplicationIdentity?
    ) -> [SessionNotification] {
        guard isEnabled, let previousSessions else {
            return []
        }

        let previousStates = Dictionary(uniqueKeysWithValues: previousSessions.map { ($0.id, $0.state) })
        return currentSessions.compactMap { session in
            guard previousStates[session.id] != session.state,
                  let action = action(for: session.state),
                  !originMatchesFrontmostApplication(session, frontmostApplication) else {
                return nil
            }

            return SessionNotification(
                identifier: "topside.\(session.id).\(session.state.rawValue)",
                title: "\(session.harness.displayName) \(action)"
            )
        }
    }

    public static func shouldRequestAuthorization(
        forUserInitiatedEnable enabled: Bool,
        status: NotificationAuthorizationState
    ) -> Bool {
        enabled && status == .notDetermined
    }

    public static func isLegacyOwnedIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix("skerry.") || identifier.hasPrefix("atoll.")
    }

    private static func action(for state: SessionState) -> String? {
        switch state {
        case .waitingForInput:
            "needs input"
        case .waitingForPermission:
            "needs approval"
        case .failed:
            "failed"
        case .running, .done, .cancelled, .unknown:
            nil
        }
    }

    private static func originMatchesFrontmostApplication(
        _ session: AgentSession,
        _ frontmostApplication: ApplicationIdentity?
    ) -> Bool {
        guard let origin = ApplicationIdentity(
            processID: session.originProcessID ?? 0,
            bundleIdentifier: session.originBundleIdentifier
        ) else {
            return false
        }

        return origin == frontmostApplication
    }
}

public struct SessionNotificationTracker: Sendable {
    private var previousSessions: [AgentSession]?

    public init() {}

    public mutating func synchronize(_ sessions: [AgentSession]) {
        previousSessions = sessions
    }

    public mutating func notifications(
        for currentSessions: [AgentSession],
        isEnabled: Bool,
        frontmostApplication: ApplicationIdentity?
    ) -> [SessionNotification] {
        guard let previousSessions else {
            return []
        }

        defer { self.previousSessions = currentSessions }
        return SessionNotificationPolicy.notifications(
            previousSessions: previousSessions,
            currentSessions: currentSessions,
            isEnabled: isEnabled,
            frontmostApplication: frontmostApplication
        )
    }
}
