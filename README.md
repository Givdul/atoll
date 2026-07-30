# Topside

Topside is a calm status light for exactly five local coding agents: Codex, Claude Code, Cursor Agent, OpenCode, and Pi. Its native macOS menu-bar capsule shows what is running, waiting, or finished without becoming another agent dashboard.

It is event-driven: native agent hooks send minimal lifecycle events to a user-only local Unix socket. Topside never infers a live run from transcript age, process names, or lock files.

The complete product includes one 72-hour trial followed by a $7.99 one-time
Polar license—no account or subscription. See [Licensing](LICENSING.md)
for the Keychain, offline, privacy, release-configuration, and validation
boundaries.

## Lifecycle model

- `started` shows a running session immediately.
- `finished`, `failed`, and `cancelled` end that session immediately.
- `needsInput` and `needsPermission` remain distinct attention states when an agent supplies a typed event.
- Events are queued under `~/.topside` before the sender is acknowledged and removed only after Topside persists the resulting lifecycle state. Replay is safe and duplicate terminals do not extend their display time.
- Optional native notifications are off by default and limited to new input, approval, or failure transitions when the captured originating app is not frontmost.
- Active events expire after ten minutes of local inactivity. Terminal rows receive a perceptible local dwell, while retained tombstones suppress late cleanup events and repeated completion notifications.
- Provider clocks are used for ordering only after future-skew clamping; they cannot keep a session alive or make a delayed terminal disappear instantly.
- When a hook originates inside a regular macOS application, its session row opens that application. Topside reactivates the captured process when possible, falls back to the same bundle identifier after an app restart, and leaves genuinely headless sessions noninteractive; it does not navigate to a specific thread, window, tab, or pane.

## Lifecycle privacy

Topside retains only the agent provider, provider session ID, normalized state, provider and local ordering/delivery timestamps, a project-folder label (or `"<Provider> session"`), and the complete origin process-ID/bundle-ID pair used by click-to-return. Delivery identities are Topside-generated IDs or SHA-256 digests used for replay deduplication. Separately, the runtime doctor retains only each provider identity and its latest valid local event time; that evidence survives ordinary session expiry.

Provider hook payloads may include prompts or other content on standard input. Topside discards that content while normalizing the event, so it never enters Topside's socket protocol, durable queue, registry, UI, logs, or uploads. This includes provider messages and reasons, responses, commands, transcripts, diffs, environment values, model identifiers, and full working-directory paths; the project label is derived locally from only the working directory's final component.

## Native hook integrations

On first launch, Topside offers setup only when it detects a supported agent that is not already configured. **Live Status Doctor…** in the menu always shows all five supported providers and checks agent detection, integration content, the private bridge, managed-policy blocking where locally visible, the app socket, and the last valid event separately. `Ready` requires runtime evidence; a matching file alone is never enough.

The doctor changes nothing until you select a provider-specific **Repair** action. Repair rewrites only missing, stale, or partial Topside-owned content, reruns diagnostics in the same panel, and preserves malformed, disabled, project-level, policy-managed, or unowned configuration.

The setup installs user-level hooks for:

- Codex: `UserPromptSubmit` and `Stop`
- Claude Code: `UserPromptSubmit`, `Stop`, `StopFailure`, and typed permission/input notifications
- Cursor Agent: `beforeSubmitPrompt` and `stop`
- OpenCode: a global plugin observing session status/error plus current and legacy permission/question events
- Pi 0.80.4 or newer: a global TypeScript extension using `agent_start`, `agent_end`, and `agent_settled`

The installer preserves existing settings and hooks. It verifies the exact managed integration, bridge contents, and bridge permissions after writing, but that is static readiness rather than proof of runtime activation. Codex may still require `/hooks` review; extensions and plugins may need a reload or new session. Topside honors inherited custom user homes documented by Codex, Claude Code, OpenCode, and Pi, while leaving project and policy layers untouched.

See [Live Status Support](LIVE_STATUS_SUPPORT.md) for the source-linked event contract, state fidelity, activation requirements, and release limitations for every shipped integration.

Existing installs migrate known app-owned state and defaults once using Topside → Skerry → Atoll precedence without overwriting Topside data or deleting either legacy tree. A private completion marker is committed only after file and defaults migration both succeed, and lifecycle-event CLI calls never run migration. Repair recognizes exact Skerry- and Atoll-owned integrations for all five providers and replaces only verified entries. See [Product identity](PRODUCT_IDENTITY.md) for the permanent identity and compatibility boundary.

The supported harnesses can also send the same normalized protocol through the Topside executable:

```sh
printf '%s' '{"session_id":"session-123","cwd":"/path/to/project"}' \
  | /Applications/Topside.app/Contents/MacOS/Topside --lifecycle-event codex started
```

Use `finished`, `failed`, `cancelled`, `needsInput`, or `needsPermission` as the final argument for the corresponding lifecycle transition.

## Build

Run the same checks as CI:

```sh
swift build --product Topside
swift test
./Scripts/test-lifecycle-queue-concurrency.sh
```

Build and install the universal local app:

```sh
./Scripts/build-release.sh --install
```

The release script builds and verifies a universal `arm64` + `x86_64` bundle, signs embedded Sparkle components inside-out, and installs `/Applications/Topside.app` with rollback on failure. The default signature is ad hoc for local builds. Distribution requires a Developer ID identity plus the external notarization and Sparkle feed credentials described by the script's environment variables.

Release operators should follow [Releasing Topside](RELEASING.md). Buyers can
read the [privacy policy](PRIVACY.md), [license and sale terms](TERMS.md),
[support tracker](https://github.com/Givdul/atoll/issues), and bundled
third-party notices from Topside's menu.
