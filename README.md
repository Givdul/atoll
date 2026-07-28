# Skerry

Skerry is a calm status light for exactly five local coding agents: Codex, Claude Code, Cursor Agent, OpenCode, and Pi. Its native macOS menu-bar capsule shows what is running, waiting, or finished without becoming another agent dashboard.

It is event-driven: native agent hooks send minimal lifecycle events to a user-only local Unix socket. Skerry never infers a live run from transcript age, process names, or lock files.

The complete product includes one 72-hour trial followed by a $7.99 one-time
Polar license—no account or subscription. See [Licensing](LICENSING.md)
for the Keychain, offline, privacy, release-configuration, and validation
boundaries.

## Lifecycle model

- `started` shows a running session immediately.
- `finished`, `failed`, and `cancelled` end that session immediately.
- `needsInput` and `needsPermission` remain distinct attention states when an agent supplies a typed event.
- Events are queued under `~/.skerry` before the sender is acknowledged and removed only after Skerry persists the resulting lifecycle state. Replay is safe and duplicate terminals do not extend their display time.
- Optional native notifications are off by default and limited to new input, approval, or failure transitions when the captured originating app is not frontmost.
- Active events expire after ten minutes of local inactivity. Terminal rows receive a perceptible local dwell, while retained tombstones suppress late cleanup events and repeated completion notifications.
- Provider clocks are used for ordering only after future-skew clamping; they cannot keep a session alive or make a delayed terminal disappear instantly.
- When a hook originates inside a regular macOS application, its session row opens that application. Skerry reactivates the captured process when possible, falls back to the same bundle identifier after an app restart, and leaves genuinely headless sessions noninteractive; it does not navigate to a specific thread, window, tab, or pane.

## Lifecycle privacy

Skerry retains only the agent provider, provider session ID, normalized state, provider and local ordering/delivery timestamps, a project-folder label (or `"<Provider> session"`), and the complete origin process-ID/bundle-ID pair used by click-to-return. Delivery identities are Skerry-generated IDs or SHA-256 digests used for replay deduplication. Separately, the runtime doctor retains only each provider identity and its latest valid local event time; that evidence survives ordinary session expiry.

Provider hook payloads may include prompts or other content on standard input. Skerry discards that content while normalizing the event, so it never enters Skerry's socket protocol, durable queue, registry, UI, logs, or uploads. This includes provider messages and reasons, responses, commands, transcripts, diffs, environment values, model identifiers, and full working-directory paths; the project label is derived locally from only the working directory's final component.

## Native hook integrations

On first launch, Skerry offers setup only when it detects a supported agent that is not already configured. **Live Status Doctor…** in the menu always shows all five supported providers and checks agent detection, integration content, the private bridge, managed-policy blocking where locally visible, the app socket, and the last valid event separately. `Ready` requires runtime evidence; a matching file alone is never enough.

The doctor changes nothing until you select a provider-specific **Repair** action. Repair rewrites only missing, stale, or partial Skerry-owned content, reruns diagnostics in the same panel, and preserves malformed, disabled, project-level, policy-managed, or unowned configuration.

The setup installs user-level hooks for:

- Codex: `UserPromptSubmit` and `Stop`
- Claude Code: `UserPromptSubmit`, `Stop`, `StopFailure`, and typed permission/input notifications
- Cursor Agent: `beforeSubmitPrompt` and `stop`
- OpenCode: a global plugin observing session status/error plus current and legacy permission/question events
- Pi 0.80.4 or newer: a global TypeScript extension using `agent_start`, `agent_end`, and `agent_settled`

The installer preserves existing settings and hooks. It verifies the exact managed integration, bridge contents, and bridge permissions after writing, but that is static readiness rather than proof of runtime activation. Codex may still require `/hooks` review; extensions and plugins may need a reload or new session. Skerry honors inherited custom user homes documented by Codex, Claude Code, OpenCode, and Pi, while leaving project and policy layers untouched.

See [Live Status Support](LIVE_STATUS_SUPPORT.md) for the source-linked event contract, state fidelity, activation requirements, and release limitations for every shipped integration.

Existing beta installs migrate known app-owned state and defaults from `~/.atoll` once, without overwriting Skerry state. A private completion marker is committed only after both stores succeed, preventing later lifecycle CLI calls from re-seeding consumed beta queue events. Repair recognizes exact beta-owned integrations for all five providers and replaces only those entries. See [Product identity](PRODUCT_IDENTITY.md) for the permanent identity, migration boundary, support/update identity, and dated name checks.

The supported harnesses can also send the same normalized protocol through the Skerry executable:

```sh
printf '%s' '{"session_id":"session-123","cwd":"/path/to/project"}' \
  | /Applications/Skerry.app/Contents/MacOS/Skerry --lifecycle-event codex started
```

Use `finished`, `failed`, `cancelled`, `needsInput`, or `needsPermission` as the final argument for the corresponding lifecycle transition.

## Build

```sh
swift test
./Scripts/build-release.sh --install
```

The release script builds and verifies a universal `arm64` + `x86_64` bundle, signs embedded Sparkle components inside-out, and installs `/Applications/Skerry.app` with rollback on failure. The default signature is ad hoc for local builds. Distribution requires a Developer ID identity plus the external notarization and Sparkle feed credentials described by the script's environment variables.
