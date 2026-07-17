# Live Status Support

This is the release contract for Atoll's bundled agent integrations. It was checked against each agent's primary documentation on 2026-07-17.

## State contract

- Every shipped adapter has a documented per-turn signal for **Running** and a documented terminal signal.
- **Done**, **Failed**, and **Cancelled** remain distinct only when the provider supplies a reliable outcome.
- **Needs Input** and **Needs Approval** are available to external integrations through Atoll's normalized protocol, but no bundled adapter currently claims them.
- Active state expires after ten minutes without a newer event. This conservative freshness window prevents a missed terminal hook from leaving an orphan visible forever.
- The table covers standard user-level configuration locations. Custom homes or enterprise policies that disable user hooks are outside the current automatic setup contract.

## Shipped integrations

| Agent | User-level integration | Running signal | Terminal signal | Outcome fidelity and activation |
| --- | --- | --- | --- | --- |
| [Codex](https://developers.openai.com/codex/hooks) | `~/.codex/hooks.json` | `UserPromptSubmit` | `Stop` -> Done | Codex requires review and trust of a new or changed command hook through `/hooks` before it executes. |
| [Claude Code](https://code.claude.com/docs/en/hooks) | `~/.claude/settings.json` | `UserPromptSubmit` | `Stop` -> Done; `StopFailure` -> Failed | `StopFailure` is the documented API-error terminal event. |
| [Gemini CLI](https://geminicli.com/docs/hooks/reference/) | `~/.gemini/settings.json` | `BeforeAgent` | `AfterAgent` -> Done | No reliable turn-level failed/cancelled hook is documented, so Atoll does not infer one. |
| [GitHub Copilot CLI](https://docs.github.com/en/copilot/reference/hooks-reference) | `~/.copilot/hooks/atoll.json` | `userPromptSubmitted` | `agentStop` -> Done; `sessionEnd.reason` -> Done, Failed, or Cancelled | `errorOccurred` is deliberately ignored because it may be recoverable. |
| [Cursor Agent](https://cursor.com/docs/hooks) | `~/.cursor/hooks.json` | `beforeSubmitPrompt` | `stop.status` -> Done, Failed, or Cancelled | `completed`, `error`, and `aborted` are preserved instead of flattened. |
| [Factory Droid](https://docs.factory.ai/reference/hooks-reference) | `~/.factory/hooks.json` | `UserPromptSubmit` | `Stop` -> Done | Droid may require review of externally changed hooks through `/hooks`; organization policy can disable user hooks. |
| [Qoder](https://docs.qoder.com/en/cli/hooks) | `~/.qoder/settings.json` | `UserPromptSubmit` | `Stop` -> Done; `StopFailure` -> Failed | The IDE extension may require restart after hook changes. |
| [Qwen Code](https://qwenlm.github.io/qwen-code-docs/en/users/features/hooks/) | `~/.qwen/settings.json` | `UserPromptSubmit` | `Stop` -> Done; `StopFailure` -> Failed | Default home only; disabled hooks and a custom `QWEN_HOME` are not automatically verified. |
| [Pi](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/extensions.md) | `~/.pi/agent/extensions/atoll.ts` | `agent_start` | `agent_settled` -> Done | Requires Pi 0.80.4 or newer because that release introduced `agent_settled`. |
| [OpenCode](https://opencode.ai/docs/plugins/) | `~/.config/opencode/plugins/atoll.js` | `session.status` `busy` or `retry` | `idle` -> Done; `session.error` -> Failed or Cancelled | Uses the plugin-provided project directory and suppresses the idle event immediately following an error. |
| [Hermes](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/hooks.md) | `~/.hermes/plugins/atoll-live-status/` for each profile | `pre_llm_call` | `on_session_end` -> Done, Failed, or Cancelled | The managed plugin must also remain enabled in each Hermes profile. |
| [Amp](https://ampcode.com/manual/plugin-api) | `~/.config/amp/plugins/atoll.ts` | `agent.start` | `agent.end.status` -> Done, Failed, or Cancelled | `amp -x` requires Amp's plugin-ready timeout option for start/end-dependent plugins. |

## Excluded after audit

- **Kiro CLI** is not shipped because stable v2 and early-access v3 use incompatible hook schemas, the old adapter did not cover the default agent or project-local agents, and its stop hook is not an unconditional settled boundary.
- **Kimi Code** is not shipped because prompt/stop hooks can be blocked or continued, interrupt needs a separate terminal event, and automatic setup could not safely validate arbitrary existing TOML.
- **CodeBuddy** is not shipped because CLI hooks are beta and version-gated, while its blockable stop contract and missing general cancellation event do not meet the stable release bar.

Atoll can add these agents again when their stable documented contracts and executable test fixtures meet the same bar as the shipped integrations.
