//! The `stage` hook (after build, desktop): copy the runtime `SDL2.dll`
//! next to the freshly built game exe, ported from labelle-cli
//! `stageSdl2DllBesideExe` (cli#285).
//!
//! The Windows loader resolves a process's implicitly linked DLLs from the
//! exe's own directory first. The build installs the exe into
//! `<target_dir>/zig-out/bin/` but nothing puts `SDL2.dll` there, so the
//! launch fails with a bare `FileNotFound`. PATH (the env hook's
//! `path_prepend`) is consulted only after the exe's directory, never
//! reaches the game the core `labelle run` launches, and a user-provided
//! `LABELLE_SDL2_LIB` is not on PATH at all; a copy beside the exe covers
//! every launch.
//!
//! The DLL is looked up where the build linked it from: the hook inherits
//! the build's merged environment (contract §2 "Scope"), so its
//! `LABELLE_SDL2_LIB` is the env hook's contribution or the user's value.
const std = @import("std");
const sdl2 = @import("sdl2.zig");

/// Locate a runtime `SDL2.dll`, mirroring the linker's own resolution:
///   1. `<lib>/SDL2.dll`         (the provisioner puts the DLL in lib/)
///   2. `<lib>/../bin/SDL2.dll`  (the upstream MinGW package layout)
///   3. the provider cache's lib dir (`cache_lib`)
/// where `<lib>` is `LABELLE_SDL2_LIB` as the build saw it.
pub fn locateDll(a: std.mem.Allocator, io: std.Io, lib_dir: ?[]const u8, cache_lib: ?[]const u8) ?[]const u8 {
    if (lib_dir) |lib| if (lib.len > 0) {
        const in_lib = std.fs.path.join(a, &.{ lib, sdl2.dll_name }) catch return null;
        if (sdl2.exists(io, in_lib)) return in_lib;
        const in_bin = std.fs.path.join(a, &.{ lib, "..", "bin", sdl2.dll_name }) catch return null;
        if (sdl2.exists(io, in_bin)) return in_bin;
    };
    if (cache_lib) |lib| {
        const p = std.fs.path.join(a, &.{ lib, sdl2.dll_name }) catch return null;
        if (sdl2.exists(io, p)) return p;
    }
    return null;
}

pub const Outcome = union(enum) {
    /// Copied from this source.
    staged: []const u8,
    /// A DLL is already beside the exe; left in place.
    already_there,
    /// No `<target_dir>/zig-out/bin` (nothing was installed there).
    no_bin_dir,
    /// No SDL2.dll could be located.
    not_found,
};

/// Stage `SDL2.dll` into `bin_dir`. A copy that fails after a DLL was
/// located is an error: the exe beside it would not start.
pub fn stageDll(a: std.mem.Allocator, io: std.Io, bin_dir: []const u8, lib_dir: ?[]const u8, cache_lib: ?[]const u8) !Outcome {
    if (!sdl2.exists(io, bin_dir)) return .no_bin_dir;
    const dst = try std.fs.path.join(a, &.{ bin_dir, sdl2.dll_name });
    if (sdl2.exists(io, dst)) return .already_there;
    const src = locateDll(a, io, lib_dir, cache_lib) orelse return .not_found;
    const cwd = std.Io.Dir.cwd();
    cwd.copyFile(src, cwd, dst, io, .{}) catch |err| {
        std.debug.print("labelle-sdl2: found {s} but could not copy it to {s}: {s}\n", .{ src, dst, @errorName(err) });
        return error.Sdl2StageFailed;
    };
    return .{ .staged = src };
}

/// `<target_dir>/zig-out/bin`: where the desktop build installs the exe.
pub fn binDir(a: std.mem.Allocator, target_dir: []const u8) ![]const u8 {
    return std.fs.path.join(a, &.{ target_dir, "zig-out", "bin" });
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

fn touch(io: std.Io, a: std.mem.Allocator, parts: []const []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(a, parts);
    if (std.fs.path.dirname(path)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

test "the DLL is found in lib/, then lib/../bin, then the provider cache" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    // A contributed install whose lib/ holds the DLL.
    const contributed = try std.fs.path.join(a, &.{ root, "contributed", "lib" });
    try touch(io, a, &.{ contributed, "SDL2.dll" }, "dll");
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ contributed, "SDL2.dll" }), locateDll(a, io, contributed, null).?);
    // The upstream layout: lib/../bin/SDL2.dll.
    const upstream = try std.fs.path.join(a, &.{ root, "upstream", "lib" });
    try std.Io.Dir.cwd().createDirPath(io, upstream);
    try touch(io, a, &.{ root, "upstream", "bin", "SDL2.dll" }, "dll");
    try testing.expect(std.mem.endsWith(u8, locateDll(a, io, upstream, null).?, "SDL2.dll"));
    // Nothing at LABELLE_SDL2_LIB (or unset / empty): the cache.
    const cache = try std.fs.path.join(a, &.{ root, "cache", "lib" });
    try touch(io, a, &.{ cache, "SDL2.dll" }, "dll");
    const empty = try std.fs.path.join(a, &.{ root, "empty" });
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ cache, "SDL2.dll" }), locateDll(a, io, empty, cache).?);
    try testing.expect(locateDll(a, io, null, cache) != null);
    try testing.expect(locateDll(a, io, "", cache) != null);
    try testing.expect(locateDll(a, io, empty, null) == null);
}

test "stageDll copies beside the exe once and never overwrites a staged DLL" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const target_dir = try std.fs.path.join(a, &.{ root, ".labelle", "bgfx_desktop" });
    const bin = try binDir(a, target_dir);
    const lib = try std.fs.path.join(a, &.{ root, "sdl", "lib" });
    try touch(io, a, &.{ lib, "SDL2.dll" }, "the dll");
    // No bin dir yet: nothing to stage into.
    try testing.expectEqual(Outcome.no_bin_dir, try stageDll(a, io, bin, lib, null));
    try touch(io, a, &.{ bin, "game.exe" }, "exe");
    // No DLL anywhere: reported, not an error.
    try testing.expectEqual(Outcome.not_found, try stageDll(a, io, bin, null, null));
    const out = try stageDll(a, io, bin, lib, null);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ lib, "SDL2.dll" }), out.staged);
    const staged = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ bin, "SDL2.dll" }), a, .limited(64));
    try testing.expectEqualStrings("the dll", staged);
    // Already there: left in place, even if the source changed.
    try touch(io, a, &.{ lib, "SDL2.dll" }, "a newer dll");
    try testing.expectEqual(Outcome.already_there, try stageDll(a, io, bin, lib, null));
}
