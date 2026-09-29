//! The `env` hook's environment contribution (contract §2 "Environment
//! contributions"): `LABELLE_SDL2_LIB`, the variable labelle-bgfx,
//! labelle-raylib, labelle-sokol and labelle-sdl read on Windows, plus the
//! same directory (it holds `SDL2.dll`) in front of PATH — what the CLI's
//! `autoWireEnv` set, now carried by the hook instead of the CLI process.
const std = @import("std");

pub const var_name = "LABELLE_SDL2_LIB";

pub const EnvVar = struct { name: []const u8, value: []const u8 };

pub const Contribution = struct {
    set: []const EnvVar,
    path_prepend: []const []const u8,
};

pub fn contribution(a: std.mem.Allocator, lib_dir: []const u8) !Contribution {
    const set = try a.alloc(EnvVar, 1);
    set[0] = .{ .name = var_name, .value = lib_dir };
    return .{ .set = set, .path_prepend = try a.dupe([]const u8, &.{lib_dir}) };
}

/// Write the contribution for `lib_dir` (absolute) to `env_file`.
pub fn writeEnvFile(a: std.mem.Allocator, io: std.Io, env_file: []const u8, lib_dir: []const u8) !void {
    if (!std.fs.path.isAbsolute(lib_dir)) return error.RelativeLibDir;
    const bytes = try std.json.Stringify.valueAlloc(a, try contribution(a, lib_dir), .{});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = env_file, .data = bytes });
}

/// The user's own `LABELLE_SDL2_LIB`, when set and non-empty. It wins, as
/// in the CLI: the hook then contributes nothing, so the inherited value
/// reaches the build unchanged.
pub fn userLibDir(environ: *const std.process.Environ.Map) ?[]const u8 {
    const value = environ.get(var_name) orelse return null;
    return if (value.len == 0) null else value;
}

/// `LABELLE_OFFLINE` set to anything but empty or `0` (the CLI's and
/// labelle-web's rule).
pub fn offline(environ: *const std.process.Environ.Map) bool {
    const value = environ.get("LABELLE_OFFLINE") orelse return false;
    return value.len != 0 and !std.mem.eql(u8, value, "0");
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "the env_file sets LABELLE_SDL2_LIB and prepends the same dir, in contract shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const file = try std.fs.path.join(a, &.{ root, "env.json" });
    const lib = try std.fs.path.join(a, &.{ root, "SDL2-2.30.11", "x86_64-w64-mingw32", "lib" });
    try writeEnvFile(a, io, file, lib);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(4096));
    // Strict decode, as the CLI does: exactly `set` and `path_prepend`, and
    // each `set` entry exactly `name` and `value`.
    const parsed = try std.json.parseFromSliceLeaky(Contribution, a, bytes, .{});
    try testing.expectEqual(@as(usize, 1), parsed.set.len);
    try testing.expectEqualStrings("LABELLE_SDL2_LIB", parsed.set[0].name);
    try testing.expectEqualStrings(lib, parsed.set[0].value);
    try testing.expectEqual(@as(usize, 1), parsed.path_prepend.len);
    try testing.expectEqualStrings(lib, parsed.path_prepend[0]);
    // A PATH entry never carries the separator, and is absolute.
    try testing.expect(std.mem.indexOfScalar(u8, parsed.path_prepend[0], std.fs.path.delimiter) == null);
    try testing.expectError(error.RelativeLibDir, writeEnvFile(a, io, file, "relative/lib"));
}

test "a user-set LABELLE_SDL2_LIB wins; empty counts as unset" {
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();
    try testing.expect(userLibDir(&map) == null);
    try map.put("LABELLE_SDL2_LIB", "");
    try testing.expect(userLibDir(&map) == null);
    try map.put("LABELLE_SDL2_LIB", "C:/sdl/lib");
    try testing.expectEqualStrings("C:/sdl/lib", userLibDir(&map).?);
}

test "LABELLE_OFFLINE" {
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();
    try testing.expect(!offline(&map));
    for ([_][]const u8{ "", "0" }) |v| {
        try map.put("LABELLE_OFFLINE", v);
        try testing.expect(!offline(&map));
    }
    try map.put("LABELLE_OFFLINE", "1");
    try testing.expect(offline(&map));
}
