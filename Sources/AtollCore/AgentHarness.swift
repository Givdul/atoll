import Foundation

public enum AgentHarness: String, Codable, CaseIterable, Identifiable, Sendable {
    case opencode
    case codex
    case claude
    case copilot
    case pi
    case atoll

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .opencode:
            "OpenCode"
        case .codex:
            "Codex"
        case .claude:
            "Claude Code"
        case .copilot:
            "GitHub Copilot"
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
        case .copilot:
            "GH"
        case .pi:
            "PI"
        case .atoll:
            "AT"
        }
    }

    public var processHints: [String] {
        switch self {
        case .opencode:
            ["opencode"]
        case .codex:
            ["codex", "codex-app", "codex-vscode"]
        case .claude:
            ["claude"]
        case .copilot:
            ["copilot", "copilot-cli"]
        case .pi:
            ["pi", "pi-island"]
        case .atoll:
            ["atoll"]
        }
    }
}
