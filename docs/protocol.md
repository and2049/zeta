# Current HTTP protocol

The server listens on `127.0.0.1` (first free port starting at 4096), or on the IPv4 address `zeta serve --hostname` gives (see [the overview](README.md)). Discovery credentials and URL live at `$XDG_RUNTIME_DIR/zeta/server.json` with mode 0600. Requests use HTTP Basic auth with username `zeta` and the discovery file's `password`. JSON request bodies use `Content-Type: application/json`.

Typed JSON request bodies reject unknown properties (including unknown properties in typed nested objects) with HTTP 400 `{"error":"UnknownField"}`. Session PATCH likewise rejects fields other than `model`, `title`, and `thinking`.

At most 64 connections are served at once; further connections get 503 and are closed. Request headers must arrive within 10 seconds (of connecting, or of a kept-alive connection's first byte), a request body within 60 seconds, and a kept-alive connection may sit idle for 5 minutes. Handler work and the `/event` stream have no deadline.

- `GET /health` returns version and PID.
- `GET /files?location=<absolute-project>&path=<relative-directory>` lists one directory as `{"entries":[{"name":"src","type":"dir","size":null}]}`, directories first then names alphabetically; `path` defaults to the project root. Types are `dir`, `file`, and `symlink`; regular files include byte `size`.
- `GET /files/find?location=<absolute-project>&q=<query>&limit=<n>` returns `{"matches":[{"path":"src/main.zig","score":42}]}` in descending fuzzy-match score (then path order). `limit` defaults to 50 and is capped at 100. Search skips hidden entries, `node_modules`, `zig-cache`, and `zig-out`, descends at most five levels, and visits at most 10,000 entries.
- `GET /files/read?location=<absolute-project>&path=<relative-file>&offset=<byte>&limit=<bytes>` returns `{"content":"...","size":123,"offset":0}`. Offset defaults to 0, limit to 65,536 bytes (maximum 65,536); files above 1 MiB return 413, binary/non-UTF-8 content returns 422. Offsets and limits must delimit valid UTF-8. All file paths are confined to the normalized project location: absolute paths, `..`, and links leading outside it are rejected with 400; missing files return 404. These routes require the same Basic auth as the other routes.
- `POST /sessions` with `{"location":"/absolute/project"}` creates a session. Optional `profile`, `model`, `thinking` (a thinking level, see [providers](providers.md#thinking-level)) and `environment` selectors are supported.
- `POST /sessions/:id/prompt` with `{"text":"…","delivery":"queue"}` submits work; `steer` is another delivery value. The reply is `{"inboxId":"msg_…"}`, a receipt rather than a completed turn. Inputs are delivered one at a time: a steering input joins the conversation at the next step boundary, and each queued input starts its own follow-up turn once the agent would otherwise stop.
- Prompts may include `images:[{"mimeType":"image/png","data":"<base64>"}]`. PNG, JPEG, GIF, and WebP MIME types are accepted with canonical base64. The complete request remains subject to the 8 MiB body limit; the selected model must support image input. Images are persisted with their user message and encoded as provider content parts.
  While a run is active, image admission uses that run's frozen capability; selecting a vision model for the next run does not enable images in an already running text-only turn. When a later run uses a text-only model, earlier images stay in the log but are sent to the model as a short text notice instead.
- `POST /sessions/:id/fork` with `{"fromMessageId"?: "msg_…"}` copies the session up to and including that message (the latest when omitted; results of that message's tool calls come along) into a new session in the same project with the same model selection, and returns its info with `forkedFrom` (the source session) and `forkedAt` (the last message copied). The two sessions then go on independently; the fork gets its own copies of saved tool output. An unknown message is a 404; a fork that would copy tool calls still running (without their results) is a 409.
- `POST /sessions/:id/compact` with `{"instructions"?: "…"}` queues a compaction of the history and returns `{"inboxId"}`; see [compaction](compaction.md).
- `GET /sessions?location=<absolute-project>&q=<text>` lists sessions (both optional), newest first; with `q`, only those whose title or user/assistant text contains it (ignoring case). New sessions remain available by ID but are neither listed nor saved to disk until their first message; existing empty logs are also omitted from listings. `GET /sessions/:id/export` returns the session as JSONL (`application/x-ndjson`): a `session` header line, then one `{"type":"message","message":…}` line per message. Session logs are restored on server start; restarting does not automatically resume interrupted turns.
- `GET /sessions/:id` returns an atomic snapshot: info, options, running state, inbox, `pendingPermissions`, latest messages, `inflight` (the current assistant draft, or null), `nextBefore`, and `revision`. `GET /sessions/:id/messages?before=<messageId>&limit=50` returns chronological items before an exclusive stable ID cursor with `nextBefore` for the next page; default limit 50, maximum 200. Unknown cursor IDs are invalid.
- `POST /sessions/:id/abort` waits for turn cleanup and clears queued input (idle abort succeeds). The aborted assistant message is kept with stop reason `aborted`; every tool call it made gets a result (tools that finished keep their real result, the rest are marked interrupted; a tool declared not cancellable is waited for, with its `tool_post` hooks, within its timeout, and keeps its result); `DELETE /sessions/:id` cancels and joins its worker, removes persisted data, and emits `session.deleted`. Prompts during abort/delete conflict; missing sessions return 404.
- `PATCH /sessions/:id` changes the session's `model`, `title` and/or `thinking` (a level name, or `auto` for the configured default); updates are persisted, and model and thinking changes affect the next run. The snapshot's `options.thinking` is the selection (null when none). `DELETE /sessions/:id/inbox/:itemId` removes one waiting input; a promoted input cannot be removed.
- `POST /sessions/:id/title` requests asynchronous title generation using `small_model` (or the session model). It uses a separate cancellable task, never overwrites an existing/manual title, and publishes `session.updated` on success.
- `POST /sessions/:id/undo` undoes the file changes of the newest reply that has some left: each file it wrote or edited goes back to how it was before that reply, unless it changed since (then it is left as is). Returns `{messageId, files: [{path, restored}]}`, 404 `nothing to undo`, or 409 while the session runs. The conversation gets a user message (`"origin":"undo"`) saying what was undone. Copies are kept beside the session log (`<session>.artifacts/undo/`) when `write` or `edit` change a file; tools declare this through `ProgressSink.backup`.
- `POST /sessions/:id/move` with `{"directory":"/absolute/path"}` changes the session's project to that directory's nearest git root (or the directory itself). Returns `{moved, location}`; the same project returns `moved:false`. Missing directories return 404, invalid/relative paths 400, active sessions 409. Persisted logs and their `.artifacts` directories move to the new location's storage; a user message with `"origin":"move"` and text `The project directory is now <location>.` records the transition. Empty, unpersisted sessions change location without adding a message.
- `GET /directories?path=<absolute-directory>` returns `{entries:[{name}]}` for subdirectories only, alphabetically sorted, including hidden names, capped at 500. Relative paths and non-directories return 400; missing paths 404.
- `GET /sessions/:id/usage` totals the session's tokens and cost: `{sessions, total: {input, output, cacheRead, cacheWrite, cost, messages, unpriced}, models: [{provider, model, totals}]}` (models most expensive first). `GET /usage?location=&since=` totals every session the server has (of one project, created since a Unix-ms time). A fork counts only what it added. Each assistant message's `usage` carries `cost` in USD when the model's price is known (catalog or config `cost`, per million tokens; not for ChatGPT sign-ins).
- `GET /event` streams server and session events via SSE.
- `POST /permissions/:id/reply` answers pending permission requests (see [permissions](permissions.md)).
- `GET /config`, `GET /models`, and `GET /registry` require exactly one query context: `location=<absolute-project>` or `session=<id>`. Config output includes redacted effective values, provenance and `diagnostics` (ignored keys, invalid plugin settings). Registry output lists `plugins` (id, layer, source), `tools` (with the providing plugin and declared permission), `providers`, transports (`apis`), `prompt_sections` and `diagnostics`: the same view a run at that location gets. `PATCH /config` requires a `target`; see [configuration](configuration.md).
- `GET /credentials` lists IDs and types; `PUT /credentials/:provider` stores an API key. `POST /server/stop` requests graceful shutdown; `zeta server stop` finds the running server without spawning one.
- `POST /registry/reload` with `{"location"?: "/abs/project"}` rebuilds plugins loaded from outside the binary for the user layer and that project (every loaded project when omitted) and returns `{"failures": [{"plugin", "message"}]}`. A plugin that fails keeps its previous version; runs already in progress keep what they started with. Load failures and warnings also stay in that scope's registry `diagnostics` until the next load. Config is read fresh for every run and needs no reload. `zeta reload` reloads for the current project without starting a server.
- `GET /auth/providers` lists named providers and login methods. An optional `location` query includes configured custom providers. OpenAI methods are `api`, `browser`, and `device`; other providers offer `api`.
- `POST /auth/:provider/start` with `{"method":"browser"}` (any of the provider's `oauth` methods; optional `location` so that project's provider plugins count) returns `{id,url,instructions}`. A provider without a sign-in flow is a 400, an unknown one a 404. The server owns the asynchronous flow and stores the tokens as the provider's credential on completion. Only one flow is active at once: starting a new one cancels a pending one, so an abandoned sign-in never blocks the next. OpenAI offers `browser` and `device`; its browser flow ignores unrelated or malformed requests to its callback port.
- `GET /auth/:provider/status?id=<id>` returns `{status:"pending"|"complete"|"error",error?}`. `DELETE /auth/:provider/flow?id=<id>` cancels the flow. These routes use the same server Basic auth; no access or refresh tokens are returned.

## Responses and errors

Session listing returns an array of `{id,location,created,title}` objects, newest first. Message listing returns `{"messages":[...],"nextBefore":"msg_…"}`; a null cursor means there are no older messages. Page items follow append order, not timestamp sorting. Config reads return `{"config":{...},"provenance":{...}}`; model reads return `{"providers":[...]}`. Successful abort, deletion, config PATCH, and server stop return `{"ok":true}`.

Errors are `{"error":"..."}`. Malformed requests and invalid cursors/limits return 400, failed authentication 401, missing sessions 404, and admission during abort/deletion 409. Permission replies return 404 when the request is no longer pending.
`GET /models` returns models only for providers with effective saved/configured/
environment credentials or an explicitly configured endpoint. This is the same
scoped list of available models; secrets are never included.

## Reconnection and recovery

Subscribe to SSE **before** fetching a snapshot and wait for `server.connected`. Buffer session events while fetching. For the hydrated session only, discard buffered events through its snapshot's `revision` and apply later events. Each other session needs its own snapshot and watermark. After a dropped/overflowed feed, subscribe and snapshot again; sequence numbers do not provide event replay and restart with a new server.

Session logs also record what the model was told: before a run's first request, a `{"type":"system","hash","prompt","tools","timestamp"}` line holds the full system prompt and tool declarations, written again only when they change, and each assistant message carries that entry's `systemHash`. Logs recover complete JSONL records before an incomplete final line; corrupt/unsupported logs are skipped with diagnostics, and orphaned tool calls are recorded as interrupted rather than replayed.

Assistant messages have an optional `completedAt` in milliseconds on the same clock as their start `timestamp`, set when logged and emitted as `message.end` (including error, aborted, length, and retried replies); in-flight drafts and older logs omit it.

`inflight` includes the assistant prefix through the snapshot revision. Apply newer `message.part.delta` events to that draft, then replace it with the complete `message.end` message. `session.inbox.updated` carries `data.inbox` as a full replacement array of `{id,text,delivery,images}`. `permission.resolved` removes its request from pending permissions. `session.updated` carries `data.session` metadata, `data.model` and `data.thinking`. Tool progress updates are transient; durable tool calls/results remain in message history. `compaction.start`, `compaction.end` and `compaction.failed` report a compaction; its summary is a user message with `"origin":"compaction"`, `firstKeptId` and `tokensBefore`, and inbox items have `kind` `prompt` or `compact`. `prompt.blocked` (`{inboxId, reason}`) means a hook refused a prompt: it left the inbox and never joined the conversation. User messages with `"origin":"hook"` were added by a hook (context, or a stop continuation) rather than typed by the user. `message.retry` announces that a draft's request failed and will be sent again after `delayMs`. If the draft had streamed nothing it continues; otherwise it ends with an error `message.end` and the retry starts a new assistant message (see providers). A draft the model rejected as too long for its context ends with `message.cancelled`; a compaction with reason `overflow` follows, then a new draft.

`session.moved` updates the hydrated session's `info.location` to `data.location`; persisted moves also publish `message.start` and `message.end` for the note.

## Events

Every SSE frame is `{seq,type,time,data,session?,location?}`; the names are defined in `proto.event.types`.

| Type | `data` |
|---|---|
| `server.connected`, `server.heartbeat` | `{}` |
| `session.created` | `{session}` |
| `session.updated` | `{session, model, thinking}` |
| `session.moved` | `{location}` |
| `session.deleted`, `session.idle` | `{}` |
| `session.error` | `{error, dropped?}` |
| `session.inbox.updated` | `{inbox}` |
| `prompt.blocked` | `{inboxId, reason}` |
| `agent.start`, `agent.end`, `turn.start` | `{}` |
| `turn.end` | `{messageId}` |
| `message.start`, `message.end` | `{message}` |
| `message.part.delta` | `{messageId, index, kind, delta}` |
| `message.cancelled` | `{messageId}` |
| `message.retry` | `{messageId, attempt, maxAttempts, delayMs, errorMessage}` |
| `tool.execution.start` | `{toolCallId, toolName, args}` |
| `tool.execution.update` | `{toolCallId, toolName, args, partialResult}` |
| `tool.execution.end` | `{toolCallId, toolName, result, isError}` |
| `compaction.start` | `{reason}` |
| `compaction.end` | `{reason, messageId, tokensBefore}` |
| `compaction.failed` | `{reason, error}` |
| `permission.asked` | `{id, action, pattern, toolCallId, timeoutMs, expiresAt}` |
| `permission.resolved` | `{id, reply}` |

Every `tool.execution.start` is followed by exactly one `tool.execution.end`, and every `agent.start` by one `agent.end`.

Tool-result messages can include `changes`, an array of bounded `{path,before,after,truncated}` previews for inline diffs. These previews remain available after reconnect and restart; truncated previews are not a complete file comparison.
