const std = @import("std");

const version = "0.0.0";

/// One entry per `src/<name>/root.zig` module. `deps` is the full set of
/// modules it may `@import`; anything else fails to compile. This is how the
/// layering rules are enforced.
const ModuleSpec = struct {
    name: []const u8,
    deps: []const []const u8,
};

const modules = [_]ModuleSpec{
    .{ .name = "proto", .deps = &.{} },
    .{ .name = "platform", .deps = &.{} },
    .{ .name = "plugin", .deps = &.{"proto"} },
    .{ .name = "core", .deps = &.{ "proto", "plugin" } },
    .{ .name = "builtins", .deps = &.{ "proto", "plugin", "core", "platform" } },
    .{ .name = "server", .deps = &.{ "proto", "plugin", "core", "platform" } },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release = optimize != .Debug;

    const options = b.addOptions();
    // Release builds pass the tag's version.
    options.addOption([]const u8, "version", b.option([]const u8, "version", "Version to report") orelse version);
    const options_mod = options.createModule();

    var mods: [modules.len]*std.Build.Module = undefined;
    for (modules, 0..) |spec, i| {
        mods[i] = b.createModule(.{
            .root_source_file = b.path(b.fmt("src/{s}/root.zig", .{spec.name})),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mods[i].addImport("build_options", options_mod);
        for (spec.deps) |dep| mods[i].addImport(dep, mods[indexOf(dep)]);
    }

    const docs_step = b.step("docs", "Install documentation under zig-out/docs");
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("docs"),
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = release,
        .stack_check = false,
        .stack_protector = false,
        .omit_frame_pointer = release,
        .unwind_tables = if (release) .none else null,
        .error_tracing = if (release) false else null,
    });
    exe_mod.addImport("build_options", options_mod);
    for (modules, 0..) |spec, i| exe_mod.addImport(spec.name, mods[i]);

    const exe = b.addExecutable(.{ .name = "zeta", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run zeta").dependOn(&run_cmd.step);

    // Each module gets its own test binary so in-file tests run with exactly
    // the imports that module is allowed to see.
    const test_step = b.step("test", "Run unit tests");
    for (modules, 0..) |spec, i| {
        const t = b.addTest(.{ .name = spec.name, .root_module = mods[i] });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    const main_test = b.addTest(.{ .name = "main", .root_module = exe_mod });
    test_step.dependOn(&b.addRunArtifact(main_test).step);
}

fn indexOf(name: []const u8) usize {
    for (modules, 0..) |spec, i| {
        if (std.mem.eql(u8, spec.name, name)) return i;
    }
    std.debug.panic("build.zig: unknown module '{s}'", .{name});
}
