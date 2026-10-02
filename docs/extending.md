# Extending zeta

How to add a capability to zeta, or change how it behaves, and check that the change took. Read [concepts](concepts.md) first for the terms used here.

## Ground rules

- Change zeta through files: config, `AGENTS.md`, skills, prompt templates, `hooks.json`, MCP servers and extensions. Never edit zeta's source or replace its binary.
- Prefer the smallest mechanism that does the job: a line in `AGENTS.md` before a skill, a skill before a hook, a hook before an extension.
- Put a change in the project layer (`<project>/.zeta/`) when it only matters to that project, and in the user layer (`~/.config/zeta/`) when it should follow the user everywhere. Ask the user when it isn't clear.
- Look before writing: check the live state (below) for a plugin, tool, command or setting that already does it, or that the change would replace.
- Never put a secret in a file. Use `{env:VAR}` or `{file:path}` in config, and `zeta auth login <provider>` for provider keys.

## Pick a mechanism

| The user wants… | Use | Page |
|---|---|---|
| zeta to always follow a rule ("run `zig fmt` before committing") | a line in `AGENTS.md` | [skills](skills.md#instructions) |
| knowledge or a procedure the model loads only when relevant | a skill | [skills](skills.md) |
| a reusable prompt behind `/name` | a prompt template | [prompt templates](commands.md) |
| a different model, provider endpoint, timeout or other setting | `zeta.jsonc` | [configuration](configuration.md) |
| some tool calls allowed, asked about or refused | a `tool_pre` hook: the example permissions extension, or a command hook | [permissions](permissions.md) |
| a shell command run when a session starts, a prompt is sent, around tool calls, or when the agent stops | a command hook | [command hooks](hooks.md) |
| tools from an existing MCP server | `mcp` in `zeta.jsonc` | [MCP servers](mcp.md) |
| a new tool, a command computed by code, a hook with logic, or a model provider zeta has no built-in support for | an extension | [extensions](extensions.md) |
| a model on an OpenAI-compatible endpoint | `provider.<id>` in config, not an extension | [providers](providers.md) |

An extension is the only way to run new code inside zeta's plugin registry. It can be written in any language that reads and writes lines on stdin and stdout.

## Look at the live state

With `"inspect_tool": true` in config, the model has `zeta_inspect`: call it with no arguments for a summary, then with a `section` (`plugins`, `tools`, `hooks`, `providers`, `commands`, `config`, `diagnostics`).

Without it, ask the server directly. The discovery file holds its URL and password:

```sh
d="${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/zeta}"; d="${d:-${XDG_STATE_HOME:-$HOME/.local/state}/zeta}/server.json"
url=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["url"])' "$d")
pw=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["password"])' "$d")
curl -su "zeta:$pw" "$url/registry?location=$PWD"     # plugins, tools, hooks, providers, skills, diagnostics
curl -su "zeta:$pw" "$url/config?location=$PWD"       # effective config and which layer set each value
curl -su "zeta:$pw" "$url/extensions?location=$PWD"   # extension status and errors
```

(On macOS there is no `$XDG_RUNTIME_DIR`; the file is under the state directory.) `location` is any absolute directory in the project; the server uses its git root. `prompt_sections` in the registry names the parts of the system prompt, including each `AGENTS.md` file. On the command line, `zeta reload` reports plugins that failed to load (and exits 1), and `zeta mcp` lists MCP servers.

## The loop

1. Write or edit the file.
2. If it is a `hooks.json`, an MCP server or an extension, run `zeta reload` (or `POST /registry/reload`); it exits 1 and names any plugin that failed to load. Everything else is read on the next run.
3. Check that it loaded: the registry lists the new plugin, tool, hook or command, and `diagnostics` is empty. A plugin that fails to reload keeps its previous version and reports why in `diagnostics`; an extension reports `failed` with an `error`.
4. Try it: `zeta run "use word_count on 'a b c'"`, or the slash command in the terminal client. `zeta run` exits 1 when the run fails or a tool is denied.
5. If something is wrong, read the logs ([troubleshooting](troubleshooting.md)).

A run already in progress keeps the plugins it started with, so the change shows from the next run on.

## Writing an extension

The [extension protocol](extensions.md) is the reference; `examples/extensions/hello/` beside these pages is a complete extension with a tool, a command, a hook and a provider. The smallest useful one, a single tool in Python:

```python
#!/usr/bin/env python3
import json, sys, threading

lock = threading.Lock()

def send(message):
    with lock:  # requests run in threads; keep each line whole
        sys.stdout.write(json.dumps(message) + "\n")
        sys.stdout.flush()

def handle(request):
    params = request["params"]
    if request["method"] == "tool" and params["name"] == "line_count":
        text = params["arguments"]["text"]
        send({"type": "response", "id": request["id"], "result": {"text": str(len(text.splitlines()))}})
    else:
        send({"type": "response", "id": request["id"], "error": "unknown request"})

send({"type": "register", "name": "lines", "tools": [{
    "name": "line_count",
    "description": "Count the lines in a text.",
    "parameters": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]},
    "sideEffect": "none",
}]})
for line in sys.stdin:
    message = json.loads(line)
    if message["type"] == "ping":
        send({"type": "pong"})
    elif message["type"] == "request":
        threading.Thread(target=handle, args=(message,), daemon=True).start()
    elif message["type"] == "shutdown":
        break
```

Save it as `.zeta/extensions/lines/lines.py` with `.zeta/extensions/lines/zeta.json`:

```json
{"name": "lines", "command": ["python3", "lines.py"], "description": "Counts lines"}
```

then `zeta reload`. The name in `register` must equal the manifest's `name` (or, for a bare executable in `extensions/`, its file name).

Things that break extensions:

- **Anything else on stdout.** A stray `print` is a protocol error and stops the extension. Log to stderr, or send a `log` call.
- **Not flushing.** zeta waits for whole lines; buffered output looks like a hang. Flush after every message.
- **Blocking the read loop.** zeta pings every 10 seconds and treats 30 seconds of silence as dead. Handle requests on threads (or asynchronously) so the loop keeps reading and answering pings, and guard stdout with a lock.
- **Registering slowly.** `register` must arrive within 10 seconds of starting. Do slow setup after `ready`.
- **Answering twice or never.** Answer every request exactly once, in any order. After a `cancel`, no answer is needed.
- **Names.** Tool names must not collide with a narrower layer's tools unless replacing them is the point; command names cannot be ones the terminal client uses itself.

Before reloading, the extension can be tried by hand: run its command in its directory; it should print one `register` line. Type `{"type":"ready","location":null,"options":{}}` and then a request such as `{"type":"request","id":"1","method":"tool","params":{"name":"line_count","arguments":{"text":"a\nb"},"location":"/tmp","session":"x"}}` to see its answer.

Settings for an extension go under `plugin.<name>` in `zeta.jsonc` and arrive in `ready` as `options`. Logs are in `$XDG_STATE_HOME/zeta/extensions/<name>.log`.

## Recipes

- **Block a dangerous command** without code: a `PreToolUse` hook on `bash` that exits 2 with a reason on stderr ([command hooks](hooks.md)), or a rule in the example permissions extension ([permissions](permissions.md)).
- **Add project context at the start of every session:** a line in the project's `AGENTS.md`; for context computed at the time, a `SessionStart` hook printing `{"additionalContext": "…"}`.
- **A `/review` command:** `.zeta/prompts/review.md` with `$1` for the path ([prompt templates](commands.md)).
- **A team procedure the model should follow when relevant:** `.zeta/skills/<name>/SKILL.md` with a description that says when to use it ([skills](skills.md)).
- **A local model server:** `provider.local.options.baseURL` plus its models under `provider.local.models` ([providers](providers.md)).
- **A provider with its own API:** an extension that registers a provider and answers `stream` requests ([extensions](extensions.md#requests)); the hello example's `echo` provider shows the event sequence.
