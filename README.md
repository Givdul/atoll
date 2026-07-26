# Atoll

Atoll is a native macOS menu-bar app that shows a Dynamic-Island-style capsule for local coding agents.

It is event-driven: native agent hooks send minimal lifecycle events to a user-only local Unix socket. Atoll never infers a live run from transcript age, process names, or lock files.

## Lifecycle model

- `started` shows a running session immediately.
- `finished`, `failed`, and `cancelled` end that session immediately.
- `needsInput` and `needsPermission` remain distinct attention states when an agent supplies a typed event.
- Events are queued under `~/.atoll` before the sender is acknowledged and removed only after Atoll persists the resulting lifecycle state. Replay is safe and duplicate terminals do not extend their display time.
- Active events expire after ten minutes of local inactivity. Terminal rows receive a perceptible local dwell, while retained tombstones suppress late cleanup events and repeated completion notifications.
- Provider clocks are used for ordering only after future-skew clamping; they cannot keep a session alive or make a delayed terminal disappear instantly.
- When a hook originates inside a regular macOS application, its session row opens that application. Atoll reactivates the captured process when possible, falls back to the same bundle identifier after an app restart, and leaves genuinely headless sessions noninteractive; it does not navigate to a specific thread, window, tab, or pane.

## Lifecycle privacy

Atoll retains only the agent provider, provider session ID, normalized state, provider and local ordering/delivery timestamps, a project-folder label (or `"<Provider> session"`), and the complete origin process-ID/bundle-ID pair used by click-to-return. Delivery identities are Atoll-generated IDs or SHA-256 digests used for replay deduplication.

Provider hook payloads may include prompts or other content on standard input. Atoll discards that content while normalizing the event, so it never enters Atoll's socket protocol, durable queue, registry, UI, logs, or uploads. This includes provider messages and reasons, responses, commands, transcripts, diffs, environment values, model identifiers, and full working-directory paths; the project label is derived locally from only the working directory's final component.

## Native hook integrations

On first launch, Atoll offers to add live status only when it detects a supported agent that is not already configured. You can also return to **Live Status Setup…** from the menu at any time to repair or install hooks. Atoll makes no configuration changes until you select **Add Live Status**; setup preserves existing settings, disabled-hook choices, and malformed configuration for the user to repair.

The setup installs user-level hooks for:

- Codex: `UserPromptSubmit` and `Stop`
- Claude Code: `UserPromptSubmit`, `Stop`, `StopFailure`, and typed permission/input notifications
- Cursor Agent: `beforeSubmitPrompt` and `stop`
- OpenCode: a global plugin observing session status/error plus current and legacy permission/question events
- Pi 0.80.4 or newer: a global TypeScript extension using `agent_start`, `agent_end`, and `agent_settled`

The installer preserves existing settings and hooks. It verifies the exact managed integration, bridge contents, and bridge permissions after writing, but that is static readiness rather than proof of runtime activation. Codex may still require `/hooks` review; extensions and plugins may need a reload or new session. Atoll honors inherited custom user homes documented by Codex, Claude Code, OpenCode, and Pi, while leaving project and policy layers untouched.

See [Live Status Support](LIVE_STATUS_SUPPORT.md) for the source-linked event contract, state fidelity, activation requirements, and release limitations for every shipped integration.

The supported harnesses can also send the same normalized protocol through the Atoll executable:

```sh
printf '%s' '{"session_id":"session-123","cwd":"/path/to/project"}' \
  | /Applications/Atoll.app/Contents/MacOS/Atoll --lifecycle-event codex started
```

Use `finished`, `failed`, `cancelled`, `needsInput`, or `needsPermission` as the final argument for the corresponding lifecycle transition.

## Build

```sh
swift test
./Scripts/build-release.sh --install
```

The release script builds and verifies a universal `arm64` + `x86_64` bundle, signs embedded Sparkle components inside-out, and installs `/Applications/Atoll.app` with rollback on failure. The default signature is ad hoc for local builds. Distribution requires a Developer ID identity plus the external notarization and Sparkle feed credentials described by the script's environment variables.
