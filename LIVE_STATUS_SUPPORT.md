# Live Status Support

This is the release contract for Atoll's bundled agent integrations. It was re-checked against each agent's primary documentation on 2026-07-25.

## State and delivery contract

- **Running**, **Needs Input**, **Needs Approval**, **Done**, **Failed**, and **Cancelled** are separate protocol states. A bundled adapter claims only states backed by a typed, documented provider event.
- Attention states are display-only. Atoll does not answer questions, approve tools, or change an agent's permission mode.
- Provider timestamps are retained as source metadata, but freshness and terminal dwell use Atoll's local receipt time. A future-skewed provider clock therefore cannot pin a session or reject later legitimate events.
- Active state expires after ten minutes without a newer event. Terminal rows remain in the registry for five seconds and receive a three-second UI dwell from the moment the app observes them, including delayed queued events.
- Terminal records remain as non-visible tombstones for ten minutes. This suppresses late cleanup events and duplicate completion notifications without hiding a genuinely newer turn.
- Repeated identical terminals do not extend their dwell. A later terminal correction does receive a new dwell, and a generic **Done** cleanup cannot overwrite a more specific **Failed** or **Cancelled** result.
- Socket delivery is at-least-once: a valid event is durably queued before the sender is acknowledged, and the queue item is removed only after the lifecycle registry is persisted. Duplicate replay is intentionally safe.
- Lifecycle storage is limited to provider, session ID, normalized state, provider/local ordering and delivery timestamps, a final-component project label (or `"<Provider> session"`), replay-deduplication identities, and the complete origin PID/bundle pair used by click-to-return. Prompt, message, reason, response, command, transcript, diff, environment, model, and full working-directory content is discarded before socket or queue serialization.

## Setup and readiness contract

Atoll changes agent configuration only after the user selects **Add Live Status**. Existing hooks are merged structurally, unrelated entries are retained, and malformed or explicitly disabled configurations are reported without being rewritten.

`Configured` means that Atoll verified its current user-level file, command bridge, and bridge permissions. It does **not** prove that a running agent has reloaded the file, that a trust prompt was accepted, or that enterprise/system policy permits user hooks. A plugin reload or new agent session may still be required.

Atoll honors inherited absolute or home-relative custom user homes for `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `OPENCODE_CONFIG_DIR`, and `PI_CODING_AGENT_DIR`. Relative custom homes are deliberately not guessed by the GUI because their meaning depends on the launching shell's working directory. Project, system, and managed-policy layers are never modified.

## Shipped integrations

| Agent | Boundary and states | Failure / cancellation fidelity | Input / approval fidelity | User config, version, and activation |
| --- | --- | --- | --- | --- |
| [Codex](https://developers.openai.com/codex/hooks) | Per turn: `UserPromptSubmit` -> Running; `Stop` -> Done. `Stop` is a response boundary that another hook can continue. | No typed failed or interrupted terminal is currently claimed. | None. `PermissionRequest` is a pre-decision policy hook, so treating every invocation as a visible user wait would create false positives. | `$CODEX_HOME/hooks.json`, default `~/.codex/hooks.json`. Atoll reports a user `config.toml` `[features] hooks = false` setting without changing it. New/changed command hooks require review through `/hooks`; managed policy can ignore user hooks. |
| [Claude Code](https://code.claude.com/docs/en/hooks) | Per response: `UserPromptSubmit` -> Running; `Stop` -> Done. `Stop` can continue the agent and does not fire on user interrupt. | `StopFailure` -> Failed for documented API errors; no reliable cancellation event is claimed. | Typed `permission_prompt` -> Needs Approval; `elicitation_dialog` and `agent_needs_input` (Claude Code 2.1.198+) -> Needs Input. Documented completion, denial, and post-tool events resume Running. | `$CLAUDE_CONFIG_DIR/settings.json`, default `~/.claude/settings.json`. `disableAllHooks` is preserved and reported. Existing sessions may need to reload settings. |
| [Cursor Agent](https://cursor.com/docs/hooks) | Per turn: `beforeSubmitPrompt` -> Running; `stop` -> terminal. | `stop.status` preserves `completed` -> Done, `error` -> Failed, and `aborted` -> Cancelled. | No typed bundled attention mapping is claimed. | `~/.cursor/hooks.json`, schema version 1. The global user file covers local Cursor Agent; cloud agents use project, team, or enterprise hooks. |
| [OpenCode](https://opencode.ai/docs/plugins/) | Per session activity cycle: `session.status` `busy`/`retry` -> Running; `session.idle` or idle status -> Done. | `session.error` -> Failed, except `MessageAbortedError` -> Cancelled. A following idle event cannot flatten or duplicate that result. | Current `permission.asked` and legacy `permission.updated` -> Needs Approval; `question.asked` -> Needs Input. Current and legacy reply/reject shapes resume Running. | `$OPENCODE_CONFIG_DIR/plugins/atoll.js`, default `~/.config/opencode/plugins/atoll.js`, loaded at startup. Current managed source must match; a restart/new session may be needed after repair. |
| [Pi](https://pi.dev/docs/latest/extensions) | Per agent turn: `agent_start` -> Running; the terminal outcome from `agent_end` is emitted only at `agent_settled`, after retries, compaction, and follow-up messages are exhausted. | The last assistant message maps `stop`/`toolUse` -> Done, `error`/`length` -> Failed, and `aborted` -> Cancelled. | No typed bundled attention mapping is claimed. | `$PI_CODING_AGENT_DIR/extensions/atoll.ts`, default `~/.pi/agent/extensions/atoll.ts`; Pi 0.80.4 or newer is required because that release introduced `agent_settled`. Managed file content must match exactly. |
