# Repository Instructions

- Always assume changes are to be done in the directory the thread is spawned in. If you want to traverse to external directories, stop and notify or ask permission from the user even if in full access mode.
- The main thread should act as the planner: keep high-level context, decide the approach, integrate results, and make final judgments.
- Prefer splitting substantial work into well-scoped subagents to keep main-thread context low, especially for parallelizable research, isolated code changes, and verification.
- Scout subagent: explorer, reads repo to find correct context and reports back, prefers to use gpt 5.4 mini as model.
- Worker subagent: code editor, implements code and code changes, prefer to use GPT 5.3 Codex Spark as model with high thinking effort.
- Do not delegate trivial tasks, work on the immediate critical path, or tightly coupled tasks that require continuous local judgment.
- When a subagent is no longer needed, clean it up promptly.
- After each fix, rebuild the release app into `/Applications` with `./Scripts/build-release.sh --install`, then restart Atoll from `/Applications/Atoll.app`.

## Commit and Publish Workflow

- This workflow is adapted from the user-level `~/.agents/skills/yeet/AGENTS.md` guidance. When that file is available, use it as the detailed source for git publish commands and safety rules.
- When working in Atoll, commit automatically at natural checkpoints after a coherent fix or feature slice is implemented and verified.
- Prefer small, step-by-step commits over one large mixed commit when changes can be separated cleanly.
- Before each commit, inspect `git status --short`, `git diff --stat`, and the staged diff enough to understand what is being published.
- Stage only files that belong to the current Atoll work. Do not revert or overwrite unrelated user changes.
- Generate commit messages and PR metadata in the current thread; do not use a separate generation provider or model.
- Use one-line commit subjects, max 72 characters, in imperative Conventional Commit style when obvious, such as `fix: recognize Pi agent completion events`.
- Avoid vague commit subjects like `Update files`, `Fix changes`, `Commit changes`, or `Misc changes`.
- Run the focused relevant tests before committing when feasible. If tests are not run, mention that explicitly.
- When the user asks to publish, push the current branch to GitHub after the commit succeeds.
- Do not amend, rebase, force-push, merge, or delete branches unless the user explicitly asks.
- If working on the default branch, commit and push only; skip pull request creation.
