//! The `stage` hook (after build, desktop): copy the runtime `SDL2.dll`
//! (and, for the `sdl` render backend, `SDL2_mixer.dll`) next to the
//! freshly built game exe, ported from labelle-cli `stageSdl2DllBesideExe`
//! (cli#285).
//!
//! The Windows loader resolves a process's implicitly linked DLLs from the
//! exe's own directory first. The build installs the exe into
//! `<target_dir>/zig-out/bin/` but nothing puts the DLLs there, so the
//! launch fails with a bare `FileNotFound`. PATH (the env hook's
//! `path_prepend`) is consulted only after the exe's directory, never
//! reaches the game the core `labelle run` launches, and a user-provided
//! `LABELLE_SDL2_LIB` is not on PATH at all; a copy beside the exe covers
//! every launch.
//!
//! The DLLs are looked up where the build linked from: the hook inherits
//! the build's merged environment (contract §2 "Scope"), so its
//! `LABELLE_SDL2_LIB` is the env hook's contribution or the user's value.
//! A staged copy is replaced whenever it differs from that source (a
//! switched SDL2 install, a new pin), so the exe never runs a stale DLL.
const std = @import("std");
const sdl2 = @import("sdl2.zig");

/// The SDL2_mixer runtime the `sdl` backend's audio links. Not provisioned:
/// it comes with the user's `LABELLE_SDL2_LIB` package. Only this one DLL
/// is staged: the official SDL2_mixer MinGW package (2.8.0, the one the CI
/// uses) ships `SDL2_mixer.dll` alone in `bin/`, its codecs built in, and
/// copying "every DLL beside it" would sweep a whole MSYS2 `bin/`.
pub const mixer_dll_name = "SDL2_mixer.dll";

/// Locate the runtime DLL `name`, mirroring the linker's own resolution:
///   1. `<lib>/<name>`         (the provisioner puts SDL2.dll in lib/)
///   2. `<lib>/../bin/<name>`  (the upstream MinGW package layout)
///   3. the provider cache's lib dir (`cache_lib`), only when no `<lib>`
///      is active
/// where `<lib>` is `LABELLE_SDL2_LIB` as the build saw it. With a `<lib>`
/// the exe linked that package's import lib, so a cached DLL of another
/// SDL2 release must not stand in for it: none found there is null (the
/// runtime then comes from PATH).
pub fn locateDll(a: std.mem.Allocator, io: std.Io, name: []const u8, lib_dir: ?[]const u8, cache_lib: ?[]const u8) ?[]const u8 {
    if (lib_dir) |lib| if (lib.len > 0) {
        const in_lib = std.fs.path.join(a, &.{ lib, name }) catch return null;
        if (sdl2.exists(io, in_lib)) return in_lib;
        const in_bin = std.fs.path.join(a, &.{ lib, "..", "bin", name }) catch return null;
        if (sdl2.exists(io, in_bin)) return in_bin;
        return null;
    };
    if (cache_lib) |lib| {
        const p = std.fs.path.join(a, &.{ lib, name }) catch return null;
        if (sdl2.exists(io, p)) return p;
    }
    return null;
}

pub const Outcome = union(enum) {
    /// Copied (new or replaced) from this source.
    staged: []const u8,
    /// The DLL beside the exe already equals the source.
    up_to_date,
    /// No `<target_dir>/zig-out/bin` (nothing was installed there).
    no_bin_dir,
    /// The DLL could not be located (nothing of ours is left beside the exe).
    not_found,
    /// The DLL could not be located, and the copy this provider staged by an
    /// earlier build was removed so it cannot shadow PATH.
    removed_stale,
    /// The DLL beside the exe is not the one this provider staged (the user
    /// put or replaced it): left alone.
    user_owned,
    /// The DLL beside the exe exists but could not be read (hashed): left
    /// alone, since its content is unknown.
    unreadable,
};

/// `<bin>/.<name>.labelle-sdl2`: written beside every DLL this provider
/// stages, recording the staged content (`<size> <sha256>`), so a later
/// build replaces or removes only a copy that is still exactly what it
/// staged — never a DLL the user put there or replaced.
fn markerPath(a: std.mem.Allocator, bin_dir: []const u8, name: []const u8) ![]const u8 {
    const file = try std.fmt.allocPrint(a, ".{s}.labelle-sdl2", .{name});
    return std.fs.path.join(a, &.{ bin_dir, file });
}

/// DLLs are a few MB; this is ample headroom.
const max_dll_bytes = 256 * 1024 * 1024;

/// The identity of `path` (`<size> <sha256>`), or null when it can't be read.
fn digestOf(a: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(max_dll_bytes)) catch return null;
    defer a.free(bytes);
    var sum: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &sum, .{});
    return std.fmt.allocPrint(a, "{d} {s}", .{ bytes.len, &std.fmt.bytesToHex(sum, .lower) }) catch null;
}

/// What the marker says was staged, or null (absent, or an older format).
fn recorded(a: std.mem.Allocator, io: std.Io, marker: []const u8) ?[]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, marker, a, .limited(256)) catch return null;
    return std.mem.trim(u8, bytes, " \t\r\n");
}

fn eqlOpt(x: ?[]const u8, y: ?[]const u8) bool {
    return x != null and y != null and std.mem.eql(u8, x.?, y.?);
}

/// Stage the DLL `name` into `bin_dir`. A destination is only ever
/// replaced or removed while it still matches what the marker recorded;
/// otherwise it is the user's and stays. Copies are atomic (`copyFile`
/// renames a complete temporary file over it). A copy that fails after the
/// DLL was located is an error: the exe beside it would not start.
pub fn stageDll(a: std.mem.Allocator, io: std.Io, bin_dir: []const u8, name: []const u8, lib_dir: ?[]const u8, cache_lib: ?[]const u8) !Outcome {
    if (!sdl2.exists(io, bin_dir)) return .no_bin_dir;
    const dst = try std.fs.path.join(a, &.{ bin_dir, name });
    const marker = try markerPath(a, bin_dir, name);
    const cwd = std.Io.Dir.cwd();
    const staged = recorded(a, io, marker);
    const present = sdl2.exists(io, dst);
    const current = if (present) digestOf(a, io, dst) else null;
    // Present but unreadable: its content is unknown, so never touch it.
    if (present and current == null) {
        std.debug.print("labelle-sdl2: warning: could not read {s}; left as is\n", .{dst});
        return .unreadable;
    }
    const ours = eqlOpt(staged, current);
    // A marker that no longer describes the destination (replaced, or the
    // DLL gone) proves nothing any more: drop it, whatever happens next.
    if (staged != null and !ours) cwd.deleteFile(io, marker) catch {};
    const src = locateDll(a, io, name, lib_dir, cache_lib) orelse {
        if (!present) return .not_found;
        if (!ours) return if (staged != null) .user_owned else .not_found;
        cwd.deleteFile(io, dst) catch |err| {
            std.debug.print("labelle-sdl2: could not remove the stale {s}: {s}\n", .{ dst, @errorName(err) });
            return error.Sdl2StageFailed;
        };
        cwd.deleteFile(io, marker) catch {};
        return .removed_stale;
    };
    const wanted = digestOf(a, io, src) orelse return error.Sdl2StageFailed;
    // Equal to the source: nothing to do. An unmarked identical copy is
    // the user's and stays unmarked (it is never claimed).
    if (eqlOpt(current, wanted)) return .up_to_date;
    if (present and !ours) return .user_owned;
    cwd.copyFile(src, cwd, dst, io, .{}) catch |err| {
        std.debug.print("labelle-sdl2: found {s} but could not copy it to {s}: {s}\n", .{ src, dst, @errorName(err) });
        return error.Sdl2StageFailed;
    };
    try cwd.writeFile(io, .{ .sub_path = marker, .data = wanted });
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

test "a DLL is found in lib/, then lib/../bin, then the provider cache" {
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
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ contributed, "SDL2.dll" }), locateDll(a, io, sdl2.dll_name, contributed, null).?);
    // The upstream layout: lib/../bin/<name>, for SDL2 and SDL2_mixer alike.
    const upstream = try std.fs.path.join(a, &.{ root, "upstream", "lib" });
    try std.Io.Dir.cwd().createDirPath(io, upstream);
    try touch(io, a, &.{ root, "upstream", "bin", "SDL2.dll" }, "dll");
    try touch(io, a, &.{ root, "upstream", "bin", "SDL2_mixer.dll" }, "mixer");
    try testing.expect(std.mem.endsWith(u8, locateDll(a, io, sdl2.dll_name, upstream, null).?, "SDL2.dll"));
    try testing.expect(std.mem.endsWith(u8, locateDll(a, io, mixer_dll_name, upstream, null).?, "SDL2_mixer.dll"));
    // LABELLE_SDL2_LIB unset or empty: the cache.
    const cache = try std.fs.path.join(a, &.{ root, "cache", "lib" });
    try touch(io, a, &.{ cache, "SDL2.dll" }, "dll");
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ cache, "SDL2.dll" }), locateDll(a, io, sdl2.dll_name, null, cache).?);
    try testing.expect(locateDll(a, io, sdl2.dll_name, "", cache) != null);
    // An active LABELLE_SDL2_LIB without the DLL never falls back to the
    // cache (another SDL2 release than the linked import lib).
    const empty = try std.fs.path.join(a, &.{ root, "empty" });
    try testing.expect(locateDll(a, io, sdl2.dll_name, empty, cache) == null);
    try testing.expect(locateDll(a, io, sdl2.dll_name, empty, null) == null);
    // The cache has no mixer.
    try testing.expect(locateDll(a, io, mixer_dll_name, null, cache) == null);
}

test "stageDll copies beside the exe, keeps an identical copy and replaces a stale one" {
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
    const staged_path = try std.fs.path.join(a, &.{ bin, "SDL2.dll" });
    try touch(io, a, &.{ lib, "SDL2.dll" }, "the dll");
    // No bin dir yet: nothing to stage into.
    try testing.expectEqual(Outcome.no_bin_dir, try stageDll(a, io, bin, sdl2.dll_name, lib, null));
    try touch(io, a, &.{ bin, "game.exe" }, "exe");
    // No DLL anywhere: reported, not an error.
    try testing.expectEqual(Outcome.not_found, try stageDll(a, io, bin, sdl2.dll_name, null, null));
    // A DLL the user put there (no marker) is never removed.
    try touch(io, a, &.{ bin, "SDL2.dll" }, "user's own");
    try testing.expectEqual(Outcome.not_found, try stageDll(a, io, bin, sdl2.dll_name, null, null));
    try testing.expect(sdl2.exists(io, staged_path));
    try std.Io.Dir.cwd().deleteFile(io, staged_path);
    // A user lib dir without the DLL: nothing staged, even with a cached one.
    const cache = try std.fs.path.join(a, &.{ root, "cache", "lib" });
    try touch(io, a, &.{ cache, "SDL2.dll" }, "cached dll");
    const no_dll = try std.fs.path.join(a, &.{ root, "user-without-dll", "lib" });
    try testing.expectEqual(Outcome.not_found, try stageDll(a, io, bin, sdl2.dll_name, no_dll, cache));
    try testing.expect(!sdl2.exists(io, staged_path));
    const out = try stageDll(a, io, bin, sdl2.dll_name, lib, null);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ lib, "SDL2.dll" }), out.staged);
    try testing.expectEqualStrings("the dll", try std.Io.Dir.cwd().readFileAlloc(io, staged_path, a, .limited(64)));
    // Identical: left alone.
    try testing.expectEqual(Outcome.up_to_date, try stageDll(a, io, bin, sdl2.dll_name, lib, null));
    // The source changed (same size, other bytes; then another size): replaced.
    try touch(io, a, &.{ lib, "SDL2.dll" }, "THE DLL");
    _ = (try stageDll(a, io, bin, sdl2.dll_name, lib, null)).staged;
    try testing.expectEqualStrings("THE DLL", try std.Io.Dir.cwd().readFileAlloc(io, staged_path, a, .limited(64)));
    try touch(io, a, &.{ lib, "SDL2.dll" }, "a newer, larger dll");
    _ = (try stageDll(a, io, bin, sdl2.dll_name, lib, null)).staged;
    try testing.expectEqualStrings("a newer, larger dll", try std.Io.Dir.cwd().readFileAlloc(io, staged_path, a, .limited(64)));
    // The selected SDK loses its DLL: our staged copy is removed (with its
    // marker), so PATH is consulted again.
    try std.Io.Dir.cwd().deleteFile(io, try std.fs.path.join(a, &.{ lib, "SDL2.dll" }));
    try testing.expectEqual(Outcome.removed_stale, try stageDll(a, io, bin, sdl2.dll_name, lib, null));
    try testing.expect(!sdl2.exists(io, staged_path));
    try testing.expectEqual(Outcome.not_found, try stageDll(a, io, bin, sdl2.dll_name, lib, null));
}

test "a staged DLL the user replaced is neither overwritten nor deleted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const bin = try std.fs.path.join(a, &.{ root, "bin" });
    const lib = try std.fs.path.join(a, &.{ root, "sdl", "lib" });
    const dst = try std.fs.path.join(a, &.{ bin, "SDL2.dll" });
    const marker = try markerPath(a, bin, "SDL2.dll");
    try touch(io, a, &.{ bin, "game.exe" }, "exe");
    try touch(io, a, &.{ lib, "SDL2.dll" }, "provider dll");
    _ = (try stageDll(a, io, bin, sdl2.dll_name, lib, null)).staged;
    // The marker records the staged size and SHA-256.
    const rec = try std.Io.Dir.cwd().readFileAlloc(io, marker, a, .limited(256));
    try testing.expect(std.mem.startsWith(u8, rec, "12 "));
    try testing.expectEqual(@as(usize, 3 + 64), rec.len);
    // The user swaps in their own build: a changed source doesn't overwrite it.
    try touch(io, a, &.{ bin, "SDL2.dll" }, "user's patched dll");
    try touch(io, a, &.{ lib, "SDL2.dll" }, "provider dll v2");
    try testing.expectEqual(Outcome.user_owned, try stageDll(a, io, bin, sdl2.dll_name, lib, null));
    try testing.expectEqualStrings("user's patched dll", try std.Io.Dir.cwd().readFileAlloc(io, dst, a, .limited(64)));
    // The marker no longer applies and is gone; a vanished source then
    // doesn't delete the user's DLL either.
    try testing.expect(!sdl2.exists(io, marker));
    try std.Io.Dir.cwd().deleteFile(io, try std.fs.path.join(a, &.{ lib, "SDL2.dll" }));
    try testing.expectEqual(Outcome.not_found, try stageDll(a, io, bin, sdl2.dll_name, lib, null));
    try testing.expect(sdl2.exists(io, dst));
    // An older-format marker (the source path) proves nothing: left alone.
    try touch(io, a, &.{ lib, "SDL2.dll" }, "provider dll v3");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "C:/old/lib/SDL2.dll" });
    try testing.expectEqual(Outcome.user_owned, try stageDll(a, io, bin, sdl2.dll_name, lib, null));
    try testing.expectEqualStrings("user's patched dll", try std.Io.Dir.cwd().readFileAlloc(io, dst, a, .limited(64)));
}

test "an identical copy the user put there is never claimed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const bin = try std.fs.path.join(a, &.{ root, "bin" });
    const lib = try std.fs.path.join(a, &.{ root, "sdl", "lib" });
    const dst = try std.fs.path.join(a, &.{ bin, "SDL2.dll" });
    const marker = try markerPath(a, bin, "SDL2.dll");
    try touch(io, a, &.{ lib, "SDL2.dll" }, "same dll");
    try touch(io, a, &.{ bin, "SDL2.dll" }, "same dll");
    try testing.expectEqual(Outcome.up_to_date, try stageDll(a, io, bin, sdl2.dll_name, lib, null));
    try testing.expect(!sdl2.exists(io, marker));
    // So a vanished source leaves it too, and a changed one doesn't replace it.
    try touch(io, a, &.{ lib, "SDL2.dll" }, "newer dll");
    try testing.expectEqual(Outcome.user_owned, try stageDll(a, io, bin, sdl2.dll_name, lib, null));
    try std.Io.Dir.cwd().deleteFile(io, try std.fs.path.join(a, &.{ lib, "SDL2.dll" }));
    try testing.expectEqual(Outcome.not_found, try stageDll(a, io, bin, sdl2.dll_name, lib, null));
    try testing.expectEqualStrings("same dll", try std.Io.Dir.cwd().readFileAlloc(io, dst, a, .limited(64)));
}

test "a replaced DLL loses its marker on every path, the identical one included" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const bin = try std.fs.path.join(a, &.{ root, "bin" });
    const lib = try std.fs.path.join(a, &.{ root, "sdl", "lib" });
    const marker = try markerPath(a, bin, "SDL2.dll");
    try touch(io, a, &.{ lib, "SDL2.dll" }, "provider dll");
    try std.Io.Dir.cwd().createDirPath(io, bin);
    // Replaced by a file differing from the source: user_owned, marker gone.
    _ = (try stageDll(a, io, bin, sdl2.dll_name, lib, null)).staged;
    try touch(io, a, &.{ bin, "SDL2.dll" }, "user dll");
    try testing.expectEqual(Outcome.user_owned, try stageDll(a, io, bin, sdl2.dll_name, lib, null));
    try testing.expect(!sdl2.exists(io, marker));
    // Replaced by a copy equal to a newer source: up_to_date, marker gone.
    try std.Io.Dir.cwd().deleteFile(io, try std.fs.path.join(a, &.{ bin, "SDL2.dll" }));
    _ = (try stageDll(a, io, bin, sdl2.dll_name, lib, null)).staged;
    try touch(io, a, &.{ lib, "SDL2.dll" }, "provider v2");
    try touch(io, a, &.{ bin, "SDL2.dll" }, "provider v2");
    try testing.expectEqual(Outcome.up_to_date, try stageDll(a, io, bin, sdl2.dll_name, lib, null));
    try testing.expect(!sdl2.exists(io, marker));
    // The staged DLL deleted by hand: the marker goes with it.
    try std.Io.Dir.cwd().deleteFile(io, try std.fs.path.join(a, &.{ bin, "SDL2.dll" }));
    _ = (try stageDll(a, io, bin, sdl2.dll_name, lib, null)).staged;
    try std.Io.Dir.cwd().deleteFile(io, try std.fs.path.join(a, &.{ bin, "SDL2.dll" }));
    try std.Io.Dir.cwd().deleteFile(io, try std.fs.path.join(a, &.{ lib, "SDL2.dll" }));
    try testing.expectEqual(Outcome.not_found, try stageDll(a, io, bin, sdl2.dll_name, lib, null));
    try testing.expect(!sdl2.exists(io, marker));
}

test "a destination that can't be read is never replaced or deleted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const bin = try std.fs.path.join(a, &.{ root, "bin" });
    const lib = try std.fs.path.join(a, &.{ root, "sdl", "lib" });
    const dst = try std.fs.path.join(a, &.{ bin, "SDL2.dll" });
    const marker = try markerPath(a, bin, "SDL2.dll");
    try touch(io, a, &.{ lib, "SDL2.dll" }, "provider dll");
    // A destination that exists but can't be hashed (here a directory).
    try touch(io, a, &.{ dst, "inside" }, "x");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = "12 0000" });
    try testing.expectEqual(Outcome.unreadable, try stageDll(a, io, bin, sdl2.dll_name, lib, null));
    try std.Io.Dir.cwd().deleteFile(io, try std.fs.path.join(a, &.{ lib, "SDL2.dll" }));
    try testing.expectEqual(Outcome.unreadable, try stageDll(a, io, bin, sdl2.dll_name, lib, null));
    try testing.expect(sdl2.exists(io, try std.fs.path.join(a, &.{ dst, "inside" })));
}
