import Foundation

public enum AgentHarness: String, Codable, CaseIterable, Identifiable, Sendable {
    case opencode
    case codex
    case claude
    case gemini
    case cursor
    case droid
    case qoder
    case qwen
    case copilot
    case hermes
    case amp
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
        case "opencode", "openCode", "oc":
            return .opencode
        case "codex", "codexcli", "openaicodex", "openaicodexcli", "codexapp", "codexdesktop", "codexvscode":
            return .codex
        case "claude", "claudecode", "anthropic", "anthropicclaude":
            return .claude
        case "gemini", "geminicli", "googlegemini", "googlegeminicli":
            return .gemini
        case "cursor", "cursoragent", "cursorcli":
            return .cursor
        case "droid", "factorydroid", "factory":
            return .droid
        case "qoder", "qodercli", "tongyilingma", "lingma":
            return .qoder
        case "qwen", "qwencode", "qwencodercli", "alibabaqwen", "alibabaqwencode":
            return .qwen
        case "copilot", "copilotcli", "githubcopilot", "githubcopilotcli", "ghcopilot":
            return .copilot
        case "hermes", "hermescli", "nousresearchhermes":
            return .hermes
        case "amp", "ampcli", "sourcegraphamp":
            return .amp
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
        case .gemini:
            "Gemini CLI"
        case .cursor:
            "Cursor Agent"
        case .droid:
            "Factory Droid"
        case .qoder:
            "Qoder"
        case .qwen:
            "Qwen Code"
        case .copilot:
            "GitHub Copilot"
        case .hermes:
            "Hermes"
        case .amp:
            "Amp"
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
        case .gemini:
            "GM"
        case .cursor:
            "CR"
        case .droid:
            "DR"
        case .qoder:
            "QD"
        case .qwen:
            "QW"
        case .copilot:
            "GH"
        case .hermes:
            "HM"
        case .amp:
            "AM"
        case .pi:
            "PI"
        case .atoll:
            "AT"
        }
    }

}
