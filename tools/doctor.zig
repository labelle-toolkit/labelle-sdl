//! `labelle sdl2 doctor [--json] [--fix]`: the SDL2 rows of labelle-cli
//! `doctor.zig` (`checkSdl2Lib`, `checkSdl2Dll`, `checkSdl2Headers`,
//! `checkSdl2Mixer`), ported with the same per-OS rules, reading the
//! provider cache instead of `~/.labelle/sdl2`. Side effect free (`--fix`
//! provisions first, in `main`); exits non-zero only when a requirement is
//! missing.
//!
//! Scoped like the CLI: the library for every project that needs SDL2, the
//! runtime DLL on Windows, and the headers plus SDL2_mixer only for the
//! `sdl` render backend. A project that does not need SDL2 gets no rows.
//!
//! `--json` prints one line on stdout, the capability object
//! `{ "id": "sdl2", "required", "ok", "items": [...] }`, items in
//! labelle-web's / labelle-studio's ToolchainGate shape, for the core
//! `labelle doctor --json` aggregate (RFC labelle-cli#466 D7).
const std = @import("std");
const sdl2 = @import("sdl2.zig");
const stage = @import("stage.zig");
const stdio = @import("stdio.zig");

pub const Item = struct {
    id: []const u8,
    name: []const u8,
    ok: bool,
    fixable: bool = false,
    size_mb: u32 = 0,
    action: ?[]const u8 = null,
    detail: ?[]const u8 = null,
    hint: ?[]const u8 = null,
};

pub const Capability = struct {
    id: []const u8 = "sdl2",
    required: bool,
    ok: bool,
    items: []const Item,
};

/// How the checks see the machine (injectable for host tests).
pub const Probe = struct {
    ctx: ?*anyopaque = null,
    exists: *const fn (ctx: ?*anyopaque, path: []const u8) bool,
    /// `argv` runs and exits 0 (`pkg-config --exists sdl2`).
    cmd_ok: *const fn (ctx: ?*anyopaque, argv: []const []const u8) bool,
    /// The first `PATH` entry holding `name`, or null.
    on_path: *const fn (ctx: ?*anyopaque, name: []const u8) ?[]const u8,
};

/// What the project needs (`project.Fields`), and where SDL2 may be.
pub const Inputs = struct {
    os: std.Target.Os.Tag,
    /// Needs SDL2 at all (gamepad or renderer).
    needs: bool,
    /// The `sdl` render backend: headers and SDL2_mixer too.
    render: bool,
    /// The user's `LABELLE_SDL2_LIB`.
    user_lib: ?[]const u8,
    /// The provider cache's complete install (lib dir), when there is one.
    cache_lib: ?[]const u8,
    /// Where the next build would install it (Windows).
    install_dir: []const u8,
    offline: bool,
};

const install_action = "labelle sdl2 install";
const install_size_mb = 14;

fn join(a: std.mem.Allocator, parts: []const []const u8) []const u8 {
    return std.fs.path.join(a, parts) catch "";
}

fn firstExisting(p: Probe, paths: []const []const u8) ?[]const u8 {
    for (paths) |path| if (p.exists(p.ctx, path)) return path;
    return null;
}

/// Windows with nothing provisioned yet: not a failure, the next desktop
/// build installs it (the `env` hook). Offline it cannot, so say so now.
fn pending(a: std.mem.Allocator, base: Item, in: Inputs) Item {
    var item = base;
    item.ok = !in.offline;
    item.fixable = true;
    item.size_mb = install_size_mb;
    item.action = install_action;
    item.detail = std.fmt.allocPrint(a, "SDL2 {s} not installed yet; the next desktop build installs it into {s}", .{ sdl2.SDL2_VERSION, in.install_dir }) catch in.install_dir;
    if (in.offline) item.hint = "LABELLE_OFFLINE is set: run `labelle sdl2 install` with network access, or set LABELLE_SDL2_LIB";
    return item;
}

pub fn checkLib(a: std.mem.Allocator, p: Probe, in: Inputs) Item {
    const base: Item = .{ .id = "sdl2-lib", .name = "SDL2 library (gamepad + sdl backend)", .ok = true };
    var item = base;
    switch (in.os) {
        .windows => {
            if (in.user_lib) |dir| {
                if (p.exists(p.ctx, join(a, &.{ dir, sdl2.import_lib }))) {
                    item.detail = std.fmt.allocPrint(a, "LABELLE_SDL2_LIB: {s}", .{dir}) catch dir;
                    return item;
                }
                item.ok = false;
                item.hint = std.fmt.allocPrint(a, "LABELLE_SDL2_LIB={s} has no {s}: point it at the SDL2 MinGW package's x86_64-w64-mingw32\\lib, or unset it to let the provider install SDL2", .{ dir, sdl2.import_lib }) catch "LABELLE_SDL2_LIB has no libSDL2.dll.a";
                return item;
            }
            if (in.cache_lib) |dir| {
                item.detail = std.fmt.allocPrint(a, "provider cache: {s}", .{dir}) catch dir;
                return item;
            }
            return pending(a, base, in);
        },
        .linux => {
            if (p.cmd_ok(p.ctx, &.{ "pkg-config", "--exists", "sdl2" })) {
                item.detail = "pkg-config: sdl2";
                return item;
            }
            if (firstExisting(p, &.{ "/usr/lib/x86_64-linux-gnu/libSDL2.so", "/usr/lib/aarch64-linux-gnu/libSDL2.so", "/usr/lib/libSDL2.so", "/usr/lib64/libSDL2.so", "/usr/local/lib/libSDL2.so" })) |f| {
                item.detail = f;
                return item;
            }
            item.ok = false;
            item.hint = "SDL2 not found. Install it: `sudo apt install libsdl2-dev` (Debian/Ubuntu) or `sudo dnf install SDL2-devel` (Fedora). Or set `.gamepad = .none`.";
            return item;
        },
        .macos => {
            if (firstExisting(p, &.{ "/opt/homebrew/lib/libSDL2.dylib", "/usr/local/lib/libSDL2.dylib" })) |f| {
                item.detail = f;
                return item;
            }
            item.ok = false;
            item.hint = "SDL2 not found. Install it: `brew install sdl2`. Or set `.gamepad = .none`.";
            return item;
        },
        else => {
            item.ok = false;
            item.hint = "Unsupported desktop OS for SDL2 detection.";
            return item;
        },
    }
}

/// Windows only: the runtime DLL the `stage` hook copies beside the exe.
pub fn checkDll(a: std.mem.Allocator, io: std.Io, p: Probe, in: Inputs) Item {
    const base: Item = .{ .id = "sdl2-dll", .name = "SDL2.dll for runtime", .ok = true };
    var item = base;
    if (stage.locateDll(a, io, sdl2.dll_name, in.user_lib, in.cache_lib)) |dll| {
        item.detail = std.fmt.allocPrint(a, "{s} (staged beside the game exe after each desktop build)", .{dll}) catch dll;
        return item;
    }
    if (p.on_path(p.ctx, sdl2.dll_name)) |dll| {
        item.detail = dll;
        return item;
    }
    if (in.user_lib == null) return pending(a, base, in);
    item.ok = false;
    item.hint = "SDL2.dll is needed at runtime: none beside LABELLE_SDL2_LIB (lib/ or ../bin) or on PATH.";
    return item;
}

pub fn checkHeaders(a: std.mem.Allocator, p: Probe, in: Inputs) Item {
    const base: Item = .{ .id = "sdl2-headers", .name = "SDL2 headers (sdl backend)", .ok = true };
    var item = base;
    switch (in.os) {
        .windows => {
            for ([_]?[]const u8{ in.user_lib, in.cache_lib }) |maybe| {
                const lib = maybe orelse continue;
                const h = join(a, &.{ lib, "..", "include", "SDL2", "SDL.h" });
                if (p.exists(p.ctx, h)) {
                    item.detail = h;
                    return item;
                }
            }
            if (in.user_lib == null and in.cache_lib == null) return pending(a, base, in);
            item.ok = false;
            item.hint = "SDL2 headers not found. The `sdl` render backend needs the SDL2 dev headers (SDL2/SDL.h) from the MinGW dev package.";
        },
        .linux => {
            if (p.cmd_ok(p.ctx, &.{ "pkg-config", "--cflags", "sdl2" })) {
                item.detail = "pkg-config: sdl2 cflags";
                return item;
            }
            if (p.exists(p.ctx, "/usr/include/SDL2/SDL.h")) {
                item.detail = "/usr/include/SDL2/SDL.h";
                return item;
            }
            item.ok = false;
            item.hint = "SDL2 headers not found. `sudo apt install libsdl2-dev` / `sudo dnf install SDL2-devel`.";
        },
        .macos => {
            if (firstExisting(p, &.{ "/opt/homebrew/include/SDL2/SDL.h", "/usr/local/include/SDL2/SDL.h" })) |f| {
                item.detail = f;
                return item;
            }
            item.ok = false;
            item.hint = "SDL2 headers not found. `brew install sdl2`.";
        },
        else => {
            item.ok = false;
            item.hint = "Unsupported desktop OS for SDL2 detection.";
        },
    }
    return item;
}

/// SDL2_mixer is not provisioned (as in the CLI): on Windows it must come
/// with the user's own `LABELLE_SDL2_LIB`.
pub fn checkMixer(a: std.mem.Allocator, p: Probe, in: Inputs) Item {
    var item: Item = .{ .id = "sdl2-mixer", .name = "SDL2_mixer (sdl backend audio)", .ok = true };
    switch (in.os) {
        .windows => {
            if (in.user_lib) |dir| {
                if (p.exists(p.ctx, join(a, &.{ dir, "libSDL2_mixer.dll.a" }))) {
                    item.detail = dir;
                    return item;
                }
            }
            item.ok = false;
            item.hint = "SDL2_mixer not found. The `sdl` backend's audio needs SDL2_mixer-devel (MinGW): download SDL2_mixer-devel-<ver>-mingw alongside SDL2 and point LABELLE_SDL2_LIB at a lib dir holding both.";
        },
        .linux => {
            if (p.cmd_ok(p.ctx, &.{ "pkg-config", "--exists", "SDL2_mixer" })) {
                item.detail = "pkg-config: SDL2_mixer";
                return item;
            }
            item.ok = false;
            item.hint = "SDL2_mixer not found. `sudo apt install libsdl2-mixer-dev` / `sudo dnf install SDL2_mixer-devel`.";
        },
        .macos => {
            if (firstExisting(p, &.{ "/opt/homebrew/lib/libSDL2_mixer.dylib", "/usr/local/lib/libSDL2_mixer.dylib" })) |f| {
                item.detail = f;
                return item;
            }
            item.ok = false;
            item.hint = "SDL2_mixer not found. `brew install sdl2_mixer`.";
        },
        else => {
            item.ok = false;
            item.hint = "Unsupported desktop OS for SDL2 detection.";
        },
    }
    return item;
}

/// Every row this project needs, in the CLI's order.
pub fn items(a: std.mem.Allocator, io: std.Io, p: Probe, in: Inputs) ![]const Item {
    var list: std.ArrayList(Item) = .empty;
    if (!in.needs) return list.items;
    try list.append(a, checkLib(a, p, in));
    if (in.os == .windows) try list.append(a, checkDll(a, io, p, in));
    if (in.render) {
        try list.append(a, checkHeaders(a, p, in));
        try list.append(a, checkMixer(a, p, in));
    }
    return list.items;
}

pub fn capability(a: std.mem.Allocator, io: std.Io, p: Probe, in: Inputs) !Capability {
    const rows = try items(a, io, p, in);
    var all = true;
    for (rows) |item| all = all and item.ok;
    return .{ .required = in.needs, .ok = all, .items = rows };
}

/// Print the report (or the JSON object); true when every row is ok.
pub fn run(a: std.mem.Allocator, io: std.Io, p: Probe, in: Inputs, json: bool, why: []const u8) !bool {
    const cap = try capability(a, io, p, in);
    if (json) {
        try stdio.json(io, cap);
        return cap.ok;
    }
    std.debug.print("\nlabelle sdl2 doctor ({s})\n", .{why});
    if (!in.needs) std.debug.print("  SDL2 is not needed: nothing to check\n", .{});
    for (cap.items) |item| {
        std.debug.print("  [{s}] {s}\n", .{ if (item.ok) "  OK  " else " FAIL ", item.name });
        if (item.detail) |d| std.debug.print("           {s}\n", .{d});
        if (item.hint) |h| std.debug.print("           -> {s}\n", .{h});
    }
    return cap.ok;
}

// ── The real machine ──────────────────────────────────────────────────────

pub const System = struct {
    io: std.Io,
    a: std.mem.Allocator,
    path_env: ?[]const u8,

    pub fn probe(self: *System) Probe {
        return .{ .ctx = self, .exists = sysExists, .cmd_ok = sysCmdOk, .on_path = sysOnPath };
    }
    fn sysExists(ctx: ?*anyopaque, path: []const u8) bool {
        const self: *System = @ptrCast(@alignCast(ctx.?));
        return sdl2.exists(self.io, path);
    }
    fn sysCmdOk(ctx: ?*anyopaque, argv: []const []const u8) bool {
        const self: *System = @ptrCast(@alignCast(ctx.?));
        return @import("proc.zig").ok(self.io, self.a, argv);
    }
    fn sysOnPath(ctx: ?*anyopaque, name: []const u8) ?[]const u8 {
        const self: *System = @ptrCast(@alignCast(ctx.?));
        var it = std.mem.tokenizeScalar(u8, self.path_env orelse return null, std.fs.path.delimiter);
        while (it.next()) |dir| {
            const p = std.fs.path.join(self.a, &.{ dir, name }) catch continue;
            if (sdl2.exists(self.io, p)) return p;
        }
        return null;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A machine made of a set of existing paths and succeeding commands.
const FakeMachine = struct {
    files: []const []const u8 = &.{},
    commands: []const []const u8 = &.{},
    path_dll: ?[]const u8 = null,

    fn probe(self: *FakeMachine) Probe {
        return .{ .ctx = self, .exists = exists, .cmd_ok = cmdOk, .on_path = onPath };
    }
    fn exists(ctx: ?*anyopaque, path: []const u8) bool {
        const self: *FakeMachine = @ptrCast(@alignCast(ctx.?));
        for (self.files) |f| if (std.mem.eql(u8, f, path)) return true;
        return false;
    }
    fn cmdOk(ctx: ?*anyopaque, argv: []const []const u8) bool {
        const self: *FakeMachine = @ptrCast(@alignCast(ctx.?));
        const joined = std.mem.join(testing.allocator, " ", argv) catch return false;
        defer testing.allocator.free(joined);
        for (self.commands) |c| if (std.mem.eql(u8, c, joined)) return true;
        return false;
    }
    fn onPath(ctx: ?*anyopaque, _: []const u8) ?[]const u8 {
        const self: *FakeMachine = @ptrCast(@alignCast(ctx.?));
        return self.path_dll;
    }
};

fn inputs(os: std.Target.Os.Tag, render: bool) Inputs {
    return .{ .os = os, .needs = true, .render = render, .user_lib = null, .cache_lib = null, .install_dir = "/cache/sdl2-v1/x/2.30.11", .offline = false };
}

fn ids(rows: []const Item) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (rows) |r| {
        if (buf.items.len != 0) try buf.append(testing.allocator, ' ');
        try buf.appendSlice(testing.allocator, r.id);
    }
    return buf.toOwnedSlice(testing.allocator);
}

test "rows are scoped like the CLI: lib always, dll on Windows, headers+mixer for the sdl renderer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m: FakeMachine = .{};
    const cases = [_]struct { os: std.Target.Os.Tag, render: bool, want: []const u8 }{
        .{ .os = .macos, .render = false, .want = "sdl2-lib" },
        .{ .os = .linux, .render = true, .want = "sdl2-lib sdl2-headers sdl2-mixer" },
        .{ .os = .windows, .render = false, .want = "sdl2-lib sdl2-dll" },
        .{ .os = .windows, .render = true, .want = "sdl2-lib sdl2-dll sdl2-headers sdl2-mixer" },
    };
    for (cases) |c| {
        const got = try ids(try items(a, testing.io, m.probe(), inputs(c.os, c.render)));
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
    var none = inputs(.windows, true);
    none.needs = false;
    const cap = try capability(a, testing.io, m.probe(), none);
    try testing.expect(cap.ok and !cap.required and cap.items.len == 0);
}

test "Windows: nothing installed is pending (ok) online, a failure offline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m: FakeMachine = .{};
    var in = inputs(.windows, false);
    var lib = checkLib(a, m.probe(), in);
    try testing.expect(lib.ok and lib.fixable);
    try testing.expectEqualStrings("labelle sdl2 install", lib.action.?);
    try testing.expect(std.mem.indexOf(u8, lib.detail.?, "next desktop build") != null);
    in.offline = true;
    lib = checkLib(a, m.probe(), in);
    try testing.expect(!lib.ok);
    try testing.expect(std.mem.indexOf(u8, lib.hint.?, "LABELLE_OFFLINE") != null);
    try testing.expect(!(try capability(a, testing.io, m.probe(), in)).ok);
}

test "Windows: the user's LABELLE_SDL2_LIB wins and is checked; the cache is next" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const user = "C:/sdl/lib";
    const implib = try std.fs.path.join(a, &.{ user, "libSDL2.dll.a" });
    const mixer = try std.fs.path.join(a, &.{ user, "libSDL2_mixer.dll.a" });
    const header = try std.fs.path.join(a, &.{ user, "..", "include", "SDL2", "SDL.h" });
    var good: FakeMachine = .{ .files = &.{ implib, mixer, header } };
    var in = inputs(.windows, true);
    in.user_lib = user;
    try testing.expect(checkLib(a, good.probe(), in).ok);
    try testing.expect(checkMixer(a, good.probe(), in).ok);
    try testing.expect(checkHeaders(a, good.probe(), in).ok);
    // A user value without the import lib is a failure, not a fallback.
    var bad: FakeMachine = .{};
    in.cache_lib = "C:/cache/lib";
    try testing.expect(!checkLib(a, bad.probe(), in).ok);
    // Without a user value the cache answers, but it has no mixer.
    in.user_lib = null;
    const lib = checkLib(a, bad.probe(), in);
    try testing.expect(lib.ok);
    try testing.expect(std.mem.indexOf(u8, lib.detail.?, "provider cache") != null);
    try testing.expect(!checkMixer(a, bad.probe(), in).ok);
    // The DLL: on PATH counts when nothing else has it.
    var path_dll: FakeMachine = .{ .path_dll = "C:/Windows/SDL2.dll" };
    try testing.expect(checkDll(a, testing.io, path_dll.probe(), in).ok);
    in.user_lib = user;
    try testing.expect(!checkDll(a, testing.io, bad.probe(), in).ok);
}

test "Linux and macOS: pkg-config / system paths / Homebrew, as in the CLI" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pc: FakeMachine = .{ .commands = &.{ "pkg-config --exists sdl2", "pkg-config --cflags sdl2", "pkg-config --exists SDL2_mixer" } };
    const linux = inputs(.linux, true);
    try testing.expect((try capability(a, testing.io, pc.probe(), linux)).ok);
    var so: FakeMachine = .{ .files = &.{"/usr/lib64/libSDL2.so"} };
    try testing.expect(checkLib(a, so.probe(), linux).ok);
    try testing.expect(!checkMixer(a, so.probe(), linux).ok);
    var empty: FakeMachine = .{};
    const miss = checkLib(a, empty.probe(), linux);
    try testing.expect(!miss.ok and std.mem.indexOf(u8, miss.hint.?, "apt install libsdl2-dev") != null);
    const mac = inputs(.macos, true);
    var brew: FakeMachine = .{ .files = &.{ "/opt/homebrew/lib/libSDL2.dylib", "/opt/homebrew/include/SDL2/SDL.h", "/opt/homebrew/lib/libSDL2_mixer.dylib" } };
    try testing.expect((try capability(a, testing.io, brew.probe(), mac)).ok);
    const nobrew = checkLib(a, empty.probe(), mac);
    try testing.expect(!nobrew.ok and std.mem.indexOf(u8, nobrew.hint.?, "brew install sdl2") != null);
}

test "the JSON capability object has the aggregate shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m: FakeMachine = .{ .files = &.{"/opt/homebrew/lib/libSDL2.dylib"} };
    const cap = try capability(a, testing.io, m.probe(), inputs(.macos, false));
    const text = try std.json.Stringify.valueAlloc(a, cap, .{});
    try testing.expect(std.mem.startsWith(u8, text, "{\"id\":\"sdl2\",\"required\":true,\"ok\":true,\"items\":[{\"id\":\"sdl2-lib\""));
    try testing.expect(std.mem.indexOf(u8, text, "\"fixable\":false,\"size_mb\":0,\"action\":null") != null);
}
