# Atoll

Atoll is a native macOS menu-bar app that shows a Dynamic-Island-style session capsule for local coding agents.

Supported scanners:

- OpenCode
- OpenAI Codex CLI / Codex app local sessions
- Claude Code
- GitHub Copilot CLI

Atoll reads local session stores and uses process/lock-file heuristics to distinguish recent running sessions, completed sessions, sessions waiting for user input, and sessions waiting for permission approval.

## Build

```sh
swift build -c release
```

## Release Bundle

```sh
./Scripts/build-release.sh --install
```

The release bundle is installed as `/Applications/Atoll.app`.
