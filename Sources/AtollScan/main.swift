import AtollCore
import Foundation

let sessions = AgentSessionScanner().scan().filter { session in
    switch session.state {
    case .running, .waitingForInput, .waitingForPermission:
        session.confidence != .historical
    case .done:
        Date().timeIntervalSince(session.updatedAt) <= 8
    case .unknown:
        false
    }
}

for session in sessions {
    let model = session.model.map { " model=\($0)" } ?? ""
    print("\(session.harness.displayName)\t\(session.state.displayName)\t\(session.title)\t\(session.detail)\(model)\t\(session.sourcePath)")
}

if sessions.isEmpty {
    print("No sessions")
}
