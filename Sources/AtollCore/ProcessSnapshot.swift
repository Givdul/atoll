import Foundation

public struct RunningProcess: Hashable, Sendable {
    public var pid: Int32
    public var command: String
    public var arguments: String

    public init(pid: Int32, command: String, arguments: String) {
        self.pid = pid
        self.command = command
        self.arguments = arguments
    }

    public func matches(_ harness: AgentHarness) -> Bool {
        let processNames = processNameCandidates
        return harness.processHints.contains { hint in
            processNames.contains(hint.lowercased())
        }
    }

    private var processNameCandidates: Set<String> {
        let trimCharacters = CharacterSet(charactersIn: "\"'`()[]{}<>.,;:")
        var candidates: Set<String> = []
        let rawTokens = ([command] + arguments.split(whereSeparator: { $0.isWhitespace }).map(String.init))

        for rawToken in rawTokens {
            let token = rawToken.trimmingCharacters(in: trimCharacters).lowercased()
            guard !token.isEmpty else {
                continue
            }

            candidates.insert(token)
            candidates.insert(URL(fileURLWithPath: token).lastPathComponent)
        }

        return candidates
    }
}

public enum ProcessSnapshot {
    public static func capture() -> [RunningProcess] {
        guard let result = CommandRunner.run(
            URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,comm=,args="],
            timeout: 2
        ), result.exitCode == 0 else {
            return []
        }

        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap(parseLine)
    }

    private static func parseLine(_ line: Substring) -> RunningProcess? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return nil
        }

        let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let pid = Int32(parts[0]) else {
            return nil
        }

        let command = String(parts[1])
        let arguments = parts.count == 3 ? String(parts[2]) : command
        return RunningProcess(pid: pid, command: command, arguments: arguments)
    }
}
