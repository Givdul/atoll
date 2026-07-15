# Atoll

Atoll is a native macOS menu-bar app that shows a Dynamic-Island-style capsule for local coding agents.

It is event-driven: native agent hooks send lifecycle events to a user-only local Unix socket. Atoll persists only the resulting session state; it never infers a live run from transcript age, process names, or lock files.

## Lifecycle model

- `started` shows a running session immediately.
- `finished`, `failed`, and `cancelled` end that session immediately.
- `needsInput` and `needsPermission` are optional, supported by the same protocol.
- Events emitted while Atoll is closed are queued under `~/.atoll` and consumed at launch.
- Active events expire after ten minutes if no newer lifecycle event arrives, so an orphan cannot remain visible indefinitely.

## Native hook integrations

On first launch, Atoll offers to enable live status for the supported agents it detects locally. You can also return to **Live Status Setup…** from the menu at any time to inspect, repair, or install hooks. Atoll makes no configuration changes until you select **Enable Live Status**; setup preserves existing settings and reports invalid existing configuration per agent.

The setup installs user-level hooks for:

- Claude Code: `UserPromptSubmit`, `Stop`, and `SessionEnd`
- Codex: `UserPromptSubmit` and `Stop`
- Gemini CLI: `BeforeAgent`, `AfterAgent`, and `SessionEnd`
- GitHub Copilot CLI: `userPromptSubmitted`, `agentStop`, `sessionEnd`, and `errorOccurred`
- Pi: a global TypeScript extension using `agent_start` and `agent_settled`
- OpenCode: a global plugin observing `session.status`
- Cursor Agent: `sessionStart`, `stop`, and `sessionEnd`
- Factory Droid, Qoder, and Qwen Code: prompt, stop, and session-end hooks
- Kimi Code: global lifecycle hook rules
- Kiro CLI: hooks added to each existing custom-agent configuration
- Hermes: a managed plugin for the default home and each named profile, using `pre_llm_call` and `on_session_end`
- Amp: a global plugin using `agent.start` and `agent.end`
- CodeBuddy: `UserPromptSubmit`, `Stop`, `StopFailure`, and `SessionEnd`

The installer preserves existing settings and hooks. It writes the bridge script to `~/.atoll/bin/atoll-hook`, then sends a harmless local verification event so setup can confirm that Atoll receives it.

Other harnesses can send the same normalized protocol through the Atoll executable:

```sh
printf '%s' '{"session_id":"session-123","cwd":"/path/to/project","prompt":"Fix auth"}' \
  | /Applications/Atoll.app/Contents/MacOS/Atoll --lifecycle-event codex started
```

Use `finished`, `failed`, `cancelled`, `needsInput`, or `needsPermission` as the final argument for the corresponding lifecycle transition.

## Build

```sh
swift test
./Scripts/build-release.sh --install
```

The release bundle is installed as `/Applications/Atoll.app`.
