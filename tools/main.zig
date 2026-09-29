//! `bin/labelle-sdl2`: the labelle-cli `sdl2` provider executable (RFC
//! labelle-cli#471, S1), the port of the CLI's `sdl_provision.zig`.
//!
//! One binary serves every command and hook `plugin.labelle` declares, like
//! labelle-android's and labelle-web's. The CLI writes a contract context to
//! the file named by `LABELLE_CONTEXT`; this decodes it strictly
//! (`contract.zig`), routes on `(kind, id, step, phase)` and refuses any
//! combination the manifest does not declare.
//!
//! - hook `env` (before generate, `desktop`): on a Windows host, for a
//!   project that needs SDL2 (`project.zig`) and has no `LABELLE_SDL2_LIB`
//!   of its own, provision SDL2 into `cache_dir` and contribute
//!   `LABELLE_SDL2_LIB` through `env_file`. A no-op elsewhere: Linux and
//!   macOS keep using the system / Homebrew SDL2.
//! - hook `stage` (after build, `desktop`): on Windows, copy `SDL2.dll` next
//!   to the built exe.
//! - `labelle sdl2 doctor [--json] [--fix]`, `labelle sdl2 install`.
//!
//! Exit status: 0 on success, 1 on any failure (with one `labelle-sdl2:`
//! diagnostic line on stderr). Reports go to stderr; the one exception is
//! `doctor --json`, whose capability object is the command's stdout.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract.zig");
const project = @import("project.zig");
const sdl2 = @import("sdl2.zig");
const env = @import("env.zig");
const stage = @import("stage.zig");
const doctor = @import("doctor.zig");
const stdio = @import("stdio.zig");

pub const Action = enum { doctor, install, env_hook, stage_hook };

const Kind = @FieldType(contract.Invocation, "kind");

/// One declared entry point. Must match `plugin.labelle` exactly.
const Route = struct {
    kind: Kind,
    id: []const u8,
    step: ?contract.Step = null,
    phase: ?contract.Phase = null,
    action: Action,
    needs_project: bool,
};

const routes = [_]Route{
    .{ .kind = .command, .id = "doctor", .action = .doctor, .needs_project = false },
    .{ .kind = .command, .id = "install", .action = .install, .needs_project = false },
    .{ .kind = .hook, .id = "env", .step = .generate, .phase = .before, .action = .env_hook, .needs_project = true },
    .{ .kind = .hook, .id = "stage", .step = .build, .phase = .after, .action = .stage_hook, .needs_project = true },
};

/// The one target this provider's hooks attach to (core-owned; no
/// `.targets` of its own).
pub const target = "desktop";

pub const RouteError = error{ UnknownCommand, UnknownHook, InvalidInvocation, UnsupportedTarget };

pub fn route(ctx: contract.Context) RouteError!Action {
    const inv = ctx.invocation;
    for (routes) |r| {
        if (r.kind != inv.kind or !std.mem.eql(u8, r.id, inv.id)) continue;
        if (!sameStep(r.step, inv.step) or !samePhase(r.phase, inv.phase)) return error.InvalidInvocation;
        if (r.needs_project and ctx.project_dir == null) return error.InvalidInvocation;
        if (r.kind == .hook and !std.mem.eql(u8, ctx.target orelse "", target)) return error.UnsupportedTarget;
        return r.action;
    }
    return switch (inv.kind) {
        .command => error.UnknownCommand,
        .hook => error.UnknownHook,
    };
}

fn sameStep(a: ?contract.Step, b: ?contract.Step) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}

fn samePhase(a: ?contract.Phase, b: ?contract.Phase) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}

/// The wires `command_contract = ">=1.3.0 <1.6.0"` admits: 1.3.x, 1.4.x
/// and 1.5.x, stable. 1.3 is the floor: `cache_dir` and `env_file`.
pub fn wireAccepted(wire_version: []const u8) bool {
    const wire = std.SemanticVersion.parse(wire_version) catch return false;
    return wire.major == 1 and wire.minor >= 3 and wire.minor <= 5 and wire.pre == null and wire.build == null;
}

pub fn main(init: std.process.Init) u8 {
    var err_buf: [1024]u8 = undefined;
    // Streaming, never positional: stderr may be a file the CLI shares (cli#446).
    var stderr = stdio.stderrWriter(init.io, &err_buf);
    const out = &stderr.interface;
    const failed = execute(init, out) catch |err| {
        out.print("labelle-sdl2: {s}\n", .{@errorName(err)}) catch {};
        out.flush() catch {};
        return 1;
    };
    out.flush() catch {};
    return if (failed) 1 else 0;
}

/// Returns true when the action ran and reported a failure it already
/// explained (doctor's FAIL rows).
fn execute(init: std.process.Init, out: *std.Io.Writer) !bool {
    const a = init.arena.allocator();
    const io = init.io;
    const context_path = init.environ_map.get(contract.context_env) orelse {
        try out.writeAll("labelle-sdl2: run me through labelle (LABELLE_CONTEXT is not set)\n");
        return error.MissingContext;
    };
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, context_path, a, .limited(1024 * 1024));
    // Every route's own `needs_project` is enforced by `route`.
    const parsed = try contract.parseContext(a, bytes, false);
    const ctx = parsed.value;
    const action = try route(ctx);
    if (!wireAccepted(ctx.contract_version)) return error.UnsupportedContract;

    var args: std.ArrayList([]const u8) = .empty;
    {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
        defer it.deinit();
        _ = it.skip();
        while (it.next()) |arg| {
            if (ctx.invocation.kind == .hook) return error.UnexpectedHookArguments;
            try args.append(a, try a.dupe(u8, arg));
        }
    }

    const fields: ?project.Fields = if (ctx.project_dir) |dir| try project.load(a, io, dir) else null;
    const run: Run = .{
        .a = a,
        .io = io,
        .environ = init.environ_map,
        .ctx = ctx,
        .fields = fields,
        .fetcher = sdl2.system,
    };
    try out.flush();
    switch (action) {
        .env_hook => try envHook(run),
        .stage_hook => try stageHook(run),
        .install => {
            if (args.items.len != 0) {
                try out.print("labelle-sdl2: install takes no arguments (got '{s}')\n", .{args.items[0]});
                return error.UnknownArgument;
            }
            try install(run);
        },
        .doctor => {
            var json = false;
            var fix = false;
            for (args.items) |arg| {
                if (std.mem.eql(u8, arg, "--json")) json = true else if (std.mem.eql(u8, arg, "--fix")) fix = true else {
                    try out.print("labelle-sdl2: unknown argument '{s}' (usage: labelle sdl2 doctor [--json] [--fix])\n", .{arg});
                    return error.UnknownArgument;
                }
            }
            return !try doctorCommand(run, json, fix);
        },
    }
    return false;
}

/// Everything an action reads.
pub const Run = struct {
    a: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    ctx: contract.Context,
    fields: ?project.Fields,
    fetcher: sdl2.Fetcher,
    /// The host OS; a parameter so tests exercise the Windows paths anywhere.
    os: std.Target.Os.Tag = builtin.os.tag,
    release: sdl2.Release = sdl2.pinned,
};

fn describe(a: std.mem.Allocator, fields: ?project.Fields) []const u8 {
    const f = fields orelse return "no project: library only";
    return std.fmt.allocPrint(a, "backend {s}, gamepad {s}", .{ f.backendName(), f.gamepad orelse "auto" }) catch "project";
}

/// `before generate`: provision on Windows and contribute LABELLE_SDL2_LIB.
pub fn envHook(r: Run) !void {
    if (r.os != .windows) return; // system / Homebrew SDL2, as before
    const fields = r.fields.?;
    if (!fields.needsSdl2()) {
        std.debug.print("labelle-sdl2: this project does not need SDL2 ({s}); nothing to provision\n", .{describe(r.a, fields)});
        return;
    }
    if (env.userLibDir(r.environ)) |dir| {
        std.debug.print("labelle-sdl2: using LABELLE_SDL2_LIB from the environment ({s})\n", .{dir});
        return;
    }
    const lib = try sdl2.ensure(r.a, r.io, r.fetcher, r.ctx.cache_dir.?, r.release, .{ .offline = env.offline(r.environ) });
    const env_file = r.ctx.env_file orelse return error.MissingEnvFile;
    try env.writeEnvFile(r.a, r.io, env_file, lib);
    std.debug.print("labelle-sdl2: using SDL2 {s} ({s})\n", .{ r.release.version, lib });
}

/// `after build`: SDL2.dll beside the exe on Windows, plus SDL2_mixer.dll
/// for the `sdl` render backend (its audio links SDL2_mixer).
pub fn stageHook(r: Run) !void {
    if (r.os != .windows) return;
    const fields = r.fields.?;
    if (!fields.needsSdl2()) return;
    const bin = try stage.binDir(r.a, r.ctx.target_dir orelse return error.MissingTargetDir);
    const cache_lib = sdl2.installedLibDir(r.a, r.io, r.ctx.cache_dir.?, r.release);
    const user_lib = env.userLibDir(r.environ);
    switch (try stage.stageDll(r.a, r.io, bin, sdl2.dll_name, user_lib, cache_lib)) {
        .staged => |src| std.debug.print("labelle-sdl2: staged SDL2.dll next to the game exe (from {s})\n", .{src}),
        .up_to_date => {},
        .no_bin_dir => {
            std.debug.print("labelle-sdl2: no {s}; nothing to stage SDL2.dll beside\n", .{bin});
            return;
        },
        .removed_stale => std.debug.print("labelle-sdl2: removed the SDL2.dll staged by an earlier build: the selected SDL2 has none (the game needs it on PATH)\n", .{}),
        .not_found => std.debug.print("labelle-sdl2: warning: no SDL2.dll to stage beside the exe (LABELLE_SDL2_LIB and the provider cache have none); the game needs it on PATH\n", .{}),
    }
    if (!fields.sdlRenderer()) return;
    switch (try stage.stageDll(r.a, r.io, bin, stage.mixer_dll_name, user_lib, cache_lib)) {
        .staged => |src| std.debug.print("labelle-sdl2: staged SDL2_mixer.dll next to the game exe (from {s})\n", .{src}),
        .up_to_date, .no_bin_dir => {},
        .removed_stale => std.debug.print("labelle-sdl2: removed the SDL2_mixer.dll staged by an earlier build: LABELLE_SDL2_LIB has none now\n", .{}),
        .not_found => std.debug.print("labelle-sdl2: warning: no SDL2_mixer.dll beside LABELLE_SDL2_LIB (lib/ or ../bin) to stage; the sdl backend's audio needs it next to the exe or on PATH\n", .{}),
    }
}

/// `labelle sdl2 install`: provision now (Windows), or say how.
pub fn install(r: Run) !void {
    if (r.os != .windows) {
        std.debug.print("labelle-sdl2: nothing to install on this host; the build uses the system SDL2.\n", .{});
        sdl2.printGuidance();
        return;
    }
    const lib = try sdl2.ensure(r.a, r.io, r.fetcher, r.ctx.cache_dir.?, r.release, .{ .offline = env.offline(r.environ) });
    try stdio.answer(r.io, r.ctx.progress == .json, "{s}\n", .{lib});
}

fn doctorCommand(r: Run, json: bool, fix: bool) !bool {
    const needs = if (r.fields) |f| f.needsSdl2() else true;
    const render = if (r.fields) |f| f.sdlRenderer() else false;
    const user_lib = env.userLibDir(r.environ);
    if (fix and needs) {
        if (r.os == .windows and user_lib == null) {
            _ = try sdl2.ensure(r.a, r.io, r.fetcher, r.ctx.cache_dir.?, r.release, .{ .offline = env.offline(r.environ) });
        } else if (r.os != .windows) sdl2.printGuidance();
    }
    const cache = r.ctx.cache_dir.?;
    var system: doctor.System = .{ .io = r.io, .a = r.a, .path_env = r.environ.get("PATH") orelse r.environ.get("Path") };
    return doctor.run(r.a, r.io, system.probe(), .{
        .os = r.os,
        .needs = needs,
        .render = render,
        .user_lib = user_lib,
        .cache_lib = sdl2.installedLibDir(r.a, r.io, cache, r.release),
        .install_dir = try sdl2.installDir(r.a, cache, r.release),
        .offline = env.offline(r.environ),
        .host_supported = r.release.mingw != null,
    }, json, describe(r.a, r.fields));
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

fn contextFor(kind: Kind, id: []const u8, step: ?contract.Step, phase: ?contract.Phase, has_project: bool) contract.Context {
    const root = if (builtin.os.tag == .windows) "C:/p" else "/p";
    return .{
        .contract_version = contract.version,
        .invocation = .{ .kind = kind, .id = id, .step = step, .phase = phase },
        .package_dir = root,
        .project_dir = if (has_project) root else null,
        .target = if (has_project) target else null,
        .lock_file = if (has_project) root else null,
        .config_file = null,
        .output_dir = root,
        .zig_executable = root,
        .optimize = .Debug,
        .progress = .human,
    };
}

fn expected(kind: Kind, id: []const u8, step: ?contract.Step, phase: ?contract.Phase, has_project: bool) RouteError!Action {
    for (routes) |r| {
        if (r.kind != kind or !std.mem.eql(u8, r.id, id)) continue;
        if (!sameStep(r.step, step) or !samePhase(r.phase, phase)) return error.InvalidInvocation;
        if (r.needs_project and !has_project) return error.InvalidInvocation;
        return r.action;
    }
    return if (kind == .hook) error.UnknownHook else error.UnknownCommand;
}

test "invocation matrix: only the declared (kind, id, step, phase) runs" {
    const ids = [_][]const u8{ "doctor", "install", "env", "stage", "bogus" };
    const steps = [_]?contract.Step{ null, .generate, .build, .bundle, .run };
    const phases = [_]?contract.Phase{ null, .before, .replace, .after };
    var accepted: usize = 0;
    for ([_]Kind{ .command, .hook }) |kind| for (ids) |id| for (steps) |step| for (phases) |phase| for ([_]bool{ false, true }) |has_project| {
        const want = expected(kind, id, step, phase, has_project);
        const got = route(contextFor(kind, id, step, phase, has_project));
        if (want) |action| {
            try testing.expectEqual(action, try got);
            accepted += 1;
        } else |err| try testing.expectError(err, got);
    };
    // doctor and install in and out of a project; the two hooks in one.
    try testing.expectEqual(@as(usize, 6), accepted);
    try testing.expectEqual(Action.env_hook, try route(contextFor(.hook, "env", .generate, .before, true)));
    try testing.expectEqual(Action.stage_hook, try route(contextFor(.hook, "stage", .build, .after, true)));
    try testing.expectError(error.InvalidInvocation, route(contextFor(.hook, "env", .build, .before, true)));
    try testing.expectError(error.UnknownCommand, route(contextFor(.command, "bogus", null, null, true)));
}

test "a hook for another target is refused" {
    var ctx = contextFor(.hook, "env", .generate, .before, true);
    ctx.target = "wasm";
    try testing.expectError(error.UnsupportedTarget, route(ctx));
}

test "routes mirror plugin.labelle" {
    const a = testing.allocator;
    const manifest = @embedFile("plugin.labelle");
    const tool = ".build_step = \"install-provider\", .executable = \"bin/labelle-sdl2\"";
    var commands: usize = 0;
    var hooks: usize = 0;
    for (routes) |r| {
        const needle = switch (r.kind) {
            .command => try std.fmt.allocPrint(a, ".name = \"{s}\", {s}", .{ r.id, tool }),
            .hook => try std.fmt.allocPrint(a, ".id = \"{s}\", .step = .{s}, .target = \"{s}\", .when = .{s}, {s}", .{
                r.id, @tagName(r.step.?), target, @tagName(r.phase.?), tool,
            }),
        };
        defer a.free(needle);
        try testing.expect(std.mem.indexOf(u8, manifest, needle) != null);
        switch (r.kind) {
            .command => commands += 1,
            .hook => hooks += 1,
        }
    }
    const declared = manifest[std.mem.indexOf(u8, manifest, ".commands = .{").?..];
    try testing.expectEqual(commands, std.mem.count(u8, declared, ".name = \""));
    try testing.expectEqual(hooks, std.mem.count(u8, declared, ".id = \""));
    try testing.expect(std.mem.indexOf(u8, manifest, ".name = \"sdl2\"") != null);
    try testing.expect(std.mem.indexOf(u8, manifest, ".namespace = \"sdl2\"") != null);
    try testing.expect(std.mem.indexOf(u8, manifest, ".command_contract = \">=1.3.0 <1.6.0\"") != null);
    // No targets of its own: `desktop` is core-owned.
    try testing.expect(std.mem.indexOf(u8, manifest, ".targets") == null);
}

test "the wire range is 1.3.x to 1.5.x" {
    for ([_][]const u8{ "1.3.0", "1.4.0", "1.5.0", "1.5.2" }) |v| try testing.expect(wireAccepted(v));
    for ([_][]const u8{ "1.2.0", "1.6.0", "2.0.0", "1.4.0-rc.1", "x" }) |v| try testing.expect(!wireAccepted(v));
}

test "the vendored decoder accepts its fixtures and routes them" {
    const parsed = try contract.parseContext(testing.allocator, contract.fixture, false);
    defer parsed.deinit();
    try testing.expectEqual(Action.doctor, try route(parsed.value));
}

/// A Run for hook tests, rooted in a temp dir.
const HookFixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    environ: std.process.Environ.Map,
    root: []const u8 = "",
    fake: sdl2.Fake = .{},
    release: sdl2.Release = undefined,

    fn init(self: *HookFixture) !void {
        self.* = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator), .environ = .init(testing.allocator) };
        self.root = try self.tmp.dir.realPathFileAlloc(testing.io, ".", self.arena.allocator());
        self.release = self.fake.release();
    }
    fn deinit(self: *HookFixture) void {
        testing.allocator.free(self.release.sha256);
        self.environ.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
    }
    fn path(self: *HookFixture, parts: []const []const u8) ![]const u8 {
        const a = self.arena.allocator();
        var all: std.ArrayList([]const u8) = .empty;
        try all.append(a, self.root);
        try all.appendSlice(a, parts);
        return std.fs.path.join(a, all.items);
    }
    fn run(self: *HookFixture, id: []const u8, project_src: [:0]const u8, os: std.Target.Os.Tag) !Run {
        const a = self.arena.allocator();
        var ctx = contextFor(.hook, id, .generate, .before, true);
        ctx.project_dir = self.root;
        ctx.cache_dir = try self.path(&.{"cache"});
        ctx.env_file = try self.path(&.{"env.json"});
        ctx.target_dir = try self.path(&.{ ".labelle", "bgfx_desktop" });
        return .{
            .a = a,
            .io = testing.io,
            .environ = &self.environ,
            .ctx = ctx,
            .fields = try project.parseFields(a, project_src),
            .fetcher = self.fake.fetcher(),
            .os = os,
            .release = self.release,
        };
    }
};

test "env hook: Windows + needs SDL2 provisions into cache_dir and writes LABELLE_SDL2_LIB" {
    var f: HookFixture = undefined;
    try f.init();
    defer f.deinit();
    const r = try f.run("env", ".{ .backend = .bgfx }", .windows);
    try envHook(r);
    try testing.expectEqual(@as(usize, 1), f.fake.downloads);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, r.ctx.env_file.?, r.a, .limited(4096));
    const c = try std.json.parseFromSliceLeaky(env.Contribution, r.a, bytes, .{});
    try testing.expectEqualStrings("LABELLE_SDL2_LIB", c.set[0].name);
    try testing.expectEqualStrings(sdl2.installedLibDir(r.a, testing.io, r.ctx.cache_dir.?, f.release).?, c.set[0].value);
    // A second build reuses the install.
    try std.Io.Dir.cwd().deleteFile(testing.io, r.ctx.env_file.?);
    try envHook(r);
    try testing.expectEqual(@as(usize, 1), f.fake.downloads);
    try testing.expect(sdl2.exists(testing.io, r.ctx.env_file.?));
}

test "env hook: a no-op off Windows, for .gamepad = .none, and with the user's LABELLE_SDL2_LIB" {
    var f: HookFixture = undefined;
    try f.init();
    defer f.deinit();
    for ([_]std.Target.Os.Tag{ .macos, .linux }) |os| try envHook(try f.run("env", ".{ .backend = .sdl }", os));
    try envHook(try f.run("env", ".{ .backend = .raylib, .gamepad = .none }", .windows));
    try envHook(try f.run("env", ".{ .backend = .wgpu }", .windows));
    try f.environ.put("LABELLE_SDL2_LIB", "C:/mine/lib");
    try envHook(try f.run("env", ".{ .backend = .sdl }", .windows));
    try testing.expectEqual(@as(usize, 0), f.fake.downloads);
    try testing.expect(!sdl2.exists(testing.io, try f.path(&.{"env.json"})));
}

test "env hook: LABELLE_OFFLINE with nothing installed fails before any download" {
    var f: HookFixture = undefined;
    try f.init();
    defer f.deinit();
    try f.environ.put("LABELLE_OFFLINE", "1");
    try testing.expectError(error.Sdl2NotInstalledOffline, envHook(try f.run("env", ".{}", .windows)));
    try testing.expectEqual(@as(usize, 0), f.fake.downloads);
}

test "stage hook: Windows copies the cached SDL2.dll beside the exe; elsewhere nothing" {
    var f: HookFixture = undefined;
    try f.init();
    defer f.deinit();
    const r = try f.run("stage", ".{ .backend = .sokol }", .windows);
    const bin = try stage.binDir(r.a, r.ctx.target_dir.?);
    try sdl2.Fake.touch(testing.io, r.a, &.{ bin, "game.exe" });
    // Off Windows: never touches the bin dir.
    try stageHook(try f.run("stage", ".{ .backend = .sokol }", .linux));
    try testing.expect(!sdl2.exists(testing.io, try std.fs.path.join(r.a, &.{ bin, "SDL2.dll" })));
    // Nothing provisioned yet: a warning, not a failure.
    try stageHook(r);
    try envHook(r);
    try stageHook(r);
    try testing.expect(sdl2.exists(testing.io, try std.fs.path.join(r.a, &.{ bin, "SDL2.dll" })));
    // A project that doesn't need SDL2 stages nothing.
    try std.Io.Dir.cwd().deleteFile(testing.io, try std.fs.path.join(r.a, &.{ bin, "SDL2.dll" }));
    try stageHook(try f.run("stage", ".{ .backend = .sokol, .gamepad = .none }", .windows));
    try testing.expect(!sdl2.exists(testing.io, try std.fs.path.join(r.a, &.{ bin, "SDL2.dll" })));
}

test "stage hook: the sdl renderer also stages SDL2_mixer.dll from the package's bin; missing only warns" {
    var f: HookFixture = undefined;
    try f.init();
    defer f.deinit();
    const r = try f.run("stage", ".{ .backend = .sdl }", .windows);
    const bin = try stage.binDir(r.a, r.ctx.target_dir.?);
    try sdl2.Fake.touch(testing.io, r.a, &.{ bin, "game.exe" });
    // The upstream MinGW layout: DLLs in the lib dir's sibling bin/.
    const lib = try f.path(&.{ "mingw", "lib" });
    try std.Io.Dir.cwd().createDirPath(testing.io, lib);
    try sdl2.Fake.touch(testing.io, r.a, &.{ lib, "..", "bin", "SDL2.dll" });
    try f.environ.put("LABELLE_SDL2_LIB", lib);
    // No mixer yet: SDL2.dll is staged, the mixer only warned about.
    try stageHook(r);
    try testing.expect(sdl2.exists(testing.io, try std.fs.path.join(r.a, &.{ bin, "SDL2.dll" })));
    try testing.expect(!sdl2.exists(testing.io, try std.fs.path.join(r.a, &.{ bin, "SDL2_mixer.dll" })));
    try sdl2.Fake.touch(testing.io, r.a, &.{ lib, "..", "bin", "SDL2_mixer.dll" });
    try stageHook(r);
    try testing.expect(sdl2.exists(testing.io, try std.fs.path.join(r.a, &.{ bin, "SDL2_mixer.dll" })));
    // A gamepad-only backend never stages the mixer.
    try std.Io.Dir.cwd().deleteFile(testing.io, try std.fs.path.join(r.a, &.{ bin, "SDL2_mixer.dll" }));
    try stageHook(try f.run("stage", ".{ .backend = .bgfx }", .windows));
    try testing.expect(!sdl2.exists(testing.io, try std.fs.path.join(r.a, &.{ bin, "SDL2_mixer.dll" })));
}

test "stage hook: the build's LABELLE_SDL2_LIB is the DLL source" {
    var f: HookFixture = undefined;
    try f.init();
    defer f.deinit();
    const r = try f.run("stage", ".{ .backend = .sdl }", .windows);
    const bin = try stage.binDir(r.a, r.ctx.target_dir.?);
    try sdl2.Fake.touch(testing.io, r.a, &.{ bin, "game.exe" });
    const mine = try f.path(&.{ "mine", "lib" });
    try sdl2.Fake.touch(testing.io, r.a, &.{ mine, "SDL2.dll" });
    try f.environ.put("LABELLE_SDL2_LIB", mine);
    try stageHook(r);
    try testing.expect(sdl2.exists(testing.io, try std.fs.path.join(r.a, &.{ bin, "SDL2.dll" })));
    try testing.expectEqual(@as(usize, 0), f.fake.downloads);
}

test {
    _ = contract;
    _ = project;
    _ = sdl2;
    _ = env;
    _ = stage;
    _ = doctor;
    _ = stdio;
    _ = @import("proc.zig");
}
