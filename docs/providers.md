# Providers and authentication

zeta supports OpenAI-compatible Chat Completions, OpenAI's ChatGPT/Codex
Responses transport and Anthropic's Messages API. A model appearing in the models.dev catalog is metadata,
not a guarantee that zeta implements that provider's API.

## Named providers

| Provider | Provider ID | Authentication | Transport |
| --- | --- | --- | --- |
| OpenAI | `openai` | API key | Chat Completions |
| OpenAI ChatGPT / Codex | `openai` | Browser OAuth or device-code OAuth | Codex Responses |
| Anthropic | `anthropic` | API key | Messages |
| DeepSeek | `deepseek` | API key | OpenAI-compatible Chat Completions |
| GLM / Z.AI (global) | `zai` | API key | OpenAI-compatible Chat Completions |
| GLM / Zhipu AI (China) | `zhipuai` | API key | OpenAI-compatible Chat Completions |
| OpenRouter | `openrouter` | API key | OpenAI-compatible Chat Completions |

The compatible providers share one adapter; this is not a claim that every
model or provider-specific feature has been live-tested. Local llama.cpp and
vLLM servers are also usable through their OpenAI-compatible endpoints.
Other compatible services can be configured with a custom provider ID and
`provider.<id>.options.baseURL`.

Each named provider is a built-in plugin with its own module that decides, for
every run, which transport serves the model and with which endpoint and
credentials; the OpenAI provider switches to Codex Responses while a ChatGPT
sign-in is its credential. A provider also declares its login methods and, for
sign-in methods, the flow that runs them. Custom IDs go to the `custom`
plugin, which needs a configured `baseURL`. `GET /registry` lists the
providers and the plugins that registered them; a provider registered in a
narrower layer replaces a built-in one with the same ID.

`GET /models` lists providers with saved OAuth/API-key credentials, a configured API
key, or a provider environment key. Explicitly configured endpoints also appear
without a key, so local servers remain usable. An empty configured API key masks
lower-precedence credentials. `GET /auth/providers` lists supported providers and their login methods.

## Anthropic

The `anthropic` provider sends `POST <baseURL>/messages` (default
`https://api.anthropic.com/v1`) with the key in `x-api-key`. The key comes
from config, a saved key, or `ANTHROPIC_API_KEY`.

- `max_tokens` is the model's output limit from the catalog, or 8192 when
  the model is unknown.
- The system prompt and the newest message carry prompt-cache breakpoints,
  so each turn reads the previous turn's prefix from the cache. Cache reads
  and writes are reported in usage.
- zeta does not request extended thinking. When a model thinks anyway, its
  signed (or redacted) thinking is replayed to the same model within the
  same run, through its tool calls, while the system prompt and tools stay
  the same. Thinking from earlier prompts, kept across a compaction, or
  made under a system prompt a hook has since changed, is left out: the API
  binds a thinking block to everything sent before it and rejects one whose
  prefix changed. A `context_build` hook that edits earlier messages can
  still make the API reject a request.

## Catalog and custom endpoints

The local models.dev cache retains metadata only for the IDs the built-in
providers claim (the six named above), and only fields zeta uses. Existing full-catalog caches are reduced
when loaded. The upstream API serves a full compressed catalog; conditional
refreshes avoid transferring it again when the saved version is unchanged.

Custom OpenAI-compatible endpoints use **config-only model definitions**. Set
their model IDs, limits, capabilities, and any pricing under
`provider.<id>.models`. zeta does not infer these from a similar model name in
models.dev: a proxy or local server may use aliases, different context limits,
disabled modalities, or different prices. A provider ID outside the supported
list does not automatically import its models.dev entry.

Endpoints come from `options.baseURL`, then the cached catalog, then the named
provider's own default (so a first run while offline still reaches Anthropic,
DeepSeek, Z.AI, Zhipu AI or OpenRouter). A custom provider without a configured
`baseURL` fails with `ProviderEndpointUnknown` rather than sending its key to
the OpenAI default endpoint.

models.dev's provider-independent [`models.json`](https://models.dev/models.json)
could supply useful defaults through an explicit mapping in the future, but
that mapping is not implemented. Config remains the source of truth for custom
endpoints.

Google Gemini, AWS Bedrock, and Azure-specific auth are not implemented, and a
custom provider ID always uses the OpenAI-compatible transport. Models served through a supported compatible gateway
use that gateway's provider ID and credentials.

## Authentication

`zeta auth login <provider>` reads an API key from a hidden prompt or stdin.
`PUT /credentials/:provider` saves an API key over HTTP; configured custom
providers are supported as well. Keys are never submitted as conversation messages.

OpenAI offers:

- **API key:** an OpenAI Platform key, using API billing and Chat Completions.
- **ChatGPT browser:** PKCE authorization with a localhost callback.
- **ChatGPT device code:** open the authorization URL and enter the code, useful
  when a localhost browser callback is unavailable.

ChatGPT authentication uses your account's Codex access. It does not turn a
ChatGPT subscription into an OpenAI Platform API key, and its available models
can differ from the API-key model catalog. Access and refresh tokens stay on
the server; API clients receive only login instructions and completion status.
Expired access tokens are refreshed before subsequent model requests.

Codex requests are not stored by OpenAI, so zeta asks for the model's
encrypted reasoning and keeps it in the session log with the reasoning block
(`thinkingSignature`). Later requests send it back, so the model keeps its
reasoning across tool calls. It is only sent to the same provider and model
that produced it; after a model switch the reasoning is left out.

## Credential precedence and storage

Explicit `provider.<id>.options.apiKey` config takes precedence over saved
credentials. Saved credentials take precedence over provider environment
variables. Remove an explicit OpenAI API-key override to use saved ChatGPT
OAuth credentials. Custom `baseURL` overrides are for API-key/compatible
endpoints; ChatGPT OAuth uses the Codex endpoint.

Credentials are saved in `$XDG_DATA_HOME/zeta/credentials.json` (normally
`~/.local/share/zeta/credentials.json`) with mode 0600. Saving a new login for
a provider replaces its previous saved credential. `zeta auth login <provider>` accepts API keys; OAuth flows are available
through `POST /auth/:provider/start` (see [protocol](protocol.md)).

## Errors and retries

A failed request is recorded on the assistant message as a short error: the
HTTP status and the API's own error message, on one line, at most 512 bytes,
with the request's API key redacted. Raw response bodies are never logged or
sent to clients. A `content_filter` or unknown finish reason is an error, not a
normal stop.

Rate limits (429, unless the quota is exhausted), server errors (500, 502,
503, 504, 529), timeouts (408), dropped connections, and streams that end early
are retried up to 3 attempts in total, waiting 1 s, then 2 s (at most 30 s),
or as long as the service's `Retry-After` asks when that is at most 30 s (a
longer ask fails at once). If nothing of the reply had arrived, the same
assistant message continues. If text had already streamed, that partial reply
is kept in the session as an error message (without any unfinished tool
calls), the request is sent again unchanged, and the new reply arrives as a
new assistant message; later requests leave the failed partial out. Each retry
publishes `message.retry` with `{messageId, attempt, maxAttempts, delayMs,
errorMessage}` for the message that failed.

## Thinking level

How much a model reasons is one scale for every provider: `off`, `minimal`,
`low`, `medium`, `high`, `xhigh`. The level for a run is the session's
selection (`zeta run --thinking <level>`, or `PATCH /sessions/:id` with
`{"thinking": "high"}`; `auto` drops it), else the model's `thinking` in
config, else the top-level `thinking` config key. Nothing chosen sends no
setting, so the service's default applies.

Only models the catalog (or a config override) marks `reasoning: true` get a
level. A model takes every level unless config lists its levels in
`thinkingLevels`; a level it does not take becomes the next one up it does,
else the next one down:

```jsonc
{
  "thinking": "medium",
  "provider": {
    "openai": { "models": { "gpt-5": { "thinkingLevels": ["minimal", "low", "medium", "high"], "thinking": "high" } } }
  }
}
```

Each transport sends it its own way: OpenAI-compatible `reasoning_effort`
(`off` is `none`), Codex `reasoning: {effort, summary: "auto"}`, Anthropic an
adaptive `thinking` with `output_config.effort` (`off` and `minimal` are `low`,
since some of these models always think; `xhigh` is `max`), or on models from
before adaptive thinking a `budget_tokens` budget (1024 to 32768, leaving 1024
tokens for the answer), where `off` disables thinking.

## Prompt caching and context overflow

Requests carry the session id as a prompt-cache key so a session's requests
share the service's cached prefix: `prompt_cache_key` for Codex, and for
OpenAI-compatible endpoints when `provider.<id>.options.setCacheKey` is true
(the default for `openai`). A forked session uses its own id. Anthropic caches
through breakpoints on the system prompt and the newest message.

An error saying the request is too long for the model's context (for example
`prompt is too long`, `context_length_exceeded`, `exceeds the context window`)
is not retried as is: the loop compacts the history and sends the request once
more (see [compaction](compaction.md)).

## Connections

Each built-in transport (OpenAI-compatible, Codex, Anthropic) keeps its
connections open between requests and shares them across sessions. A
connection is reused only when the previous reply ended cleanly within 100 ms
of its last event; an endpoint that keeps finished streams open gets a fresh
connection per request instead. Connections idle for 30 s are dropped, and
the client (with its certificate list) is replaced at least hourly. When a
reused connection turns out to be closed (the request could not be written,
or the connection closed before any byte of the reply), the request is sent
once more on a new connection, without counting as a retry.
