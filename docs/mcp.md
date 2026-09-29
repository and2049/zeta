# MCP servers

zeta is a Model Context Protocol client. The tools of the MCP servers you configure become ordinary tools: the model sees them, permission rules and hooks apply to them, and `GET /registry` lists them.

## Configuration

Servers live under `mcp` in `zeta.jsonc`, at user or project level (the layers merge like the rest of the config, with provenance in `GET /config`):

```jsonc
{
  "mcp": {
    "timeout": 30000,          // connecting and listing tools, in ms (default 30000)
    "servers": {
      "git": {
        "type": "local",
        "command": ["uvx", "mcp-server-git"],
        "cwd": "tools",          // optional; relative to the project
        "environment": { "GIT_TOKEN": "{env:GIT_TOKEN}" }
      },
      "docs": {
        "type": "remote",
        "url": "https://docs.example.com/mcp",
        "headers": { "Authorization": "Bearer {env:DOCS_TOKEN}" },
        "timeout": 60000        // this server's tool calls, in ms
      },
      "old": { "type": "local", "command": ["old-server"], "disabled": true }
    }
  }
}
```

- `local` servers run as child processes speaking MCP over stdin/stdout (one JSON message per line). They start in the project directory (or `cwd`), with the server's environment plus `environment`. stderr is kept for error reports.
- `remote` servers use Streamable HTTP: each message is a POST to `url`, answered with JSON or an event stream; a session id the server hands out is sent back, and the session is ended when the server is stopped. `headers` are sent with every request. There is no standalone event stream and no legacy HTTP+SSE transport. A remote server can also sign in with OAuth (below).
- `{env:VAR}` and `{file:path}` work in every string. `GET /config` shows `headers` and `environment` values as `[REDACTED]`.
- A server's `timeout` bounds its tool calls; without it they use `tool_timeout_ms`. `disabled` keeps an entry without starting it.
- `disabled_tools` lists tools of the server not to offer, by the server's own tool names, with `*` and `?` wildcards (e.g. `["delete_*"]`).
- `"instructions": false` leaves out the instructions the server hands out (see below).
- `"deferred": true` (or `mcp.deferred` for every server) keeps the server's tools out of the tool list (see [Deferred tools](#deferred-tools)).
- An entry that does not fit (no command, a non-http URL, an unknown type) is skipped and reported in the registry's `diagnostics`.

## Signing in

A remote server that answers `401` needs a sign-in: its status is `needs_auth` and nothing opens by itself. Run `zeta mcp auth <server>` in the project (or `POST /mcp/<server>/auth`): zeta finds the authorization server from the server's protected-resource metadata (or uses the server's own origin when it publishes none), checks that the authorization server's metadata names the same issuer, registers itself as a client there unless `oauth.client_id` is set, and prints the sign-in URL (opening it in the browser when it can). The browser returns to a listener on `127.0.0.1`; the tokens are stored as `mcp:<server>` (see [credentials](credentials.md) for names that need escaping) in the credential store for that server's URL only, and the server connects. Requests then carry the access token; it is refreshed a minute before it expires, or once when the server refuses it. When it is refused and cannot be refreshed, the server is `needs_auth` again and its tools go.

A sign-in is refused when the server or the authorization server is plain HTTP (except on this machine), when the protected-resource metadata names a resource that does not cover the server's URL (another host, port, scheme or path), and when the authorization server does not advertise PKCE (`S256`) in its metadata, as the protocol requires. `zeta mcp logout <server>` forgets the sign-in, and `zeta mcp` lists the servers.

```jsonc
"docs": {
  "type": "remote",
  "url": "https://docs.example.com/mcp",
  "oauth": { "client_id": "…", "client_secret": "…", "scope": "read", "callback_port": 8912 }
}
```

All `oauth` fields are optional; a `client_secret` is sent as HTTP Basic unless the authorization server only lists `client_secret_post`; `"oauth": false` turns sign-ins off, and a server with its own `Authorization` header never uses one. Set `callback_port` when the client registered with the authorization server allows only a fixed redirect (`http://127.0.0.1:<port>/callback`). A sign-in waits ten minutes; starting another one cancels it.

## Connecting

A project's servers start the first time the project is used (a run, `GET /registry`, `GET /mcp`), all at once and in the background, one set of processes per project. Each is `pending`, then `connected`, `failed`, `needs_auth` or `disabled`. A run waits for servers still connecting, up to the startup `timeout`, then uses the tools of those that are connected; a server that connects later is available to the next run.

zeta asks for protocol version `2025-11-25`, lists every page of `tools/list` (and of `prompts/list` when the server has prompts), and registers each tool and prompt. Servers may ask for `ping`, for `roots/list`, which answers with the project directory as a `file://` URI, and for `elicitation/create` (see [Questions](#questions)); other requests from a server are refused. When a server sends `notifications/tools/list_changed` or `notifications/prompts/list_changed`, its tools and prompts are listed and registered again for later runs.

Instructions a server gives in its `initialize` answer join the system prompt of runs that have its tools (none when all of them are disabled), cut to 2 KB, under a line naming the server. A server that does not declare tools is not asked for them.

A server that exits or fails is `failed`, with the reason (and the end of its stderr) in its status; its tools disappear until it is connected again. `zeta reload` (or `POST /registry/reload`) restarts every server of the project; `POST /mcp/<name>/connect` restarts one.

## Tools

- Names are `mcp__<server>__<tool>`, with characters outside `A-Z a-z 0-9 _ -` turned into `_` and cut to 64 bytes; two tools of one server that end up alike get `_2`, `_3`… Hook matchers can select them with wildcards, e.g. `mcp__git__*`.
- The plugin is `mcp:<server>` in the project layer; its tools replace built-ins of the same name like any project plugin.
- The model sees the tool's own description and input schema. zeta only checks that the arguments are an object and leaves the schema to the server, since a schema may use keywords (`$ref`, `patternProperties`…) zeta does not know.
- Permission rules see the tool name as the action with pattern `*`, e.g. `{"action": "mcp__git__*", "pattern": "*", "effect": "ask"}`.
- A result's text parts are joined with newlines; embedded resources contribute their text, and images, audio and links appear as short placeholders such as `[image image/png]`. A result with no content but `structuredContent` shows that JSON. `isError` makes it an error result. A missed deadline or an abort sends `notifications/cancelled`.
- A tool annotated `readOnlyHint: true` counts as reading only; any other tool as changing anything (the tool's side effect in `GET /registry` and `zeta_inspect`).

## Deferred tools

A server with many tools costs tokens on every request, since each tool's schema is sent. For a `deferred` server, the model is offered two tools instead: `mcp_search` takes `{query, limit?}` and returns the best matching tools of the project's deferred servers (by words in their names, then descriptions; five by default, at most twenty) with their input schemas, and `mcp_call` takes `{name, arguments}` and runs one. The tool list stays the same as servers connect and go, which keeps that part of the provider's prompt cache (server instructions still come and go with their servers). The search covers the tools the current run can call, so a server that connects during a run is searchable from the next one. A call through `mcp_call` is checked, hooked and permitted exactly as a direct call of that tool would be: permission rules and hook matchers see `mcp__<server>__<tool>`.

## Questions

zeta declares form elicitation: a server can ask the user for input during a call (`elicitation/create` with a message and a JSON Schema of simple properties). The question goes to clients as `elicitation.requested` `{id, session, source, message, schema, expiresAt}` for the project (`source` is `mcp:<server>`). A question asked while exactly one tool call is running on that server belongs to that call: `session` is the call's session (the event carries it too), it waits at most until the call's deadline, and it is withdrawn when the call ends; otherwise `session` is null and it waits for the server's `timeout` (120 s by default). A server's `notifications/cancelled` for it withdraws it too, with no reply sent; `GET /elicitations?location=` lists the open ones, and `POST /elicitations/:id/reply` with `{"action": "accept", "content": {…}}` (checked against the schema, including the string formats `email`, `uri`, `date` and `date-time`: a misfit is `400` and the question stays open), `{"action": "decline"}` or `{"action": "cancel"}` answers; `elicitation.resolved` `{id, action}` follows, with `cancel` for a withdrawn question. With no client connected, when the last one leaves, or when its time runs out, the answer is `decline`. `zeta run` declines its own session's questions, saying so on stderr; after a reconnect it declines what its session has open. Questions of other sessions, and those with no session, are left to clients that can answer. A request in another mode (`url`) gets JSON-RPC error `-32602`.

## Prompts

A server's prompts become slash commands named `<server>:<prompt>` (whitespace and `/` in either name, and `:` in the server's, become `_`, and `_2`, `_3`… tell apart servers, in config order, and prompts that end up alike), listed in `GET /commands` with the prompt's arguments as the hint (`<required> [optional]`). The words typed after the command fill the arguments in the order the prompt declares them, quotes group words, the last argument takes the rest of the text as typed, and missing ones are empty. The prompt's messages, joined by blank lines, become the session's prompt; an error from the server is shown to the user. A server whose prompts cannot be listed keeps its tools. MCP resources are not used.

## Status

`GET /mcp?location=/abs/project` (or `?session=<id>`) returns `{"servers": [{"name", "status", "tools", "error", "signIn"}]}` (`signIn`: the latest sign-in for that server, `{id, state}` with state `running`, `done` or `failed`, else null); `GET /registry` includes the same list under `mcp`.
