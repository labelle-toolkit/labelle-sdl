const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("build_helpers.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
        "SDL2 install prefix (auto-detected on macOS Homebrew, unused on Linux/Windows)",
    ) orelse helpers.detectSdlPrefix(target.result.os.tag, builtin.target.os.tag, dirExists);

    // Shared SDL2 C import module — ensures a single set of opaque types.
    // Only include/library *paths* are set here for @cImport resolution.
    // Actual linkSystemLibrary calls are deferred to the final executable
    // to prevent duplicate dylib entries when multiple modules import sdl.
    const sdl_mod = b.addModule("sdl", .{
        .root_source_file = b.path("src/sdl.zig"),
        .target = target,
        .optimize = optimize,
    });
    addSdlPaths(b, sdl_mod, sdl_prefix);

    // labelle-core — frozen gamepad event contract types consumed by the
    // input backend (GamepadEvent / GamepadDescription, core#18).
    const core_dep = b.dependency("labelle_core", .{ .target = target, .optimize = optimize });
    const core_mod = core_dep.module("labelle-core");

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
    input_mod.addImport("labelle_core", core_mod);

    // ── Audio backend module ────────────────────────────────────────
    // audio.zig has its own @cImport for SDL_mixer, so it needs the
    // paths directly; cImports don't propagate through module imports.
    const audio_mod = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_mod.addImport("sdl", sdl_mod);
    addSdlPaths(b, audio_mod, sdl_prefix);

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
    const test_step = b.step("test", "Run SDL backend build-helper tests");
    test_step.dependOn(&b.addRunArtifact(helper_tests).step);

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
                .{ .name = "labelle_core", .module = core_mod },
            },
        }),
    });
    addSdlPaths(b, input_tests.root_module, sdl_prefix);
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
    addSdlPaths(b, window_mod, sdl_prefix);
    window_mod.linkSystemLibrary("SDL2", .{});
    test_step.dependOn(&window_tests.step);
}

fn addSdlPaths(b: *std.Build, mod: *std.Build.Module, prefix: []const u8) void {
    if (prefix.len == 0) return;
    const include_path = b.pathJoin(&.{ prefix, "include" });
    const lib_path = b.pathJoin(&.{ prefix, "lib" });
    mod.addIncludePath(.{ .cwd_relative = include_path });
    mod.addLibraryPath(.{ .cwd_relative = lib_path });
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
