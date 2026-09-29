//! One extension: starts its process, registers what it declares as the
//! plugin `<name>` (user layer, or the project layer of its location), and
//! answers its calls. An extension that exits, goes silent or breaks the
//! protocol is `failed` and its registrations are gone until `retry` or a
//! reload.
const Extension = @This();
const calls = @import("extension_calls.zig");

const std = @import("std");
const core = @import("core");
const plugin = @import("plugin");
const platform = @import("platform");
const Process = @import("Process.zig");
const register = @import("register.zig");
const adapters = @import("adapters.zig");
const providers = @import("providers.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;

pub const register_timeout_ms = 10_000;

/// What every extension shares; owned by the loader.
pub const Host = struct {
    gpa: Allocator,
    registry: *plugin.Registry,
    env: *const std.process.Environ.Map,
    config_dir: []const u8,
    home: []const u8,
    /// Saved credentials, for provider keys.
    data_dir: ?[]const u8 = null,
    /// stderr logs go here, one file per extension.
    log_dir: []const u8,
    /// Set by the composition root once the runtime exists.
    runtime: ?*core.Runtime = null,
};

pub const Source = struct {
    /// The name it must register; null takes the one it registers.
    name: ?[]const u8,
    argv: []const []const u8,
    cwd: []const u8,
    env: []const [2][]const u8 = &.{},
    /// Where it came from: a path, or `config`.
    origin: []const u8,
};

pub const State = enum { starting, running, failed };

/// One start of the extension.
const Attempt = struct {
    ext: *Extension,
    process: ?*Process = null,
    /// Set when this start is stopped; a process published after that is
    /// stopped by its launch.
    stopped: bool = false,
    /// Set once this start is no longer `starting`; never reset.
    ready: Io.Event = .unset,
};

host: *Host,
io: Io,
/// Source and location copies.
arena: std.heap.ArenaAllocator,
source: Source,
location: ?[]const u8,
mutex: Io.Mutex = .init,
state: State = .starting,
/// The registered name once known.
name: ?[]const u8 = null,
problem: ?[]u8 = null,
/// The start that counts; older ones are ignored. Every attempt is kept
/// until `destroy`: requests and waiting runs may still hold one.
attempt: ?*Attempt = null,
attempts: std.ArrayList(*Attempt) = .empty,
owner: ?plugin.Registry.Owner = null,
/// Memory of registrations; views taken earlier may still use them.
versions: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
tasks: Io.Group = .init,
closing: bool = false,
/// Serializes restart and shutdown.
lifecycle: Io.Mutex = .init,

pub fn create(host: *Host, io: Io, source: Source, location: ?[]const u8) !*Extension {
    const e = try host.gpa.create(Extension);
    e.* = .{ .host = host, .io = io, .arena = .init(host.gpa), .source = undefined, .location = null };
    errdefer {
        e.arena.deinit();
        host.gpa.destroy(e);
    }
    const a = e.arena.allocator();
    e.location = if (location) |here| try a.dupe(u8, here) else null;
    const argv = try a.alloc([]const u8, source.argv.len);
    for (source.argv, argv) |arg, *dst| dst.* = try a.dupe(u8, arg);
    const env = try a.alloc([2][]const u8, source.env.len);
    for (source.env, env) |pair, *dst| dst.* = .{ try a.dupe(u8, pair[0]), try a.dupe(u8, pair[1]) };
    e.source = .{
        .name = if (source.name) |n| try a.dupe(u8, n) else null,
        .argv = argv,
        .cwd = try a.dupe(u8, source.cwd),
        .env = env,
        .origin = try a.dupe(u8, source.origin),
    };
    try e.begin();
    return e;
}

/// Starts an attempt; it is current at once, so a run that settles right
/// after waits for it.
fn begin(e: *Extension) !void {
    const gpa = e.host.gpa;
    const attempt = try gpa.create(Attempt);
    attempt.* = .{ .ext = e };
    e.mutex.lockUncancelable(e.io);
    e.attempts.append(gpa, attempt) catch |err| {
        e.mutex.unlock(e.io);
        gpa.destroy(attempt);
        return err;
    };
    e.attempt = attempt;
    e.mutex.unlock(e.io);
    e.tasks.concurrent(e.io, launch, .{ e, attempt }) catch |err| {
        attempt.ready.set(e.io);
        return err;
    };
}

/// Removes the registrations at once and refuses new ones; fast, no I/O.
/// `shutdown` stops the process afterwards.
pub fn detach(e: *Extension) void {
    e.mutex.lockUncancelable(e.io);
    defer e.mutex.unlock(e.io);
    e.closing = true;
    e.state = .failed;
    e.release();
}

/// Removes the registrations; the caller holds `mutex`, so nobody sees the
/// owner gone while its plugin id is still taken.
fn release(e: *Extension) void {
    if (e.owner) |o| e.host.registry.dispose(o);
    e.owner = null;
}

/// Stops `attempt`'s process, now or (if it is still starting) when its
/// launch publishes it. Idempotent.
fn stopAttempt(e: *Extension, attempt: *Attempt) void {
    e.mutex.lockUncancelable(e.io);
    attempt.stopped = true;
    const process = attempt.process;
    e.mutex.unlock(e.io);
    if (process) |p| p.shutdown();
}

/// Detaches the extension and stops its process; memory stays until
/// `destroy`, since a request may still be finishing.
pub fn shutdown(e: *Extension) void {
    e.lifecycle.lockUncancelable(e.io);
    defer e.lifecycle.unlock(e.io);
    e.detach();
    // The process's reader goes first: it is what schedules failures.
    const attempt = e.currentAttempt();
    if (attempt) |a| e.stopAttempt(a);
    e.tasks.cancel(e.io);
    if (attempt) |a| a.ready.set(e.io);
}

fn currentAttempt(e: *Extension) ?*Attempt {
    e.mutex.lockUncancelable(e.io);
    defer e.mutex.unlock(e.io);
    return e.attempt;
}

/// Waits for the extension's calls into the host that are still being
/// answered; for teardown, before what they use goes away.
pub fn quiesce(e: *Extension) void {
    for (e.attempts.items) |a| if (a.process) |p| p.quiesce();
}

pub fn destroy(e: *Extension) void {
    const gpa = e.host.gpa;
    e.shutdown();
    for (e.attempts.items) |a| {
        if (a.process) |p| p.destroy();
        gpa.destroy(a);
    }
    e.attempts.deinit(gpa);
    for (e.versions.items) |v| {
        v.deinit();
        gpa.destroy(v);
    }
    e.versions.deinit(gpa);
    if (e.problem) |p| gpa.free(p);
    e.arena.deinit();
    gpa.destroy(e);
}

/// Starts the extension again; false once it was shut down. Its
/// registrations are gone until the new process registers, and runs wait
/// for that.
pub fn retry(e: *Extension) !bool {
    e.lifecycle.lockUncancelable(e.io);
    defer e.lifecycle.unlock(e.io);
    e.mutex.lockUncancelable(e.io);
    const closing = e.closing;
    const old = e.attempt;
    e.mutex.unlock(e.io);
    if (closing) return false;
    if (old) |a| e.stopAttempt(a);
    e.tasks.cancel(e.io);
    e.mutex.lockUncancelable(e.io);
    e.state = .starting;
    if (e.problem) |p| e.host.gpa.free(p);
    e.problem = null;
    e.release();
    e.mutex.unlock(e.io);
    if (old) |a| a.ready.set(e.io);
    try e.begin();
    return true;
}

/// Waits until the current start finished, at most `ms`.
pub fn settle(e: *Extension, ms: u64) Io.Cancelable!void {
    const attempt = e.currentAttempt() orelse return;
    const Done = union(enum) { ready: Io.Cancelable!void, deadline: Io.Cancelable!void };
    var storage: [2]Done = undefined;
    var select: Io.Select(Done) = .init(e.io, &storage);
    defer select.cancelDiscard();
    select.concurrent(.ready, Io.Event.wait, .{ &attempt.ready, e.io }) catch return;
    select.concurrent(.deadline, Io.sleep, .{ e.io, Io.Duration.fromMilliseconds(@intCast(ms)), Io.Clock.awake }) catch return;
    _ = try select.await();
}

pub const Status = struct { name: []const u8, scope: []const u8, status: State, source: []const u8, @"error": ?[]const u8 = null };

pub fn status(e: *Extension, arena: Allocator) !Status {
    e.mutex.lockUncancelable(e.io);
    defer e.mutex.unlock(e.io);
    return .{
        .name = try arena.dupe(u8, e.name orelse e.source.name orelse "?"),
        .scope = if (e.location == null) "user" else "project",
        .status = e.state,
        .source = e.source.origin,
        .@"error" = if (e.problem) |p| try arena.dupe(u8, p) else null,
    };
}

/// The running process, for a request.
pub fn current(e: *Extension) !*Process {
    e.mutex.lockUncancelable(e.io);
    defer e.mutex.unlock(e.io);
    if (e.state != .running) return error.ExtensionNotRunning;
    const attempt = e.attempt orelse return error.ExtensionNotRunning;
    return attempt.process orelse error.ExtensionNotRunning;
}

fn launch(e: *Extension, attempt: *Attempt) Io.Cancelable!void {
    e.startUp(attempt) catch |err| {
        if (err == error.Canceled) {
            attempt.ready.set(e.io);
            return error.Canceled;
        }
        e.fail(attempt, @errorName(err));
    };
}

/// Whether `attempt` is the current start of an extension still running.
fn isCurrent(e: *Extension, attempt: *Attempt) bool {
    return e.attempt == attempt and !e.closing;
}

fn startUp(e: *Extension, attempt: *Attempt) !void {
    const gpa = e.host.gpa;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    var env = try e.host.env.clone(a);
    for (e.source.env) |pair| try env.put(pair[0], pair[1]);
    try Io.Dir.cwd().createDirPath(e.io, e.host.log_dir);
    const log_name = try std.fmt.allocPrint(a, "{s}.log", .{e.source.name orelse std.fs.path.basename(e.source.argv[0])});
    const process = try Process.start(gpa, e.io, .{
        .argv = e.source.argv,
        .cwd = e.source.cwd,
        .env = &env,
        .log_path = try std.fs.path.join(a, &.{ e.host.log_dir, log_name }),
    }, .{ .ctx = e, .answer = calls.answer }, .{ .ctx = attempt, .lost = lost });
    // Published under the lock: a start stopped meanwhile never saw this
    // process, so stopping it is ours. Either way it is freed at destroy.
    e.mutex.lockUncancelable(e.io);
    attempt.process = process;
    const live = e.isCurrent(attempt) and !attempt.stopped;
    e.mutex.unlock(e.io);
    if (!live) {
        e.stopAttempt(attempt);
        return error.Canceled;
    }

    const version = try gpa.create(std.heap.ArenaAllocator);
    version.* = .init(gpa);
    var kept = false;
    defer if (!kept) {
        version.deinit();
        gpa.destroy(version);
    };
    const v = version.allocator();
    const reg = try register.parse(v, try process.awaitRegistration(register_timeout_ms));
    if (e.source.name) |expected| if (!std.mem.eql(u8, expected, reg.name)) {
        e.fail(attempt, try std.fmt.allocPrint(a, "registered as '{s}', expected '{s}'", .{ reg.name, expected }));
        return;
    };
    {
        e.mutex.lockUncancelable(e.io);
        defer e.mutex.unlock(e.io);
        if (!e.isCurrent(attempt)) return error.Canceled;
        e.name = try e.arena.allocator().dupe(u8, reg.name);
        try e.versions.ensureUnusedCapacity(gpa, 1);
        const owner = try e.host.registry.stage(.{
            .id = reg.name,
            .layer = if (e.location == null) .user else .project,
            .location = e.location,
            .source = e.source.origin,
        }, e.owner);
        errdefer e.host.registry.dispose(owner);
        try adapters.add(e, v, owner, reg);
        try providers.add(e, v, owner, reg);
        e.versions.appendAssumeCapacity(version);
        kept = true;
        e.host.registry.commit(owner);
        e.owner = owner;
    }
    // Written without the lock: shutdown must be able to get past a stuck
    // write (it kills the process, which ends the write).
    try process.send(try std.json.Stringify.valueAlloc(a, .{ .type = "ready", .location = e.location, .options = try e.options(a, reg.name) }, .{}));
    e.mutex.lockUncancelable(e.io);
    if (e.isCurrent(attempt)) e.state = .running;
    e.mutex.unlock(e.io);
    attempt.ready.set(e.io);
}

/// `plugin.<name>` from the config of its location (the user config for a
/// user extension).
fn options(e: *Extension, a: Allocator, name: []const u8) !Value {
    const cfg = core.config.load(a, e.io, e.host.env, e.host.config_dir, e.location orelse e.host.home) catch return .null;
    return cfg.pluginOptions(name) orelse .null;
}

/// `attempt` failed: unless another start replaced it, the extension is
/// failed and its registrations are gone.
fn fail(e: *Extension, attempt: *Attempt, reason: []const u8) void {
    const gpa = e.host.gpa;
    e.stopAttempt(attempt);
    e.mutex.lockUncancelable(e.io);
    const counts = e.isCurrent(attempt);
    if (counts) {
        e.state = .failed;
        if (e.problem) |p| gpa.free(p);
        e.problem = gpa.dupe(u8, reason) catch null;
        e.release();
    }
    e.mutex.unlock(e.io);
    if (counts) std.log.warn("extension {s}: {s}", .{ e.name orelse e.source.origin, reason });
    attempt.ready.set(e.io);
}

fn lost(ctx: ?*anyopaque, reason: []const u8) void {
    const attempt: *Attempt = @ptrCast(@alignCast(ctx.?));
    const e = attempt.ext;
    // Runs on the process's reader, which shutting the process down waits
    // for; fail from a task of the extension instead. Checked and scheduled
    // under the lock, so nothing is added once stopping has begun and the
    // final `tasks.cancel` joins everything.
    e.mutex.lockUncancelable(e.io);
    defer e.mutex.unlock(e.io);
    if (!e.isCurrent(attempt) or attempt.stopped) return;
    e.tasks.concurrent(e.io, failLater, .{ e, attempt, reason }) catch {};
}

fn failLater(e: *Extension, attempt: *Attempt, reason: []const u8) Io.Cancelable!void {
    e.fail(attempt, reason);
}
