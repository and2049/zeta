# Extensions

An extension is a program, in any language, that zeta starts and talks to over its stdin and stdout. It can add tools, slash commands, hooks and model providers, which zeta registers like its own. A crash only takes that extension down. This page is the whole protocol; `examples/extensions/hello/` is a complete extension using only the Python standard library.

## Where extensions come from

- A directory with a `zeta.json` manifest inside an `extensions/` directory:
  `{"name": "hello", "command": ["python3", "hello.py"], "description": "…"}`. The command runs in that directory.
- An executable file directly inside an `extensions/` directory. Its file name is its name.
- An entry in the `extensions` config list: `{"extensions": [{"command": ["/path/to/ext", "--flag"], "env": {"KEY": "{env:KEY}"}}]}`. Its name is the one it registers.

`extensions/` is read from `~/.agents/` and the zeta config directory (user extensions) and from `<project>/.agents/` and `<project>/.zeta/` (project extensions). A user extension runs once per server, and each request tells it which project it is for; a project extension (and a config entry) runs once per project, started when the project is first used. The name an extension registers must match its file or manifest name. It is the plugin id: its tools, commands, hooks and providers belong to that plugin, whose settings under `plugin.<name>` in `zeta.jsonc` it receives. There is no trust prompt for project extensions.

After changing an extension, run `zeta reload` (or `POST /registry/reload`): it stops the extensions and starts them again. `POST /extensions/<name>/restart` restarts one.

## Framing

Every message is one JSON object on one line (`\n`-terminated), both ways. stdout carries only protocol messages; write logs to stderr, which zeta keeps in `$XDG_STATE_HOME/zeta/extensions/<name>.log` (emptied on each start; a `--standalone` server keeps them in its private directory, removed when it stops). A line that is not a JSON object is a protocol error and stops the extension. Lines are limited to 16 MiB.

## Lifecycle

1. zeta starts the program. Its first message must be `register`, within 10 seconds.
2. zeta registers what it declared and answers `ready`.
3. zeta sends `request`s and the extension answers each with a `response`; the extension may send `call`s to zeta, answered with `result`.
4. zeta sends `ping` every 10 seconds; answer `pong`. No message for 30 seconds counts as dead.
5. On shutdown zeta sends `shutdown` and closes stdin; after a second the process is killed.

zeta never lets a stuck extension hold it up: pings and the shutdown message are skipped when the extension is not reading its stdin, and a silent extension is killed, which also ends any write waiting on it. An extension that exits, stops answering, breaks the protocol or fails to register is `failed`: its registrations are removed until it is restarted or reloaded. `GET /extensions?location=<project>` lists extensions with `{name, scope, status, source, error}`; status is `starting`, `running` or `failed`.

## register

```json
{"type": "register", "name": "hello",
 "tools": [{"name": "word_count", "description": "Count words in a text",
            "parameters": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]},
            "permission": {"target": "none"}, "sideEffect": "none", "timeoutMs": 10000, "sequential": false}],
 "commands": [{"name": "summarize", "description": "Summarize a file", "argumentHint": "<path>"}],
 "hooks": ["tool_pre", "prompt_submit"],
 "providers": [{"id": "echo", "name": "Echo", "models": [{"id": "echo-1", "name": "Echo 1", "context": 8192, "images": false}], "env": ["ECHO_API_KEY"]}]}
```

All lists are optional.

- **tools**: `parameters` is the JSON Schema of the arguments; zeta checks the keywords it supports and the extension checks the rest. `permission` says what permission rules see: `{"action"?: "…", "target": "none" | "path" | "command" | "url" | "value", "arg": "<argument name>"}` (see [permissions](permissions.md)); without it the action is the tool name and the pattern `*`. `sideEffect` is `none`, `read`, `workspace` (default), `network` or `system`. `timeoutMs` overrides the tool timeout; `sequential: true` keeps the tool out of parallel batches; `cancellable: false` makes an abort wait for the call and its `tool_post` hooks to finish (within its timeout) and keep the hooked result, instead of cancelling it.
- **commands**: slash commands. Running one asks the extension for the prompt text (see `command` below). Reserved command names (`new`, `model`, `reload`, …) are refused.
- **hooks**: hook points to receive: `session_start`, `prompt_submit`, `tool_pre`, `permission`, `tool_post`, `turn_stop` (see [tools](tools.md#hook-points)). They run in plugin load order with the other hooks.
- **providers**: model providers, used as `<id>/<model>` in `model`. zeta resolves the API key like for built-in providers (`provider.<id>.options.apiKey`, a key saved with `zeta auth login <id>`, then the `env` variables) and a `baseURL` from config, and passes both with each request. `images: true` lets a model take image input; `reasoning: true` makes it take a thinking level (config's `thinkingLevels`, `thinking` and `reasoning` for the model apply too).

zeta answers:

```json
{"type": "ready", "location": "/home/me/project", "options": {"level": 2}}
```

`location` is the project for a project extension and `null` for a user extension; `options` is `plugin.<name>` from the config (for a user extension, from the user config).

## Requests

```json
{"type": "request", "id": "7", "method": "tool", "params": {…}}
```

Answer with `{"type": "response", "id": "7", "result": {…}}`, or `{"type": "response", "id": "7", "error": "what went wrong"}`. Requests may overlap; answer each once, in any order. `{"type": "cancel", "id": "7"}` means zeta gave up on that request (a deadline or an abort); stop working on it, no answer is needed. Tool requests have the tool's timeout, hook and command requests 60 seconds, provider streams the tool timeout between messages.

Every request's `params` has `location`, the project it is for.

- **tool** `{"name", "arguments", "location", "session"}` → `{"text": "…", "isError"?: true}`. Before answering, the extension may send `{"type": "event", "id": "7", "event": {"progress": "partial output"}}`.
- **command** `{"name", "arguments", "location"}` (`arguments` is the text typed after the name) → `{"text": "the prompt to send"}`.
- **hook** `{"point", "location", "scope": {"session", "provider", "model"}, …}` with, per point:
  - `session_start` `{"source": "startup" | "resume"}` → `{"context"?: "text for the model"}`
  - `prompt_submit` `{"prompt": {"id", "text"}}` → `{"action": "continue"}`, `{"action": "context", "text"}` or `{"action": "block", "reason"}`
  - `tool_pre` `{"call": {"id", "name", "arguments"}}` → `{"action": "continue"}`, `{"action": "rewrite", "arguments"}` or `{"action": "block", "reason"}`
  - `permission` `{"call": {…}, "action", "pattern"}` → `{"action": "continue"}`, `{"action": "allow", "arguments"?}` or `{"action": "deny", "reason"}`
  - `tool_post` `{"call": {…}, "result": {"text", "isError"}}` → `{"action": "continue"}` or `{"action": "replace", "result": {"text", "isError"?}}`
  - `turn_stop` `{"reply": {"text"}, "continued"}` → `{"action": "stop"}` or `{"action": "continue", "text"}`

  An error answer, a timeout or a crash counts as a failing hook: `tool_pre` blocks, `permission` denies, others are skipped.
- **stream** `{"provider", "model", "system", "messages", "tools", "options": {"apiKey"?, "baseURL"?}, "location", "session", "thinking"}` asks a provider for one reply for the run in `location` (`session` can serve as a prompt-cache key; `thinking` is a thinking level or null for the service's default). `messages` are zeta's messages (`role` `user`, `assistant` or `tool_result`, `content` blocks `text`, `thinking`, `toolCall`, `image`); `tools` are `{name, description, parameters}`. Send the reply as events, then the result:
  - `{"type": "event", "id": "7", "event": {"text": "…"}}`, `{"thinking": "…"}`
  - `{"toolCall": {"index": 0, "id"?: "call_1", "name"?: "read", "arguments"?: "{\"pa"}}}`: `arguments` are pieces of the JSON text, appended per index
  - `{"usage": {"input": 10, "output": 5}}`
  - finally `{"type": "response", "id": "7", "result": {"stop": "stop" | "length" | "tool_use"}}`, or an error `{"type": "response", "id": "7", "error": "message", "retryable"?: true, "overflow"?: true}`; a retryable error before any event is retried, and `overflow` (the request is too long for the model) makes zeta compact the history and ask once more.

## Calls

The extension may ask zeta:

```json
{"type": "call", "id": "c1", "method": "log", "params": {"level": "info", "message": "hello"}}
```

zeta answers `{"type": "result", "id": "c1", "result": …}` or `{"type": "result", "id": "c1", "error": "…"}`.

- `log` `{"level": "debug" | "info" | "warn" | "error", "message"}` writes to the server log.
- `registry` `{"location"?}` returns the live listing, like `GET /registry`.
- `messages` `{"session"}` returns the latest 200 messages of that session, `{"messages": […], "nextBefore"}`, read-only.
- `credential` `{"provider"}` returns `{"apiKey": "…" | null}` for one of the extension's own providers.
