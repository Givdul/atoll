# Atoll

Atoll is a native macOS menu-bar app that shows a Dynamic-Island-style capsule for local coding agents.

It is event-driven: native agent hooks send lifecycle events to a user-only local Unix socket. Atoll persists only the resulting session state; it never infers a live run from transcript age, process names, or lock files.

## Lifecycle model

- `started` shows a running session immediately.
- `finished`, `failed`, and `cancelled` end that session immediately.
- `needsInput` and `needsPermission` are optional protocol states; the bundled adapters do not claim native coverage for them.
- Events emitted while Atoll is closed are queued under `~/.atoll` and consumed at launch.
- Active events expire after ten minutes if no newer lifecycle event arrives, so an orphan cannot remain visible indefinitely.

## Native hook integrations

On first launch, Atoll offers to add live status for the supported agents it detects locally. You can also return to **Live Status Setup…** from the menu at any time to repair or install hooks. Atoll makes no configuration changes until you select **Add Live Status**; setup preserves existing settings and reports invalid existing configuration per agent.

The setup installs user-level hooks for:

- Codex: `UserPromptSubmit` and `Stop`
- Claude Code: `UserPromptSubmit`, `Stop`, and `StopFailure`
- Gemini CLI: `BeforeAgent` and `AfterAgent`
- GitHub Copilot CLI: `userPromptSubmitted`, `agentStop`, and `sessionEnd`
- Pi 0.80.4 or newer: a global TypeScript extension using `agent_start` and `agent_settled`
- OpenCode: a global plugin observing `session.status` and `session.error`
- Cursor Agent: `beforeSubmitPrompt` and `stop`
- Factory Droid: `UserPromptSubmit` and `Stop`
- Qoder and Qwen Code: `UserPromptSubmit`, `Stop`, and `StopFailure`
- Hermes: a managed plugin for the default home and each named profile, using `pre_llm_call` and `on_session_end`
- Amp: a global plugin using `agent.start` and `agent.end`

The installer preserves existing settings and hooks. It verifies the exact managed integration, bridge contents, and bridge permissions after writing. Codex and Factory Droid may still require a one-time review of newly changed hooks through their `/hooks` command before those hooks execute.

See [Live Status Support](LIVE_STATUS_SUPPORT.md) for the source-linked event contract, state fidelity, activation requirements, and release limitations for every shipped integration.

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
