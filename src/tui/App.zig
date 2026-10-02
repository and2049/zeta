//! TUI session state. HTTP and terminal rendering are deliberately outside it.
const std = @import("std");
const App = @This();
const Editor = @import("editor.zig").Editor;
const picker = @import("picker.zig");
const proto = @import("proto");

allocator: std.mem.Allocator,
message_arena: std.heap.ArenaAllocator,
picker_arena: std.heap.ArenaAllocator,
connect_arena: std.heap.ArenaAllocator,
connect_providers: []const @import("client").auth.Provider = &.{},
connect_provider: ?@import("client").auth.Provider = null,
connect_flow: ?@import("client").auth.Flow = null,
connect_secret: std.ArrayList(u8) = .empty,
connect_poll_ticks: usize = 0,
connect_polling: bool = false,
connect_generation: u64 = 0,
connect_url_offset: usize = 0,
connect_instructions_offset: usize = 0,
connect_page_width: usize = 40,
connect_browser: bool = false,
cwd: []const u8,
/// Server project location of the selected session, not necessarily the
/// directory typed for `/cd`. Owned separately from the projection arena.
session_location: []const u8 = "",
session_location_owned: ?[]u8 = null,
/// The user's home directory, shown as `~`; empty when unknown.
home: []const u8 = "",
session: ?[]const u8 = null,
title: []const u8 = "New session",
/// The session has a title of its own, not a placeholder.
named: bool = false,
model: []const u8 = "",
model_owned: ?[]u8 = null,
running: bool = false,
/// The session's thinking level selection; empty for the default.
thinking: []const u8 = "",
/// Context window of the current model (0 unknown) and whether it takes
/// a thinking level, from the model listing.
context_window: u64 = 0,
reasoning: bool = false,
/// Loaded history's total cost in USD.
cost: f64 = 0,
/// Git branch of `cwd`, empty outside a repository.
branch: []const u8 = "",
/// Advances every frame while running; picks the spinner glyph.
tick: u64 = 0,
completion: @import("completion.zig").State = .{},
/// Prompt templates for `/` completion, owned by `template_arena`.
templates: []const picker.Item = &.{},
template_arena: std.heap.ArenaAllocator,
/// `@` matches for `file_query`, owned by `file_arena`.
files: []const picker.Item = &.{},
file_query: []const u8 = "",
file_arena: std.heap.ArenaAllocator,
/// Subdirectories of `directory_parent` (as typed) for a directory
/// argument; ids are the typed parent plus the name and `/`.
directories: []const picker.Item = &.{},
directory_parent: ?[]const u8 = null,
directory_arena: std.heap.ArenaAllocator,
/// Owns `cwd` once the session moved.
cwd_owned: ?[]u8 = null,
/// The running turn: when it started (epoch ms) and what it is doing.
turn_started: ?i64 = null,
activity: Activity = .working,
/// The tool being run, when `activity` is `tool`.
activity_tool: []const u8 = "",
/// A compaction is running (between its start and end events).
compacting: bool = false,
/// Local time for turn footers and session dates.
clock: @import("clock.zig").Clock = .{},
/// Compaction summaries are shown in full.
show_compaction: bool = false,
expand_tools: bool = false,
show_reasoning: bool = false,
usage_input: u64 = 0,
usage_output: u64 = 0,
last_context: ?u64 = null,
render_revision: u64 = 0,
/// Session whose prompt request is in flight; a second Enter there waits.
submitting: ?[]const u8 = null,
/// Enter before the first session existed: the input as it was then,
/// sent once the session is created (later edits stay in the editor).
deferred_send: ?Deferred = null,
auto_title_attempted: bool = false,
connected: bool = false,
follow_end: bool = true,
scroll: usize = 0,
last_lines: usize = 0,
history_prepend: bool = false,
quit: bool = false,
overlay: Overlay = .none,
picker_items: []const picker.Item = &.{},
pending_picker_items: ?[]picker.Item = null,
picker_selected: usize = 0,
picker_waiting: bool = false,
picker_confirm_pending: bool = false,
picker_query: std.ArrayList(u8) = .empty,
status: []const u8 = "Connecting…",
status_buffer: [128]u8 = undefined,
editor: Editor,
drafts: std.StringHashMapUnmanaged([]u8) = .empty,
messages: std.ArrayList(Message) = .empty,
pending: std.ArrayList(Pending) = .empty,
questions: @import("questions.zig").Queue,
attachments: std.ArrayList([]const u8) = .empty,
embedded_images: std.ArrayList(proto.attachment.Image) = .empty,

pub const Overlay = enum { none, help, models, thinking, sessions, pending, question, connect_providers, connect_methods, connect_key, connect_oauth };
pub const Message = struct {
    role: []const u8,
    /// For a tool call, its JSON arguments.
    text: []const u8,
    id: ?[]const u8 = null,
    thinking: []const u8 = "",
    tool_name: ?[]const u8 = null,
    /// A tool call's result text, once it arrived.
    output: []const u8 = "",
    /// Why a user message was added without typing, e.g. `move`.
    origin: ?[]const u8 = null,
    /// A compaction summary: the context size it replaced.
    tokens_before: ?u64 = null,
    /// Role `turn_end`: how long the turn took and how it ended.
    turn: ?Turn = null,
    is_error: bool = false,
    tool_running: bool = false,
    changes: []const proto.message.FileChange = &.{},
};
pub const Turn = struct {
    /// Epoch milliseconds.
    started: i64,
    ended: i64,
    outcome: enum { done, stopped, failed },
};
/// What the running turn is doing, for the working row.
pub const Activity = enum { working, thinking, tool, compacting };
pub const Pending = struct { id: []const u8, text: []const u8, delivery: []const u8 };
/// A saved editor state: text plus attached paths and images.
pub const Draft = struct { text: []const u8 = "", paths: []const []const u8 = &.{}, images: []const proto.attachment.Image = &.{} };
pub const Delivery = enum { queue, steer };
pub const Deferred = struct {
    delivery: Delivery,
    /// JSON `Draft`, owned by the app allocator.
    draft: []u8,
};

pub fn init(a: std.mem.Allocator, cwd: []const u8) App {
    return .{ .allocator = a, .cwd = cwd, .questions = .{ .allocator = a }, .editor = Editor.init(a), .message_arena = .init(a), .picker_arena = .init(a), .connect_arena = .init(a), .template_arena = .init(a), .file_arena = .init(a), .directory_arena = .init(a) };
}

pub fn deinit(self: *App) void {
    if (self.deferred_send) |deferred| self.allocator.free(deferred.draft);
    self.clearInput();
    self.editor.deinit();
    self.questions.deinit();
    if (self.model_owned) |name| self.allocator.free(name);
    self.message_arena.deinit();
    self.picker_arena.deinit();
    self.template_arena.deinit();
    self.file_arena.deinit();
    self.directory_arena.deinit();
    if (self.cwd_owned) |owned| self.allocator.free(owned);
    if (self.session_location_owned) |owned| self.allocator.free(owned);
    self.clearSecret();
    self.connect_secret.deinit(self.allocator);
    self.connect_arena.deinit();
    self.picker_query.deinit(self.allocator);
    if (self.pending_picker_items) |items| self.allocator.free(items);
    var it = self.drafts.valueIterator();
    while (it.next()) |value| self.allocator.free(value.*);
    self.drafts.deinit(self.allocator);
    self.messages.deinit(self.allocator);
    self.pending.deinit(self.allocator);
    self.attachments.deinit(self.allocator);
    self.embedded_images.deinit(self.allocator);
}

pub fn clearSecret(self: *App) void {
    @memset(self.connect_secret.items, 0);
    self.connect_secret.clearRetainingCapacity();
}

pub fn ask(self: *App, data: std.json.Value, envelope_session: ?[]const u8, location: ?[]const u8) !void {
    if (try self.questions.add(data, envelope_session, location, self.session, self.session_location) and self.overlay == .none) self.overlay = .question;
}

pub fn resolve(self: *App, id: []const u8) void {
    if (self.questions.remove(id) and self.overlay == .question and self.questions.items.items.len == 0) self.overlay = .none;
}

/// Save the old draft and restore the target's draft. Session strings must
/// remain valid for the lifetime of this state (the run arena owns them).
pub fn switchSession(self: *App, id: []const u8) !void {
    if (self.session) |old| {
        if (self.drafts.fetchRemove(old)) |old_draft| self.allocator.free(old_draft.value);
        try self.drafts.put(self.allocator, old, try std.json.Stringify.valueAlloc(self.allocator, .{ .text = self.editor.text(), .paths = self.attachments.items, .images = self.embedded_images.items }, .{}));
    }
    if (self.session != null) {
        self.clearInput();
        if (self.drafts.get(id)) |saved| {
            const parsed = try std.json.parseFromSlice(struct { text: []const u8, paths: []const []const u8, images: []const proto.attachment.Image }, self.allocator, saved, .{});
            defer parsed.deinit();
            try self.editor.insert(parsed.value.text);
            for (parsed.value.paths) |path| try self.attachments.append(self.allocator, try self.allocator.dupe(u8, path));
            for (parsed.value.images) |image| try self.embedded_images.append(self.allocator, try proto.attachment.Image.init(self.allocator, image.mimeType, image.data));
        }
    }
    self.session = id;
    if (self.model_owned) |name| self.allocator.free(name);
    self.model_owned = null;
    self.model = "";
    self.title = "Loading session…";
    self.named = false;
    self.render_revision +%= 1;
    self.questions.clear();
    self.setSessionLocation("") catch unreachable;
    self.running = false;
    self.thinking = "";
    self.cost = 0;
    self.auto_title_attempted = false;
    self.messages.clearRetainingCapacity();
    self.pending.clearRetainingCapacity();
    self.follow_end = true;
    self.scroll = 0;
    self.last_lines = 0;
    self.history_prepend = false;
    self.overlay = .none;
    self.picker_query.clearRetainingCapacity();
    self.picker_items = &.{};
    self.picker_waiting = false;
    self.picker_confirm_pending = false;
    _ = self.picker_arena.reset(.free_all);
    if (self.pending_picker_items) |items| self.allocator.free(items);
    self.pending_picker_items = null;
}

/// The client now works in `path`: completions made for the old one go.
pub fn setCwd(self: *App, path: []const u8) !void {
    const owned = try self.allocator.dupe(u8, path);
    if (self.cwd_owned) |old| self.allocator.free(old);
    self.cwd_owned = owned;
    self.cwd = owned;
    self.templates = &.{};
    _ = self.template_arena.reset(.free_all);
    self.files = &.{};
    self.file_query = "";
    _ = self.file_arena.reset(.free_all);
    self.directories = &.{};
    self.directory_parent = null;
    _ = self.directory_arena.reset(.free_all);
}

pub fn setSessionLocation(self: *App, location: []const u8) !void {
    const owned = try self.allocator.dupe(u8, location);
    if (self.session_location_owned) |old| self.allocator.free(old);
    self.session_location_owned = owned;
    self.session_location = owned;
}

/// Shows a picker in the dock; `waiting` until its items arrive.
pub fn openPicker(self: *App, overlay: Overlay, waiting: bool) void {
    self.overlay = overlay;
    self.picker_items = &.{};
    self.picker_selected = 0;
    self.picker_waiting = waiting;
    self.picker_confirm_pending = false;
    self.picker_query.clearRetainingCapacity();
}

/// Sets the status line to a formatted message (cut to fit its buffer).
pub fn say(self: *App, comptime format: []const u8, args: anytype) void {
    var w: std.Io.Writer = .fixed(&self.status_buffer);
    w.print(format, args) catch {};
    self.status = w.buffered();
}

/// Captures the input as sent, before any session exists to send it to.
pub fn deferSend(self: *App, text: []const u8, delivery: Delivery) !void {
    const draft = try std.json.Stringify.valueAlloc(self.allocator, Draft{ .text = text, .paths = self.attachments.items, .images = self.embedded_images.items }, .{});
    if (self.deferred_send) |old| self.allocator.free(old.draft);
    self.deferred_send = .{ .delivery = delivery, .draft = draft };
}

/// A prompt request for `session` finished (or failed).
pub fn submitted(self: *App, session: []const u8) void {
    if (self.submitting) |busy| if (std.mem.eql(u8, busy, session)) {
        self.submitting = null;
    };
}

pub fn setEffectiveModel(self: *App, name: []const u8) !void {
    const owned = try self.allocator.dupe(u8, name);
    if (self.model_owned) |old| self.allocator.free(old);
    self.model_owned = owned;
    self.model = self.model_owned.?;
}

pub fn appendText(self: *App, text: []const u8) !void {
    try self.editor.insert(text);
}

pub fn clearInput(self: *App) void {
    self.editor.clear();
    for (self.attachments.items) |path| self.allocator.free(path);
    self.attachments.clearRetainingCapacity();
    for (self.embedded_images.items) |image| {
        self.allocator.free(image.mimeType);
        self.allocator.free(image.data);
    }
    self.embedded_images.clearRetainingCapacity();
}

/// Keep a removed pending input locally even if the user typed or switched
/// sessions while its DELETE request was in flight. Never resubmit implicitly.
/// Drops a saved draft, e.g. for a deleted session.
pub fn forgetDraft(self: *App, id: []const u8) void {
    if (self.drafts.fetchRemove(id)) |entry| self.allocator.free(entry.value);
}

pub fn restorePending(self: *App, id: []const u8, text: []const u8, images: []const proto.attachment.Image) !void {
    if (self.session != null and std.mem.eql(u8, self.session.?, id)) {
        if (self.editor.text().len != 0) try self.editor.insert("\n");
        try self.editor.insert(text);
        for (images) |image| try self.embedded_images.append(self.allocator, try proto.attachment.Image.init(self.allocator, image.mimeType, image.data));
        return;
    }
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const saved = if (self.drafts.get(id)) |bytes| try std.json.parseFromSliceLeaky(Draft, a, bytes, .{}) else Draft{};
    const merged = try std.json.Stringify.valueAlloc(self.allocator, Draft{
        .text = if (saved.text.len == 0) text else try std.mem.concat(a, u8, &.{ saved.text, "\n", text }),
        .paths = saved.paths,
        .images = try std.mem.concat(a, proto.attachment.Image, &.{ saved.images, images }),
    }, .{});
    errdefer self.allocator.free(merged);
    const entry = self.drafts.getEntry(id) orelse return error.UnknownDraftSession;
    self.allocator.free(entry.value_ptr.*);
    entry.value_ptr.* = merged;
}

pub fn appendMessage(self: *App, role: []const u8, text: []const u8) !void {
    try self.messages.append(self.allocator, .{ .role = role, .text = text });
}

pub fn scrollUp(self: *App, lines: usize) void {
    self.follow_end = false;
    self.scroll +|= lines;
}

pub fn scrollDown(self: *App, lines: usize) void {
    self.scroll -|= lines;
    if (self.scroll == 0) self.follow_end = true;
}

test "draft survives session switching" {
    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    try app.switchSession("one");
    try app.appendText("draft one");
    try app.switchSession("two");
    try app.appendText("draft two");
    try app.switchSession("one");
    try std.testing.expectEqualStrings("draft one", app.editor.text());
}

test "a deferred send keeps the input as sent; submitting is per session" {
    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    try app.editor.insert("sent text");
    try app.attachments.append(app.allocator, try app.allocator.dupe(u8, "shot.png"));
    try app.deferSend("sent text", .steer);
    try app.editor.insert(" edited later");
    const draft = try std.json.parseFromSlice(Draft, std.testing.allocator, app.deferred_send.?.draft, .{});
    defer draft.deinit();
    try std.testing.expectEqualStrings("sent text", draft.value.text);
    try std.testing.expectEqualStrings("shot.png", draft.value.paths[0]);
    try std.testing.expectEqual(Delivery.steer, app.deferred_send.?.delivery);

    app.submitting = "one";
    app.submitted("two");
    try std.testing.expectEqualStrings("one", app.submitting.?);
    app.submitted("one");
    try std.testing.expect(app.submitting == null);
}

test "attachments stay with their session and restored pending input never overwrites typing" {
    var app = App.init(std.testing.allocator, "/tmp");
    defer app.deinit();
    try app.switchSession("one");
    try app.attachments.append(app.allocator, try app.allocator.dupe(u8, "image.png"));
    try app.editor.insert("typed");
    try app.switchSession("two");
    try std.testing.expectEqual(@as(usize, 0), app.attachments.items.len);
    try app.restorePending("one", "removed prompt", &.{.{ .mimeType = "image/png", .data = "YWJj" }});
    try app.switchSession("one");
    try std.testing.expectEqualStrings("typed\nremoved prompt", app.editor.text());
    try std.testing.expectEqualStrings("image.png", app.attachments.items[0]);
    try std.testing.expectEqualStrings("YWJj", app.embedded_images.items[0].data);
}
