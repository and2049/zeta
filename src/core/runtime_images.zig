//! Image admission is serialized with selector changes, using the active
//! worker's frozen capabilities when a turn is already running.
const std = @import("std");
const Runtime = @import("Runtime.zig");
const config = @import("config.zig");

/// Caller holds Runtime.mutex. Catalog lookup does not perform network I/O.
pub fn check(rt: *Runtime, entry: *Runtime.Entry) !void {
    if (entry.running) {
        if (!(entry.active_images orelse return error.SessionBusy)) return error.ModelDoesNotSupportImages;
        return;
    }
    var arena = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg = try config.loadWithOptions(a, rt.io, rt.env, rt.config_dir, entry.session.info.location, entry.overrides);
    if (entry.session.model_selected) cfg.model = entry.overrides.model;
    try @import("runtime_model.zig").fill(rt, a, entry.session.info.location, &cfg);
    const ref = config.splitModel(cfg.model orelse return error.NoModel) orelse return error.InvalidConfig;
    const view = try rt.registry.view(a, entry.session.info.location);
    const routed = try @import("runtime_route.zig").resolve(view, a, rt.io, cfg, ref.provider, ref.model);
    if (!routed.options.accepts_images) return error.ModelDoesNotSupportImages;
}
