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
