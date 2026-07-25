# Atoll

Atoll is a native macOS menu-bar app that shows a Dynamic-Island-style capsule for local coding agents.

It is event-driven: native agent hooks send lifecycle events to a user-only local Unix socket. Atoll persists only the resulting session state; it never infers a live run from transcript age, process names, or lock files.

## Lifecycle model

- `started` shows a running session immediately.
- `finished`, `failed`, and `cancelled` end that session immediately.
- `needsInput` and `needsPermission` remain distinct attention states when an agent supplies a typed event.
- Events are queued under `~/.atoll` before the sender is acknowledged and removed only after Atoll persists the resulting lifecycle state. Replay is safe and duplicate terminals do not extend their display time.
- Active events expire after ten minutes of local inactivity. Terminal rows receive a perceptible local dwell, while retained tombstones suppress late cleanup events and repeated completion notifications.
- Provider clocks are used for ordering only after future-skew clamping; they cannot keep a session alive or make a delayed terminal disappear instantly.
- When a hook originates inside a regular macOS application, its session row opens that application. Atoll reactivates the captured process when possible, falls back to the same bundle identifier after an app restart, and leaves genuinely headless sessions noninteractive; it does not navigate to a specific thread, window, tab, or pane.

## Native hook integrations

On first launch, Atoll offers to add live status only when it detects a supported agent that is not already configured. You can also return to **Live Status Setup…** from the menu at any time to repair or install hooks. Atoll makes no configuration changes until you select **Add Live Status**; setup preserves existing settings, disabled-hook choices, and malformed configuration for the user to repair.

The setup installs user-level hooks for:

- Codex: `UserPromptSubmit` and `Stop`
- Claude Code: `UserPromptSubmit`, `Stop`, `StopFailure`, and typed permission/input notifications
- Gemini CLI: `BeforeAgent`, `AfterAgent`, and typed tool-permission notifications
- GitHub Copilot CLI: `userPromptSubmitted`, `agentStop`, `sessionEnd`, and typed permission/input notifications
- Pi 0.80.4 or newer: a global TypeScript extension using `agent_start` and `agent_settled`
- OpenCode: a global plugin observing session status/error plus current and legacy permission/question events
- Cursor Agent: `beforeSubmitPrompt` and `stop`
- Factory Droid: `UserPromptSubmit` and `Stop`
- Qoder and Qwen Code: prompt/stop/failure hooks plus documented typed attention events
- Hermes: a managed plugin for the inherited active `HERMES_HOME`, or the default home and each valid named profile when unset, using per-turn lifecycle and prompted-approval observers
- Amp: a global plugin using `agent.start`, `agent.end`, and the stable thread-state observable

The installer preserves existing settings and hooks. It verifies the exact managed integration, bridge contents, and bridge permissions after writing, but that is static readiness rather than proof of runtime activation. Codex and Factory Droid may still require `/hooks` review; managed plugins may need a reload or new session. Atoll honors inherited custom user homes documented by Codex, Claude Code, Gemini CLI, Copilot, Qwen Code, Pi, OpenCode, and Hermes, while leaving project and policy layers untouched.

See [Live Status Support](LIVE_STATUS_SUPPORT.md) for the source-linked event contract, state fidelity, activation requirements, and release limitations for every shipped integration.

See [Competitive Lifecycle Compatibility](COMPETITIVE_COMPATIBILITY.md) for the current evidence-backed comparison with Vibe Island, including explicit unknowns where its public material does not expose lifecycle internals.

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

The release script builds and verifies a universal `arm64` + `x86_64` bundle, signs embedded Sparkle components inside-out, and installs `/Applications/Atoll.app` with rollback on failure. The default signature is ad hoc for local builds. Distribution requires a Developer ID identity plus the external notarization and Sparkle feed credentials described by the script's environment variables.
