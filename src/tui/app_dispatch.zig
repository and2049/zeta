//! Turns an input action into app state changes and background jobs.
const std = @import("std");
const App = @import("App.zig");
const actions = @import("actions.zig");
const plugin = @import("plugin.zig");
const Worker = @import("app_network.zig").Worker;
const auth = @import("app_auth.zig");

pub fn dispatch(app: *App, registry: *const plugin.Registry, worker: *Worker, req: actions.Request) !void {
    switch (req) {
        // The run loop copies and opens links: it has the laid-out transcript.
        .none, .older, .select_session, .copy_selection, .open_at => {},
        .command => |c| {
            const command = registry.command(c.name) orelse return;
            var ctx: plugin.Context = .{ .app = app, .worker = worker };
            command.run(&ctx, c.arguments) catch |err| app.say("/{s} failed: {s}", .{ c.name, @errorName(err) });
        },
        .list_providers, .select_provider, .select_method, .save_key, .cancel_flow, .open_auth_url => try auth.dispatch(app, worker, req),
        .search_files => |query| try worker.submit(.{ .kind = .files, .text = query }),
        .list_directories => |typed| {
            const path = try @import("completion.zig").absolutePath(app.allocator, app.cwd, app.home, if (typed.len == 0) "." else typed);
            defer app.allocator.free(path);
            try worker.submit(.{ .kind = .directories, .text = path, .extra = typed });
        },
        .list_templates => if (app.session) |id| try worker.submit(.{ .kind = .list_commands, .id = id }),
        .select_model => |model| if (app.session) |id| try worker.submit(.{ .kind = .model, .id = id, .text = model }),
        .select_thinking => |level| if (app.session) |id| try worker.submit(.{ .kind = .thinking, .id = id, .text = level }),
        .remove_inbox => |inbox_id| if (app.session) |id| try worker.submit(.{ .kind = .remove_inbox, .id = id, .extra = inbox_id }),
        .edit_pending => |item| if (app.session) |id| {
            try worker.submit(.{ .kind = .edit_inbox, .id = id, .extra = item.id, .text = app.editor.text() });
        },
        .send => |s| {
            if (app.session) |id| {
                if (app.submitting) |busy| if (std.mem.eql(u8, busy, id)) return;
                try worker.submit(.{ .kind = .prompt, .id = id, .text = s.text, .extra = @tagName(s.delivery), .images = app.attachments.items, .image_data = app.embedded_images.items });
                app.submitting = id;
            } else try app.deferSend(s.text, if (s.delivery == .steer) .steer else .queue);
        },
        .abort => if (app.session) |id| try worker.submit(.{ .kind = .abort, .id = id }),
        .answer_question => {}, // The run loop sends this on the independent answers queue.
    }
}
