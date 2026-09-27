//! The `provider` capability: turns a request into a stream of normalized
//! events. Providers only emit deltas; the agent loop
//! assembles them into an assistant message.

const std = @import("std");
const proto = @import("proto");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const ToolDecl = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const u8,
};

pub const Request = struct {
    model: []const u8,
    /// The project the run is for.
    location: []const u8 = "",
    /// The session the run is for; transports that support it send it as
    /// a prompt-cache key.
    session_id: ?[]const u8 = null,
    /// Hash of `system` and `tools` as assistant messages log it
    /// (`systemHash`): replies with another hash were produced under a
    /// different prompt.
    system_hash: ?[]const u8 = null,
    /// How much the model should reason, already fitted to the model; null
    /// sends no setting (the service's default).
    thinking: ?proto.thinking.Level = null,
    system: []const u8,
    messages: []const proto.Message,
    tools: []const ToolDecl = &.{},
};

pub const Event = union(enum) {
    text_delta: []const u8,
    thinking_delta: []const u8,
    /// Opaque data completing the current reasoning block, replayed to the
    /// same provider and model only. Opens an empty block if none is open.
    thinking_signature: []const u8,
    /// A tool call begins. `index` is the provider's slot for later deltas.
    /// May repeat for the same index: empty `id`/`name` are filled in by a
    /// later start, non-empty ones are kept.
    tool_call_start: struct { index: u32, id: []const u8, name: []const u8 },
    /// Arguments for `index`. A delta before any start opens the call with
    /// an empty identity.
    tool_call_delta: struct { index: u32, arguments: []const u8 },
    usage: proto.message.Usage,
    done: proto.message.StopReason,
    /// Detail for an error the provider is about to return. Recorded as the
    /// message's `errorMessage` and shown to clients.
    failure: Failure,
};

pub const Failure = struct {
    /// Short and sanitized: never a raw response body or a credential.
    message: []const u8,
    /// The same request may succeed later (network drop, 429, 5xx). The loop
    /// retries only while nothing of the reply has streamed yet.
    retryable: bool = false,
    /// Delay the service asked for (Retry-After), in milliseconds.
    retry_after_ms: ?u64 = null,
    /// HTTP status, when the failure came from one.
    status: ?u16 = null,
    /// The request did not fit the model's context window. Never retryable
    /// as is; the loop compacts and tries once more.
    overflow: bool = false,
};

/// Receives events. Slices are only valid during the call.
pub const Sink = struct {
    ctx: *anyopaque,
    onEvent: *const fn (ctx: *anyopaque, event: Event) anyerror!void,

    pub fn emit(s: Sink, event: Event) !void {
        return s.onEvent(s.ctx, event);
    }
};

/// Per-provider settings from config (`provider.<id>.options`), already
/// resolved (env/file substitution done).
pub const Options = struct {
    baseURL: ?[]const u8 = null,
    apiKey: ?[]const u8 = null,
    /// Optional account identifier supplied by provider authentication.
    account_id: ?[]const u8 = null,
    authentication: ?Authentication = null,
    /// Capability resolved from catalog/config; unknown models are text-only.
    accepts_images: bool = false,
    /// The model's context window in tokens; 0 when unknown (no automatic
    /// compaction).
    context_window: u64 = 0,
    /// The model's output limit in tokens; 0 when unknown (the transport
    /// picks its own default where the API needs one).
    max_output: u64 = 0,
    /// Ask the transport to send `Request.session_id` as a prompt-cache key.
    cache_key: bool = false,
    /// The model reasons (catalog `reasoning`); only then is a thinking
    /// level sent.
    reasoning: bool = false,
    /// Levels the model takes; null takes every level.
    thinking_levels: ?proto.thinking.Set = null,
    /// The model's configured default level, below a session's selection.
    thinking: ?proto.thinking.Level = null,
    /// USD per million tokens, from the catalog or config; null when
    /// unknown or not billed per token (a subscription).
    price: ?proto.message.Price = null,
};

pub const Credentials = struct {
    apiKey: []const u8,
    account_id: ?[]const u8 = null,
};

/// Resolved per HTTP request, so expiring OAuth credentials can refresh.
pub const Authentication = struct {
    ctx: ?*anyopaque,
    resolve: *const fn (?*anyopaque, Allocator, Io) anyerror!Credentials,
};

/// A login method offered for a provider, e.g. an API key or a browser sign-in.
pub const AuthMethod = struct {
    id: []const u8,
    label: []const u8,
    /// Kind of credential it stores: "api" or "oauth".
    type: []const u8,
};

/// Tokens a sign-in produced; the host stores them as the provider's
/// credential. Strings live in the arena given to `Login.finish`.
pub const Tokens = struct {
    access: []const u8,
    refresh: []const u8,
    /// Unix milliseconds.
    expires: i64,
    account_id: ?[]const u8 = null,
};

/// A sign-in that has started: what to show the user, and the flow's state.
pub const Started = struct {
    url: []const u8,
    instructions: []const u8,
    state: *anyopaque,
};

/// Interactive sign-in for the provider's `oauth` methods. The host runs one
/// flow at a time: `start`, then `finish` on a cancelable task, then `close`
/// whatever the outcome.
pub const Login = struct {
    ctx: ?*anyopaque = null,
    /// Begins `method` (an `AuthMethod.id`). The state and returned strings
    /// live in `arena` until `close`.
    start: *const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, method: []const u8) anyerror!Started,
    /// Waits for the user to finish; returns `error.Canceled` if canceled.
    finish: *const fn (ctx: ?*anyopaque, state: *anyopaque, arena: Allocator, io: Io) anyerror!Tokens,
    /// Releases what the flow holds (listeners, sockets).
    close: *const fn (ctx: ?*anyopaque, state: *anyopaque, io: Io) void,
};

/// One `provider.<id>` entry from config, already substituted.
pub const Configured = struct {
    id: []const u8,
    baseURL: ?[]const u8 = null,
    apiKey: ?[]const u8 = null,
    /// `setCacheKey`: send the session id as a prompt-cache key.
    setCacheKey: ?bool = null,
    /// Raw `models` overrides: model id -> model fields.
    models: std.json.Value = .null,
};

/// A model reference and what config says about providers.
pub const Query = struct {
    provider: []const u8,
    model: []const u8,
    /// Every configured provider, in config order.
    configured: []const Configured = &.{},
    /// `plugin.<id>` config of the plugin that registered this provider.
    plugin_options: std.json.Value = .null,

    /// Config for `id`; empty when it has none.
    pub fn options(q: Query, id: []const u8) Configured {
        for (q.configured) |c| if (std.mem.eql(u8, c.id, id)) return c;
        return .{ .id = id };
    }
};

/// The transport to use for a model and its per-request options.
pub const Route = struct {
    api: []const u8,
    options: Options,
};

/// A provider as named in model references (`<id>/<model>`). It decides
/// which transport serves a model, with which endpoint and credentials, and
/// what its model picker lists.
pub const Provider = struct {
    /// `*` handles every id no other registration claims.
    id: []const u8,
    name: []const u8,
    auth_methods: []const AuthMethod = &.{},
    /// Required when any auth method has type "oauth".
    login: ?Login = null,
    ctx: ?*anyopaque = null,
    /// Must not use the network: image admission calls it under a lock.
    /// Returned data lives in `arena`.
    resolve: *const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, query: Query) anyerror!Route,
    /// Picker entries (`{id, name, baseURL, models}`), usually none or one;
    /// `*` lists every provider it serves. `query.model` is empty.
    models: ?*const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, query: Query) anyerror![]const std.json.Value = null,
};

/// A transport ("api") for model requests.
/// Stateless: config comes in with each call.
pub const Api = struct {
    id: []const u8,
    ctx: ?*anyopaque = null,
    /// Streams one response. Must emit `done` last on success. Returns
    /// `error.Canceled` if the task is canceled mid-stream. `arena` lives for
    /// the attempt.
    stream: *const fn (ctx: ?*anyopaque, arena: Allocator, io: Io, options: Options, request: Request, sink: Sink) anyerror!void,
};
