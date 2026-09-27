//! Shared built-in provider registration for the runtime.
const std = @import("std");
const plugin = @import("plugin");
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

/// `transports` must outlive the registry.
pub fn register(r: *plugin.Registry, transports: *Transports) !void {
    for ([_]plugin.provider.Api{
        provider_openai.api(&transports.openai),
        provider_codex.api(&transports.codex),
        provider_anthropic.api(&transports.anthropic),
    }) |api| try r.addApi(try r.addPlugin(.{ .id = api.id }), api);
}
