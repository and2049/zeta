# Sessions

A session is one conversation in one project. The runtime keeps sessions across the projects it has seen.

## Storage

Each session is an append-only JSONL log at `$XDG_DATA_HOME/zeta/sessions/<project-hash>/<id>.jsonl` (default `~/.local/share/zeta/sessions/`). Lines are messages, plus `system` lines recording the exact system prompt and tool declarations sent to the model (written again only when they change). Tool output too long for the model, and file backups supplied by tools, are kept beside it in `<id>.artifacts/`.

A new session is not written to disk until its first message. On start the runtime restores every log it finds; a log cut off mid-line keeps its complete lines, and tool calls left without results are recorded as interrupted. Interrupted runs are not resumed. An open session is locked so another runtime never loads it at the same time.

Never edit a log while a runtime has it open.

## Working with sessions

The core supports search, usage totals, undo, move, fork and compaction. Undo puts back each file a tool backed up for the reply, unless it changed again since. A move rehomes the session in the new directory's project (its git root) and adds a note to the conversation. A fork keeps the same model selection and gets its own copy of saved tool output. See [compaction](compaction.md) for what a summary keeps.

## Model and thinking level

A new session uses `model` from config, else the model last picked anywhere (`<state>/model.json`), else the first model of the first connected provider. On its first run it pins that model and thinking level; changing config later affects new sessions only. Changing a session's selection takes effect on its next run.

## Reading a log

The first line is a `session` header (`id`, `location`, `title`, and the model selection under `metadata`). Each message line is `{"type": "message", "message": {…}}`; a message has `role` (`user`, `assistant`, `tool_result`), `content` blocks (`text`, `thinking`, `toolCall`, `image`) and an `id`. User messages zeta added itself carry `origin`: `compaction` (a summary), `hook` (hook context or a stop continuation), `undo` or `move`. Assistant messages carry `usage`, `stopReason`, `systemHash` (the `system` line they were sent with) and `completedAt`. The model's view after a compaction starts at the summary and continues from its `firstKeptId`.
