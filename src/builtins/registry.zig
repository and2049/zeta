//! Shared built-in registration for the runtime and generated reference docs.
//! Each built-in module is its own plugin in the built-in layer.
const std = @import("std");
const plugin = @import("plugin");
const tool_inspect = @import("tool_inspect.zig");
const http_pool = @import("http_pool.zig");
const provider_openai = @import("provider_openai/root.zig");
const provider_codex = @import("provider_codex/root.zig");
const provider_anthropic = @import("provider_anthropic/root.zig");

/// One HTTP pool per built-in transport, shared by every session.
pub const Transports = struct {
    openai: http_pool.Pool,
    codex: http_pool.Pool,
    anthropic: http_pool.Pool,

    /// `gpa` must be thread-safe.
    pub fn init(gpa: std.mem.Allocator, io: std.Io) Transports {
        return .{ .openai = .init(gpa, io), .codex = .init(gpa, io), .anthropic = .init(gpa, io) };
    }

    /// After every run has ended.
    pub fn deinit(t: *Transports) void {
        t.openai.deinit();
        t.codex.deinit();
        t.anthropic.deinit();
    }
};

/// `inspector` and `transports` must outlive the registry; the composition
/// root points the inspector at the runtime once that exists.
pub fn register(r: *plugin.Registry, inspector: *tool_inspect.Inspector, transports: *Transports) !void {
    for ([_]plugin.provider.Api{
        provider_openai.api(&transports.openai),
        provider_codex.api(&transports.codex),
        provider_anthropic.api(&transports.anthropic),
    }) |api| try r.addApi(try r.addPlugin(.{ .id = api.id }), api);
    inline for (.{
        @import("tool_read.zig").tool,
        @import("tool_write.zig").tool,
        @import("tool_edit.zig").tool,
        @import("tool_bash.zig").tool,
        @import("tool_webfetch.zig").tool,
    }) |tool| try r.addTool(try r.addPlugin(.{ .id = tool.name }), tool);
    try r.addTool(try r.addPlugin(.{ .id = "zeta_inspect" }), tool_inspect.tool(inspector));
    // Skills are loaded per run beside the registry (see resources.zig);
    // the plugin entry names them in listings.
    _ = try r.addPlugin(.{ .id = "skills" });
}
