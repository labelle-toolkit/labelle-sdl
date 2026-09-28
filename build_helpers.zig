//! Build-script helpers for the SDL2 backend. Extracted from build.zig
//! so the path-detection logic can be exercised by unit tests with an
//! injected filesystem probe instead of relying on the real /opt/homebrew
//! layout (which only exists on macOS dev boxes).
const std = @import("std");

/// Probe function signature. Returns true if the given path exists.
pub const ProbeFn = *const fn (path: []const u8) bool;

/// Resolve an SDL2 install prefix given a target OS, the host OS this
/// build script is running on, and a filesystem probe.
///
/// Only returns a non-empty prefix when `target_os == host_os` — the
/// probes inspect the host filesystem, and their results are only
/// meaningful when the host is also the target. Cross-compilation
/// must pass `-Dsdl-prefix=<target-sdl2-root>` explicitly.
///
/// On macOS, tries `/opt/homebrew` (Apple Silicon Homebrew) first,
/// then `/usr/local` (Intel Homebrew / manual installs). On Linux and
/// Windows, returns an empty string — SDL2 headers and libraries live
/// in system paths that Zig's default C search resolves on its own.
pub fn detectSdlPrefix(
    target_os: std.Target.Os.Tag,
    host_os: std.Target.Os.Tag,
    probe: ProbeFn,
) []const u8 {
    if (target_os != host_os) return "";
    if (target_os != .macos) return "";
    if (probe("/opt/homebrew/include/SDL2")) return "/opt/homebrew";
    if (probe("/usr/local/include/SDL2")) return "/usr/local";
    return "";
}

/// Library + include dirs derived from `LABELLE_SDL2_LIB`.
pub const EnvSdlPaths = struct {
    /// The dir holding the import lib (`libSDL2.dll.a`) — the env value
    /// as-is, exactly like the other backends pass it to the linker.
    lib: []const u8,
    /// `<lib>/../include` — the MinGW devel layout keeps `SDL2/SDL.h` there.
    /// Null when `lib` has no parent (a drive root or a bare relative name).
    include: ?[]const u8,
};

/// Honour `LABELLE_SDL2_LIB` the same way labelle-bgfx / labelle-raylib /
/// labelle-sokol do: only for a Windows target built on a Windows host
/// (Zig has no default SDL2 search path for the MinGW `windows-gnu`
/// toolchain), and only when the variable is set and non-empty. The value
/// is the dir holding `libSDL2.dll.a` (the SDL2 MinGW devel package's
/// `x86_64-w64-mingw32/lib`, which is what `labelle` provisions). Unlike
/// those backends, this one `@cImport`s the SDL headers, so the sibling
/// `include` dir is returned too. Returns null when the env var is not in
/// play; the caller then keeps its `-Dsdl-prefix` / system-search path.
pub fn envSdlPaths(
    allocator: std.mem.Allocator,
    target_os: std.Target.Os.Tag,
    host_os: std.Target.Os.Tag,
    env_value: ?[]const u8,
) error{OutOfMemory}!?EnvSdlPaths {
    if (target_os != .windows or host_os != .windows) return null;
    const lib = env_value orelse return null;
    if (lib.len == 0) return null;
    // Always a Windows path here, so split it with the Windows rules on any
    // host (the unit tests run on Linux/macOS CI too). `dirnameWindows`
    // ignores trailing separators and keeps a drive root's separator.
    const parent = std.fs.path.dirnameWindows(lib) orelse return .{ .lib = lib, .include = null };
    const sep: []const u8 = if (std.mem.endsWith(u8, parent, "\\") or std.mem.endsWith(u8, parent, "/")) "" else "\\";
    const include = try std.mem.concat(allocator, u8, &.{ parent, sep, "include" });
    return .{ .lib = lib, .include = include };
}

// ── Test fakes ───────────────────────────────────────────────────────

fn probeAlways(_: []const u8) bool {
    return true;
}

fn probeNever(_: []const u8) bool {
    return false;
}

fn probeOnlyAppleSilicon(path: []const u8) bool {
    return std.mem.eql(u8, path, "/opt/homebrew/include/SDL2");
}

fn probeOnlyIntel(path: []const u8) bool {
    return std.mem.eql(u8, path, "/usr/local/include/SDL2");
}

// ── Tests ────────────────────────────────────────────────────────────

test "detectSdlPrefix: cross-compile macos→linux returns empty even if host has Brew" {
    try std.testing.expectEqualStrings("", detectSdlPrefix(.linux, .macos, probeAlways));
}

test "detectSdlPrefix: cross-compile linux→macos returns empty even if probe says yes" {
    // This is the class of bug Cursor Bugbot flagged on PR #15: probing
    // the host fs for target-specific paths silently gives wrong answers.
    try std.testing.expectEqualStrings("", detectSdlPrefix(.macos, .linux, probeAlways));
}

test "detectSdlPrefix: linux host/target returns empty (system search)" {
    try std.testing.expectEqualStrings("", detectSdlPrefix(.linux, .linux, probeAlways));
}

test "detectSdlPrefix: windows host/target returns empty" {
    try std.testing.expectEqualStrings("", detectSdlPrefix(.windows, .windows, probeAlways));
}

test "detectSdlPrefix: macos host/target picks Apple Silicon Brew when both available" {
    try std.testing.expectEqualStrings("/opt/homebrew", detectSdlPrefix(.macos, .macos, probeAlways));
}

test "detectSdlPrefix: macos host/target picks Apple Silicon when only Apple Silicon present" {
    try std.testing.expectEqualStrings("/opt/homebrew", detectSdlPrefix(.macos, .macos, probeOnlyAppleSilicon));
}

test "detectSdlPrefix: macos host/target falls back to Intel Brew" {
    try std.testing.expectEqualStrings("/usr/local", detectSdlPrefix(.macos, .macos, probeOnlyIntel));
}

test "detectSdlPrefix: macos host/target with no SDL2 returns empty" {
    try std.testing.expectEqualStrings("", detectSdlPrefix(.macos, .macos, probeNever));
}

test "envSdlPaths: windows host/target derives lib + sibling include" {
    const a = std.testing.allocator;
    const got = (try envSdlPaths(a, .windows, .windows, "C:\\sdl2\\x86_64-w64-mingw32\\lib")).?;
    defer if (got.include) |p| a.free(p);
    try std.testing.expectEqualStrings("C:\\sdl2\\x86_64-w64-mingw32\\lib", got.lib);
    try std.testing.expectEqualStrings("C:\\sdl2\\x86_64-w64-mingw32\\include", got.include.?);
}

test "envSdlPaths: forward slashes and a trailing separator are accepted" {
    const a = std.testing.allocator;
    const got = (try envSdlPaths(a, .windows, .windows, "C:/sdl2/lib/")).?;
    defer if (got.include) |p| a.free(p);
    // The lib dir is passed through untouched, like the other backends do.
    try std.testing.expectEqualStrings("C:/sdl2/lib/", got.lib);
    try std.testing.expectEqualStrings("C:/sdl2\\include", got.include.?);
}

test "envSdlPaths: lib dir directly under a drive root keeps one separator" {
    const a = std.testing.allocator;
    const got = (try envSdlPaths(a, .windows, .windows, "D:\\lib")).?;
    defer if (got.include) |p| a.free(p);
    try std.testing.expectEqualStrings("D:\\include", got.include.?);
}

test "envSdlPaths: a drive root itself is kept as-is and has no sibling include" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "C:\\", "C:/" }) |root| {
        const got = (try envSdlPaths(a, .windows, .windows, root)).?;
        // Not trimmed to the drive-relative `C:`.
        try std.testing.expectEqualStrings(root, got.lib);
        try std.testing.expect(got.include == null);
    }
}

test "envSdlPaths: unset or empty env var is not in play" {
    const a = std.testing.allocator;
    try std.testing.expect((try envSdlPaths(a, .windows, .windows, null)) == null);
    try std.testing.expect((try envSdlPaths(a, .windows, .windows, "")) == null);
}

test "envSdlPaths: non-Windows host or target ignores the env var" {
    const a = std.testing.allocator;
    try std.testing.expect((try envSdlPaths(a, .linux, .linux, "/x/lib")) == null);
    try std.testing.expect((try envSdlPaths(a, .macos, .macos, "/x/lib")) == null);
    // Cross-compiling to Windows: the host path means nothing for the target.
    try std.testing.expect((try envSdlPaths(a, .windows, .linux, "/x/lib")) == null);
    try std.testing.expect((try envSdlPaths(a, .linux, .windows, "C:/x/lib")) == null);
}
