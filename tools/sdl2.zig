//! The provider-managed SDL2 under the contract's `cache_dir`: the official
//! MinGW dev package, ported from labelle-cli `sdl_provision.zig` (same
//! release, same URL, same lib-dir arrangement), now pinned by SHA-256 and
//! installed the way contract §2 "Provider cache" asks: keyed by host and
//! SDK identity, under an exclusive lock, staged in a temporary sibling and
//! renamed into place once complete; a tree without its marker is absent.
//!
//! Layout (versioned, `layout`):
//!
//!   <cache_dir>/sdl2-v1/<os>-<arch>/<version>-<sha12>/
//!       .labelle-sdl2.json                  completion marker
//!       SDL2-<version>/x86_64-w64-mingw32/
//!           lib/libSDL2.dll.a  lib/SDL2.dll  the dir LABELLE_SDL2_LIB names
//!           include/SDL2/SDL.h               bin/SDL2.dll
//!
//! Only Windows hosts provision: Linux and macOS use the system (or
//! Homebrew) SDL2 exactly as before, and a system install needs privileges
//! a build hook won't assume, so there the provider prints the one-liner.
const std = @import("std");
const builtin = @import("builtin");
const proc = @import("proc.zig");

/// The layout of everything under `cache_dir`; bump on an incompatible change.
pub const layout = "sdl2-v1";
pub const marker_name = ".labelle-sdl2.json";
pub const is_windows = builtin.os.tag == .windows;
/// `<os>-<arch>` of this host: one cache may serve several machines.
pub const host_key = @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.cpu.arch);

/// One pinned SDL2 dev package.
pub const Release = struct {
    version: []const u8,
    url: []const u8,
    /// SHA-256 of the archive bytes, lowercase hex.
    sha256: []const u8,
    /// The package's root directory inside the archive.
    root: []const u8,
    /// The package's MinGW subtree for the host's architecture, or null
    /// when the package has none (`mingwTriple`).
    mingw: ?[]const u8,
};

/// The MinGW subtree of the SDL2 dev package that matches `arch`: the
/// package ships x86_64 and i686 builds only, so an ARM64 host has none.
pub fn mingwTriple(arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (arch) {
        .x86_64 => "x86_64-w64-mingw32",
        .x86 => "i686-w64-mingw32",
        else => null,
    };
}

/// The release labelle-cli provisions (`SDL2_VERSION` in
/// `sdl_provision.zig`), verified against the toolkit's Windows backends.
pub const SDL2_VERSION = "2.30.11";
pub const pinned: Release = .{
    .version = SDL2_VERSION,
    .url = "https://github.com/libsdl-org/SDL/releases/download/release-" ++
        SDL2_VERSION ++ "/SDL2-devel-" ++ SDL2_VERSION ++ "-mingw.tar.gz",
    .sha256 = "0590db0a47b564aab92499ed03eaa75db9aee17c371080caa3b05df9d49d9ff9",
    .root = "SDL2-" ++ SDL2_VERSION,
    .mingw = mingwTriple(builtin.cpu.arch),
};

pub const import_lib = "libSDL2.dll.a";
pub const dll_name = "SDL2.dll";

/// How the archive is fetched and unpacked. `system` runs curl and tar
/// (both ship with Windows 10+, as the CLI relied on); tests substitute a
/// fake that lays out a package without the network.
pub const Fetcher = struct {
    ctx: ?*anyopaque = null,
    /// Download `url` to the file `dest`.
    download: *const fn (ctx: ?*anyopaque, io: std.Io, a: std.mem.Allocator, url: []const u8, dest: []const u8) anyerror!void,
    /// Unpack the `.tar.gz` `archive` into the directory `dest`.
    extract: *const fn (ctx: ?*anyopaque, io: std.Io, a: std.mem.Allocator, archive: []const u8, dest: []const u8) anyerror!void,
};

pub const system: Fetcher = .{ .download = systemDownload, .extract = systemExtract };

fn systemDownload(_: ?*anyopaque, io: std.Io, a: std.mem.Allocator, url: []const u8, dest: []const u8) anyerror!void {
    if (try proc.step(io, a, &.{ "curl", "-fsSL", "--retry", "2", "-o", dest, url }) != 0) {
        std.debug.print("labelle-sdl2: download failed (is curl on PATH?): {s}\n", .{url});
        return error.Sdl2DownloadFailed;
    }
}

fn systemExtract(_: ?*anyopaque, io: std.Io, a: std.mem.Allocator, archive: []const u8, dest: []const u8) anyerror!void {
    if (try proc.step(io, a, &.{ "tar", "-xzf", archive, "-C", dest }) != 0) {
        std.debug.print("labelle-sdl2: extracting {s} failed (is tar on PATH?)\n", .{archive});
        return error.Sdl2ExtractFailed;
    }
}

/// `<cache_dir>/sdl2-v1/<host>/<version>-<sha12>`: the install directory
/// of `release` for this host.
pub fn installDir(a: std.mem.Allocator, cache_dir: []const u8, release: Release) ![]const u8 {
    const id = try std.fmt.allocPrint(a, "{s}-{s}", .{ release.version, release.sha256[0..12] });
    return std.fs.path.join(a, &.{ cache_dir, layout, host_key, id });
}

/// The directory `LABELLE_SDL2_LIB` names for an install: import lib + DLL.
pub fn libDirOf(a: std.mem.Allocator, install: []const u8, release: Release) ![]const u8 {
    const triple = release.mingw orelse return error.Sdl2UnsupportedHostArch;
    return std.fs.path.join(a, &.{ install, release.root, triple, "lib" });
}

pub fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// A complete install: the marker (written last, before the rename) and
/// the files the link, the `@cImport`s and the launch need. A damaged one
/// is reinstalled by the next `ensure`.
pub fn complete(a: std.mem.Allocator, io: std.Io, install: []const u8, release: Release) bool {
    const lib = libDirOf(a, install, release) catch return false;
    const marker = std.fs.path.join(a, &.{ install, marker_name }) catch return false;
    const implib = std.fs.path.join(a, &.{ lib, import_lib }) catch return false;
    const dll = std.fs.path.join(a, &.{ lib, dll_name }) catch return false;
    const header = std.fs.path.join(a, &.{ lib, "..", "include", "SDL2", "SDL.h" }) catch return false;
    return exists(io, marker) and exists(io, implib) and exists(io, dll) and exists(io, header);
}

/// The lib dir of a complete install of `release` in `cache_dir`, or null.
pub fn installedLibDir(a: std.mem.Allocator, io: std.Io, cache_dir: []const u8, release: Release) ?[]const u8 {
    const dir = installDir(a, cache_dir, release) catch return null;
    if (!complete(a, io, dir, release)) return null;
    return libDirOf(a, dir, release) catch null;
}

pub const EnsureOptions = struct {
    /// `LABELLE_OFFLINE`: never download; a missing install is an error.
    offline: bool = false,
};

/// Install `release` under `cache_dir` unless a complete install exists.
/// Returns its lib dir (the `LABELLE_SDL2_LIB` value).
pub fn ensure(a: std.mem.Allocator, io: std.Io, fetcher: Fetcher, cache_dir: []const u8, release: Release, opts: EnsureOptions) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const triple = release.mingw orelse {
        std.debug.print("labelle-sdl2: unsupported host architecture ({s}): the SDL2 MinGW package ships x86_64 and i686 builds only; set LABELLE_SDL2_LIB to an SDL2 for this architecture\n", .{@tagName(builtin.cpu.arch)});
        return error.Sdl2UnsupportedHostArch;
    };
    const dir = try installDir(a, cache_dir, release);
    if (complete(a, io, dir, release)) return libDirOf(a, dir, release);
    if (opts.offline) {
        std.debug.print(
            "labelle-sdl2: SDL2 {s} is not installed at {s} and LABELLE_OFFLINE is set; " ++
                "run `labelle sdl2 install` with network access first\n",
            .{ release.version, dir },
        );
        return error.Sdl2NotInstalledOffline;
    }
    const parent = std.fs.path.dirname(dir).?;
    try cwd.createDirPath(io, parent);
    const lock_path = try std.fmt.allocPrint(a, "{s}.lock", .{dir});
    const lock = cwd.createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive }) catch |err| {
        std.debug.print("labelle-sdl2: could not lock {s}: {s}\n", .{ lock_path, @errorName(err) });
        return error.Sdl2InstallLockFailed;
    };
    defer lock.close(io);
    // Another build may have finished the install while this one waited.
    if (complete(a, io, dir, release)) {
        std.debug.print("labelle-sdl2: SDL2 {s} was installed by another build: {s}\n", .{ release.version, dir });
        return libDirOf(a, dir, release);
    }
    // Holding the lock: any staging sibling is an interrupted install's.
    const stale_prefix = try std.fmt.allocPrint(a, "{s}.tmp-", .{std.fs.path.basename(dir)});
    removeStale(a, io, parent, stale_prefix);

    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const staging = try std.fmt.allocPrint(a, "{s}.tmp-{x}", .{ dir, std.mem.readInt(u64, &rnd, .little) });
    defer cwd.deleteTree(io, staging) catch {};
    try cwd.createDirPath(io, staging);

    std.debug.print("labelle-sdl2: downloading SDL2 {s} (MinGW dev libs)\n    {s}\n", .{ release.version, release.url });
    const archive = try std.fs.path.join(a, &.{ staging, "SDL2-devel-mingw.tar.gz" });
    try fetcher.download(fetcher.ctx, io, a, release.url, archive);
    try verifySha256(a, io, archive, release.sha256);
    try fetcher.extract(fetcher.ctx, io, a, archive, staging);
    cwd.deleteFile(io, archive) catch {};

    // Arrange for Zig's linker (as the CLI did): it resolves SDL2.dll in the
    // library search dir, not only the MinGW import lib, and would otherwise
    // fall back to the static libSDL2.a (which drags in many Win32 libs).
    // Copy the DLL into lib/ and drop the static archives.
    const lib = try libDirOf(a, staging, release);
    const bin_dll = try std.fs.path.join(a, &.{ staging, release.root, triple, "bin", dll_name });
    const lib_dll = try std.fs.path.join(a, &.{ lib, dll_name });
    const implib = try std.fs.path.join(a, &.{ lib, import_lib });
    const header = try std.fs.path.join(a, &.{ lib, "..", "include", "SDL2", "SDL.h" });
    if (!exists(io, bin_dll) or !exists(io, header) or !exists(io, implib)) {
        std.debug.print("labelle-sdl2: the SDL2 {s} package has an unexpected layout (no {s}/bin/{s} or lib/{s})\n", .{ release.version, triple, dll_name, import_lib });
        return error.Sdl2UnexpectedLayout;
    }
    try cwd.copyFile(bin_dll, cwd, lib_dll, io, .{});
    for ([_][]const u8{ "libSDL2.a", "libSDL2_test.a" }) |static| {
        const p = try std.fs.path.join(a, &.{ lib, static });
        cwd.deleteFile(io, p) catch {};
    }

    const marker = try std.fs.path.join(a, &.{ staging, marker_name });
    const record = try std.json.Stringify.valueAlloc(a, .{
        .layout = layout,
        .version = release.version,
        .sha256 = release.sha256,
        .host = host_key,
    }, .{});
    try cwd.writeFile(io, .{ .sub_path = marker, .data = record });
    // An incomplete tree at the destination (no marker) is absent.
    cwd.deleteTree(io, dir) catch {};
    try cwd.rename(staging, cwd, dir, io);
    const lib_dir = try libDirOf(a, dir, release);
    std.debug.print("labelle-sdl2: SDL2 {s} ready at {s}\n", .{ release.version, lib_dir });
    return lib_dir;
}

fn removeStale(a: std.mem.Allocator, io: std.Io, parent: []const u8, prefix: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(io, parent, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (std.mem.startsWith(u8, entry.name, prefix)) names.append(a, a.dupe(u8, entry.name) catch return) catch return;
    }
    for (names.items) |name| dir.deleteTree(io, name) catch {};
}

/// Refuse an archive whose SHA-256 is not `expected` (lowercase hex).
pub fn verifySha256(a: std.mem.Allocator, io: std.Io, path: []const u8, expected: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(256 * 1024 * 1024));
    defer a.free(bytes);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const got = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &got, expected)) {
        std.debug.print("labelle-sdl2: SDL2 archive checksum mismatch: expected {s}, got {s}\n", .{ expected, &got });
        return error.Sdl2ChecksumMismatch;
    }
}

/// Package-manager guidance where the provider does not provision.
pub fn printGuidance() void {
    switch (builtin.os.tag) {
        .linux => std.debug.print(
            \\  SDL2 comes from your system package manager:
            \\    sudo apt install libsdl2-dev libsdl2-mixer-dev    # Debian/Ubuntu
            \\    sudo dnf install SDL2-devel SDL2_mixer-devel      # Fedora
            \\    sudo pacman -S sdl2 sdl2_mixer                    # Arch
            \\
        , .{}),
        .macos => std.debug.print(
            \\  SDL2 comes from Homebrew:
            \\    brew install sdl2 sdl2_mixer
            \\
        , .{}),
        else => std.debug.print("  SDL2 provisioning is not supported on this host.\n", .{}),
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A fake network: `download` writes `payload`; `extract` lays out a MinGW
/// package tree (optionally a broken one).
pub const Fake = struct {
    payload: []const u8 = "fake SDL2 archive",
    downloads: usize = 0,
    broken_layout: bool = false,
    fail_download: bool = false,

    pub fn fetcher(self: *Fake) Fetcher {
        return .{ .ctx = self, .download = download, .extract = extract };
    }

    pub fn release(self: *const Fake) Release {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.payload, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        return .{
            .version = "2.30.11",
            .url = "https://example.invalid/SDL2-devel-2.30.11-mingw.tar.gz",
            .sha256 = testing.allocator.dupe(u8, &hex) catch unreachable,
            .root = "SDL2-2.30.11",
            .mingw = "x86_64-w64-mingw32",
        };
    }

    pub fn touch(io: std.Io, a: std.mem.Allocator, parts: []const []const u8) !void {
        const path = try std.fs.path.join(a, parts);
        defer a.free(path);
        if (std.fs.path.dirname(path)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "fake" });
    }

    fn download(ctx: ?*anyopaque, io: std.Io, _: std.mem.Allocator, _: []const u8, dest: []const u8) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        self.downloads += 1;
        if (self.fail_download) return error.Sdl2DownloadFailed;
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = self.payload });
    }

    fn extract(ctx: ?*anyopaque, io: std.Io, a: std.mem.Allocator, _: []const u8, dest: []const u8) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        const base = try std.fs.path.join(a, &.{ dest, "SDL2-2.30.11", "x86_64-w64-mingw32" });
        defer a.free(base);
        try touch(io, a, &.{ base, "lib", import_lib });
        try touch(io, a, &.{ base, "lib", "libSDL2.a" });
        try touch(io, a, &.{ base, "lib", "libSDL2_test.a" });
        try touch(io, a, &.{ base, "include", "SDL2", "SDL.h" });
        if (!self.broken_layout) try touch(io, a, &.{ base, "bin", dll_name });
    }
};

const Tmp = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []const u8,

    fn init() !Tmp {
        var t: Tmp = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator), .root = "" };
        t.root = try t.tmp.dir.realPathFileAlloc(testing.io, ".", t.arena.allocator());
        return t;
    }
    fn deinit(t: *Tmp) void {
        t.arena.deinit();
        t.tmp.cleanup();
    }
    fn path(t: *Tmp, parts: []const []const u8) ![]const u8 {
        const a = t.arena.allocator();
        var all: std.ArrayList([]const u8) = .empty;
        try all.append(a, t.root);
        try all.appendSlice(a, parts);
        return std.fs.path.join(a, all.items);
    }
};

test "the pinned release is the CLI's 2.30.11 MinGW package" {
    try testing.expectEqualStrings("2.30.11", pinned.version);
    try testing.expectEqualStrings("https://github.com/libsdl-org/SDL/releases/download/release-2.30.11/SDL2-devel-2.30.11-mingw.tar.gz", pinned.url);
    try testing.expectEqual(@as(usize, 64), pinned.sha256.len);
    for (pinned.sha256) |c| try testing.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
}

test "the install dir is keyed by layout, host and SDK identity" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const dir = try installDir(a, "/c", pinned);
    const want = try std.fs.path.join(a, &.{ "/c", "sdl2-v1", host_key, "2.30.11-0590db0a47b5" });
    try testing.expectEqualStrings(want, dir);
    var x64 = pinned;
    x64.mingw = mingwTriple(.x86_64);
    try testing.expect(std.mem.endsWith(u8, try libDirOf(a, dir, x64), try std.fs.path.join(a, &.{ "SDL2-2.30.11", "x86_64-w64-mingw32", "lib" })));
}

test "the MinGW subtree follows the host arch; an ARM64 host is refused, not given x86_64" {
    try testing.expectEqualStrings("x86_64-w64-mingw32", mingwTriple(.x86_64).?);
    try testing.expectEqualStrings("i686-w64-mingw32", mingwTriple(.x86).?);
    try testing.expect(mingwTriple(.aarch64) == null);
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    var fake: Fake = .{};
    var arm = fake.release();
    defer testing.allocator.free(arm.sha256);
    arm.mingw = null;
    try testing.expectError(error.Sdl2UnsupportedHostArch, ensure(a, testing.io, fake.fetcher(), try t.path(&.{"cache"}), arm, .{}));
    try testing.expectEqual(@as(usize, 0), fake.downloads);
    try testing.expectError(error.Sdl2UnsupportedHostArch, libDirOf(a, "/c", arm));
}

test "a cached install that lost its headers is incomplete and reinstalled" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const io = testing.io;
    const cache = try t.path(&.{"cache"});
    var fake: Fake = .{};
    const release = fake.release();
    defer testing.allocator.free(release.sha256);
    const lib = try ensure(a, io, fake.fetcher(), cache, release, .{});
    try std.Io.Dir.cwd().deleteFile(io, try std.fs.path.join(a, &.{ lib, "..", "include", "SDL2", "SDL.h" }));
    try testing.expect(installedLibDir(a, io, cache, release) == null);
    _ = try ensure(a, io, fake.fetcher(), cache, release, .{});
    try testing.expectEqual(@as(usize, 2), fake.downloads);
    try testing.expect(installedLibDir(a, io, cache, release) != null);
}

test "ensure installs once, arranges lib/ for the linker and leaves no staging" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const io = testing.io;
    const cache = try t.path(&.{"cache"});
    var fake: Fake = .{};
    const release = fake.release();
    defer testing.allocator.free(release.sha256);
    const lib = try ensure(a, io, fake.fetcher(), cache, release, .{});
    try testing.expectEqual(@as(usize, 1), fake.downloads);
    try testing.expect(exists(io, try std.fs.path.join(a, &.{ lib, dll_name })));
    try testing.expect(exists(io, try std.fs.path.join(a, &.{ lib, import_lib })));
    try testing.expect(!exists(io, try std.fs.path.join(a, &.{ lib, "libSDL2.a" })));
    try testing.expect(!exists(io, try std.fs.path.join(a, &.{ lib, "libSDL2_test.a" })));
    try testing.expectEqualStrings(lib, installedLibDir(a, io, cache, release).?);
    // Complete: a second call (even offline) reuses it without a download.
    try testing.expectEqualStrings(lib, try ensure(a, io, fake.fetcher(), cache, release, .{ .offline = true }));
    try testing.expectEqual(@as(usize, 1), fake.downloads);
    // No staging or archive left beside the install.
    const dir = try installDir(a, cache, release);
    var parent = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(dir).?, .{ .iterate = true });
    defer parent.close(io);
    var it = parent.iterate();
    while (try it.next(io)) |entry| try testing.expect(std.mem.indexOf(u8, entry.name, ".tmp-") == null);
    try testing.expect(!exists(io, try std.fs.path.join(a, &.{ dir, "SDL2-devel-mingw.tar.gz" })));
    // The marker records the identity.
    const marker = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ dir, marker_name }), a, .limited(4096));
    try testing.expect(std.mem.indexOf(u8, marker, "\"layout\":\"sdl2-v1\"") != null);
    try testing.expect(std.mem.indexOf(u8, marker, release.sha256) != null);
}

test "ensure refuses a checksum mismatch, a broken layout and an offline miss, installing nothing" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const io = testing.io;
    const cache = try t.path(&.{"cache"});
    var fake: Fake = .{};
    var release = fake.release();
    defer testing.allocator.free(release.sha256);
    const good = release.sha256;
    release.sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
    try testing.expectError(error.Sdl2ChecksumMismatch, ensure(a, io, fake.fetcher(), cache, release, .{}));
    release.sha256 = good;
    try testing.expect(installedLibDir(a, io, cache, release) == null);
    var broken: Fake = .{ .broken_layout = true };
    try testing.expectError(error.Sdl2UnexpectedLayout, ensure(a, io, broken.fetcher(), cache, release, .{}));
    try testing.expect(installedLibDir(a, io, cache, release) == null);
    var offline: Fake = .{};
    try testing.expectError(error.Sdl2NotInstalledOffline, ensure(a, io, offline.fetcher(), cache, release, .{ .offline = true }));
    try testing.expectEqual(@as(usize, 0), offline.downloads);
    var down: Fake = .{ .fail_download = true };
    try testing.expectError(error.Sdl2DownloadFailed, ensure(a, io, down.fetcher(), cache, release, .{}));
    try testing.expect(installedLibDir(a, io, cache, release) == null);
}

test "a tree without the marker is absent; stale staging is cleared under the lock" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const io = testing.io;
    const cache = try t.path(&.{"cache"});
    var fake: Fake = .{};
    const release = fake.release();
    defer testing.allocator.free(release.sha256);
    const dir = try installDir(a, cache, release);
    // An interrupted install: the files but no marker, and a staging sibling.
    const lib = try libDirOf(a, dir, release);
    try Fake.touch(io, a, &.{ lib, import_lib });
    try Fake.touch(io, a, &.{ lib, dll_name });
    try testing.expect(!complete(a, io, dir, release));
    const stale = try std.fmt.allocPrint(a, "{s}.tmp-dead", .{dir});
    try Fake.touch(io, a, &.{ stale, "partial" });
    _ = try ensure(a, io, fake.fetcher(), cache, release, .{});
    try testing.expectEqual(@as(usize, 1), fake.downloads);
    try testing.expect(!exists(io, stale));
    try testing.expect(complete(a, io, dir, release));
    // The lock file stays (harmless); it is not an install.
    try testing.expect(exists(io, try std.fmt.allocPrint(a, "{s}.lock", .{dir})));
}

test "verifySha256 hashes the archive bytes" {
    var t = try Tmp.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const file = try t.path(&.{"blob"});
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = file, .data = "abc" });
    try verifySha256(a, testing.io, file, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try testing.expectError(error.Sdl2ChecksumMismatch, verifySha256(a, testing.io, file, pinned.sha256));
}
