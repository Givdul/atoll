import Foundation

public enum AgentHarness: String, Codable, CaseIterable, Identifiable, Sendable {
    case opencode
    case codex
    case claude
    case cursor
    case pi
    case atoll

    public var id: String { rawValue }

    public static func parse(_ rawValue: String?) -> AgentHarness? {
        guard let rawValue else {
            return nil
        }

        let normalized = rawValue
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }

        guard !normalized.isEmpty else {
            return nil
        }

        switch normalized {
        case "opencode", "oc":
            return .opencode
        case "codex", "codexcli", "openaicodex", "openaicodexcli", "codexapp", "codexdesktop", "codexvscode":
            return .codex
        case "claude", "claudecode", "anthropic", "anthropicclaude":
            return .claude
        case "cursor", "cursoragent", "cursorcli":
            return .cursor
        case "pi", "piagent", "piisland":
            return .pi
        case "atoll":
            return .atoll
        default:
            return AgentHarness(rawValue: rawValue.lowercased())
        }
    }

    public var displayName: String {
        switch self {
        case .opencode:
            "OpenCode"
        case .codex:
            "Codex"
        case .claude:
            "Claude Code"
        case .cursor:
            "Cursor Agent"
        case .pi:
            "Pi"
        case .atoll:
            "Atoll"
        }
    }

    public var shortName: String {
        switch self {
        case .opencode:
            "OC"
        case .codex:
            "CX"
        case .claude:
            "CC"
        case .cursor:
            "CR"
        case .pi:
            "PI"
        case .atoll:
            "AT"
        }
    }

}
