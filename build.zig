const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("build_helpers.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── The `sdl2` provider (plugin.labelle, RFC labelle-cli#471 S1) ─────
    // Declared FIRST and dependency-free: the CLI builds it with
    // `zig build install-provider --system <zig-cache>/p`, which never
    // fetches, so nothing below may be required to reach these steps.
    //
    // `labelle_sdl2` is the module the assembler imports for a `.plugins`
    // entry named `sdl2` (`labelle_<name>`); it is empty.
    _ = b.addModule("labelle_sdl2", .{
        .root_source_file = b.path("src/sdl2_provider.zig"),
        .target = target,
        .optimize = optimize,
    });
    // `bin/labelle-sdl2`, the one executable every command/hook names.
    // Always built for the host, whatever `-Dtarget` says; std only.
    const provider_module = b.createModule(.{
        .root_source_file = b.path("tools/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    // `tools/main.zig`'s test checks its routing table against the manifest.
    provider_module.addAnonymousImport("plugin.labelle", .{ .root_source_file = b.path("plugin.labelle") });
    const provider = b.addExecutable(.{ .name = "labelle-sdl2", .root_module = provider_module });
    b.step("install-provider", "Install the labelle-cli sdl2 provider tool (bin/labelle-sdl2)")
        .dependOn(&b.addInstallArtifact(provider, .{}).step);
    const provider_tests = b.addRunArtifact(b.addTest(.{ .root_module = provider_module }));
    b.step("test-provider", "Run the sdl2 provider host-tool tests (wire contract, needs-SDL2, cache, staging, doctor)")
        .dependOn(&provider_tests.step);
    const test_step = b.step("test", "Run SDL backend build-helper tests and the provider tests");
    test_step.dependOn(&provider_tests.step);

    // labelle-core — frozen gamepad event contract types consumed by the
    // input backend (GamepadEvent / GamepadDescription, core#18). Lazy, so
    // the provider build above never needs it: under `--system` an absent
    // package is skipped rather than requested (a request fails the whole
    // `--system` build). A normal build that lacks it gets null on the
    // first configure pass and is re-run once zig fetched it, so the modules
    // below are still declared (a consumer's `.module("gfx")` must resolve)
    // and only the core-importing wiring waits for it.
    const core_mod: ?*std.Build.Module = blk: {
        if (b.graph.system_package_mode and !lazyDepFetched(b, "labelle_core")) break :blk null;
        const dep = b.lazyDependency("labelle_core", .{ .target = target, .optimize = optimize }) orelse break :blk null;
        break :blk dep.module("labelle-core");
    };

    // SDL2 install prefix. On Linux and Windows, SDL2 headers and
    // libraries live in system-wide paths that Zig finds automatically;
    // no prefix is needed. On macOS, SDL2 is typically installed via
    // Homebrew under /opt/homebrew (Apple Silicon) or /usr/local
    // (Intel), and Zig doesn't search those by default.
    //
    // Override via `-Dsdl-prefix=/custom/path` for non-standard installs
    // or cross-compilation (auto-detect skips cross-compile — see
    // build_helpers.zig for the logic and test cases).
    const sdl_prefix: []const u8 = b.option(
        []const u8,
        "sdl-prefix",
        "SDL2 install prefix (auto-detected on macOS Homebrew; on Windows set LABELLE_SDL2_LIB instead)",
    ) orelse helpers.detectSdlPrefix(target.result.os.tag, builtin.target.os.tag, dirExists);

    // Windows: honour `LABELLE_SDL2_LIB` (the dir holding `libSDL2.dll.a`,
    // e.g. the SDL2 MinGW devel package's `x86_64-w64-mingw32/lib` that
    // `labelle` provisions) — same contract as labelle-bgfx / labelle-raylib.
    // Its sibling `include` dir is added too, for the `@cImport`s. Applied
    // on top of `-Dsdl-prefix`; ignored off Windows and when cross-compiling.
    const env_paths = helpers.envSdlPaths(
        b.allocator,
        target.result.os.tag,
        builtin.target.os.tag,
        b.graph.environ_map.get("LABELLE_SDL2_LIB"),
    ) catch @panic("OOM");
    const sdl_paths: SdlPaths = .{
        .prefix = sdl_prefix,
        .env = env_paths,
        .windows = target.result.os.tag == .windows,
    };

    // Shared SDL2 C import module — ensures a single set of opaque types.
    // Only include/library *paths* are set here for @cImport resolution.
    // Actual linkSystemLibrary calls are deferred to the final executable
    // to prevent duplicate dylib entries when multiple modules import sdl.
    const sdl_mod = b.addModule("sdl", .{
        .root_source_file = b.path("src/sdl.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSdlPaths(b, sdl_mod, sdl_paths);

    // ── Gfx backend module ──────────────────────────────────────────
    const gfx_mod = b.addModule("gfx", .{
        .root_source_file = b.path("src/gfx.zig"),
        .target = target,
        .optimize = optimize,
    });
    gfx_mod.addImport("sdl", sdl_mod);

    // ── Input backend module ────────────────────────────────────────
    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_mod.addImport("sdl", sdl_mod);
    if (core_mod) |core| input_mod.addImport("labelle_core", core);

    // ── Audio backend module ────────────────────────────────────────
    // audio.zig has its own @cImport for SDL_mixer, so it needs the
    // paths directly; cImports don't propagate through module imports.
    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_mod.addImport("sdl", sdl_mod);
    addSdlPaths(b, audio_mod, sdl_paths);

    // ── Window backend module ───────────────────────────────────────
    const window_mod = b.addModule("window", .{
        .root_source_file = b.path("src/window.zig"),
        .target = target,
        .optimize = optimize,
    });
    window_mod.addImport("sdl", sdl_mod);
    window_mod.addImport("gfx", gfx_mod);
    window_mod.addImport("input", input_mod);
    window_mod.addImport("audio", audio_mod);

    // ── Unit tests for build_helpers.zig ────────────────────────────
    const helper_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("build_helpers.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(helper_tests).step);

    // The tests below import labelle-core (see `core_mod`).
    const core = core_mod orelse return;

    // ── Input backend unit tests (gamepad mapping/ring logic) ───────
    // Imports the same sdl + labelle-core modules and links SDL2 so the
    // SDL_CONTROLLER_* constants resolve. These tests are hardware-free.
    const input_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/input.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "sdl", .module = sdl_mod },
                .{ .name = "labelle_core", .module = core },
            },
        }),
    });
    addSdlPaths(b, input_tests.root_module, sdl_paths);
    input_tests.root_module.linkSystemLibrary("SDL2", .{});
    test_step.dependOn(&b.addRunArtifact(input_tests).step);

    // ── Compile-check window.zig ────────────────────────────────────
    // window.zig owns the SDL window lifecycle, including the
    // fullscreen toggle (SDL_SetWindowFullscreen / SDL_GetWindowFlags).
    // Forcing a test binary off window_mod pulls the full module graph
    // (sdl + gfx + input + audio) into the build so any breakage in the
    // @cImport-backed fullscreen path is caught at `zig build test`.
    // Depend on the compile step (not a run step) so it also works under
    // cross-compilation where the host can't execute the binary; SDL
    // include/lib paths are needed for the transitive @cInclude.
    const window_tests = b.addTest(.{ .root_module = window_mod });
    addSdlPaths(b, window_mod, sdl_paths);
    window_mod.linkSystemLibrary("SDL2", .{});
    test_step.dependOn(&window_tests.step);

    // ── labelle-core contract conformance self-check (#502) ─────────
    // Test-only module that imports labelle-core and compile-proves this
    // backend satisfies assertWindow/assertInput/assertBackend — the same
    // gates the assembler emits into every generated main.zig. The shipped
    // src/window.zig deliberately does NOT import labelle-core, so the module
    // graph consumed by generated games stays untouched. Mirrors input_tests'
    // SDL2 wiring so the behavioral runWindowSuite RUNS host-side.
    const contract_check_mod = b.createModule(.{
        .root_source_file = b.path("src/contract_check.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "labelle_core", .module = core },
            .{ .name = "window", .module = window_mod },
            .{ .name = "input", .module = input_mod },
            .{ .name = "gfx", .module = gfx_mod },
        },
    });
    addSdlPaths(b, contract_check_mod, sdl_paths);
    contract_check_mod.linkSystemLibrary("SDL2", .{});
    const contract_check = b.addTest(.{ .root_module = contract_check_mod });
    test_step.dependOn(&b.addRunArtifact(contract_check).step);
}

const SdlPaths = struct {
    /// `-Dsdl-prefix` / auto-detected Homebrew prefix ("" = system search).
    prefix: []const u8,
    /// From `LABELLE_SDL2_LIB` (Windows host + target only).
    env: ?helpers.EnvSdlPaths,
    /// Windows target: the SDL headers pull in C runtime headers
    /// (`process.h`, ...) that Zig only exposes when the module links libc.
    windows: bool,
};

fn addSdlPaths(b: *std.Build, mod: *std.Build.Module, paths: SdlPaths) void {
    if (paths.windows) mod.link_libc = true;
    if (paths.prefix.len != 0) {
        mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ paths.prefix, "include" }) });
        mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ paths.prefix, "lib" }) });
    }
    if (paths.env) |e| {
        if (e.include) |inc| mod.addIncludePath(.{ .cwd_relative = inc });
        mod.addLibraryPath(.{ .cwd_relative = e.lib });
    }
}

/// Whether the lazy dependency `name` is already on disk, without marking
/// it needed (which `b.lazyDependency` does, and which fails a `--system`
/// build). The same availability test `std.Build.lazyDependency` makes.
fn lazyDepFetched(b: *std.Build, name: []const u8) bool {
    const deps = @import("root").dependencies;
    const hash = for (b.available_deps) |dep| {
        if (std.mem.eql(u8, dep[0], name)) break dep[1];
    } else return false;
    inline for (@typeInfo(deps.packages).@"struct".decls) |decl| {
        if (std.mem.eql(u8, decl.name, hash)) {
            const pkg = @field(deps.packages, decl.name);
            return !@hasDecl(pkg, "available") or pkg.available;
        }
    }
    return false;
}

fn dirExists(path: []const u8) bool {
    // std.fs.cwd() removed in 0.16. The build runner doesn't link libc,
    // so we can't use std.c.access either — spin up an ad-hoc Io.Threaded
    // and go through std.Io.Dir.access{Absolute,}.
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    } else {
        std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    }
    return true;
}
