//! Built-in providers, one module each: OpenAI (API key or ChatGPT sign-in),
//! Anthropic (Messages API) and the OpenAI-compatible DeepSeek, Z.AI, Zhipu
//! AI and OpenRouter, plus
//! the config-only fallback (`*`, plugin `custom`) for any other id. Each is
//! its own plugin; a provider from a narrower layer replaces one by id.
const std = @import("std");
const plugin = @import("plugin");
const shared = @import("shared.zig");
const compatible = @import("compatible.zig");

pub const Context = shared.Context;
pub const Spec = shared.Spec;

const openai = @import("openai.zig");
const specs = [_]Spec{
    @import("anthropic.zig").spec,
    @import("deepseek.zig").spec,
    @import("zai.zig").spec,
    @import("zhipuai.zig").spec,
    @import("openrouter.zig").spec,
};

/// The catalog ids the built-in providers read models.dev metadata for.
pub const catalog_ids = blk: {
    var ids: [specs.len + 1][]const u8 = undefined;
    ids[0] = openai.spec.id;
    for (specs, ids[1..]) |s, *id| id.* = s.id;
    const out = ids;
    break :blk &out;
};

/// `ctx` must outlive the registry.
pub fn register(ctx: *Context, r: *plugin.Registry) !void {
    try r.addProvider(try r.addPlugin(.{ .id = openai.spec.id }), openai.provider(ctx));
    inline for (specs) |s| try r.addProvider(try r.addPlugin(.{ .id = s.id }), compatible.provider(s, ctx));
    try r.addProvider(try r.addPlugin(.{ .id = "custom" }), @import("custom.zig").provider(ctx));
}

test {
    _ = @import("root_test.zig");
    _ = @import("access.zig");
    _ = @import("codex_models.zig");
    _ = openai;
}
