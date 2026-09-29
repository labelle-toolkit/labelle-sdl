//! "Does this project need SDL2?" — decided from the project's own
//! `project.labelle`, which the provider reads from the context's
//! `project_dir` (the contract passes no project fields, only the path).
//!
//! The rule is labelle-cli's `wants_sdl2` (`pipeline/install.zig`, and
//! `doctor.zig`'s `needs_sdl`), ported as-is so moving SDL2 out of the CLI
//! changes nothing for a project:
//!
//!   needs SDL2  <=>  backend == sdl
//!                or (backend in {raylib, sokol, bgfx} and .gamepad != .none)
//!
//! The `sdl` backend links SDL2 as its renderer; raylib, sokol and bgfx link
//! it for the shared desktop gamepad source unless the project opts out with
//! `.gamepad = .none` (the default is `.auto`). The backend is `.backend`
//! when given, else `.backend_package.name`, else `bgfx` (the CLI's
//! `default_backend`). Any other backend (wgpu, null, a third-party
//! package) is not known to need SDL2, so it gets nothing — the same answer
//! the CLI's closed enum gives.
//!
//! Only the three fields are read, from the ZON syntax tree, so an unknown
//! backend tag or any other field a newer schema adds never fails a hook.
const std = @import("std");

/// The CLI's `default_backend`: the backend of a project that declares none.
pub const default_backend = "bgfx";

/// The backends whose desktop gamepad source is SDL2.
const gamepad_backends = [_][]const u8{ "raylib", "sokol", "bgfx" };

pub const Fields = struct {
    /// `.backend = .<tag>`, as the tag name.
    backend: ?[]const u8 = null,
    /// `.backend_package = .{ .name = "<name>", ... }`.
    backend_package: ?[]const u8 = null,
    /// `.gamepad = .<tag>` (`auto` or `none`).
    gamepad: ?[]const u8 = null,

    /// The effective backend identity.
    pub fn backendName(f: Fields) []const u8 {
        return f.backend orelse f.backend_package orelse default_backend;
    }

    /// The SDL `render` backend: needs the headers and SDL2_mixer too.
    pub fn sdlRenderer(f: Fields) bool {
        return std.mem.eql(u8, f.backendName(), "sdl");
    }

    /// SDL2 for the desktop gamepad source (the sdl backend included, as in
    /// the CLI's doctor: it links SDL2 unconditionally).
    pub fn sdlGamepad(f: Fields) bool {
        const off = if (f.gamepad) |g| std.mem.eql(u8, g, "none") else false;
        if (off) return f.sdlRenderer();
        const name = f.backendName();
        if (std.mem.eql(u8, name, "sdl")) return true;
        for (gamepad_backends) |b| if (std.mem.eql(u8, name, b)) return true;
        return false;
    }

    pub fn needsSdl2(f: Fields) bool {
        return f.sdlRenderer() or f.sdlGamepad();
    }
};

pub const Error = error{ProjectFileInvalid} || std.mem.Allocator.Error;

/// Read the three fields out of `project.labelle` source. Arena-allocated
/// (the strings are copies). A file that does not parse is refused: the
/// CLI and assembler would refuse it too, and guessing could download SDL2
/// for nothing or skip it when needed.
pub fn parseFields(a: std.mem.Allocator, source: [:0]const u8) Error!Fields {
    var ast = try std.zig.Ast.parse(a, source, .zon);
    defer ast.deinit(a);
    if (ast.errors.len != 0) return error.ProjectFileInvalid;
    const zoir = try std.zig.ZonGen.generate(a, ast, .{});
    defer zoir.deinit(a);
    if (zoir.hasCompileErrors()) return error.ProjectFileInvalid;
    const root = std.zig.Zoir.Node.Index.root.get(zoir);
    const top = switch (root) {
        .struct_literal => |s| s,
        .empty_literal => return .{},
        else => return error.ProjectFileInvalid,
    };
    var out: Fields = .{};
    for (top.names, 0..) |name_nts, i| {
        const name = name_nts.get(zoir);
        const value = top.vals.at(@intCast(i)).get(zoir);
        if (std.mem.eql(u8, name, "backend")) {
            out.backend = try enumTag(a, zoir, value);
        } else if (std.mem.eql(u8, name, "gamepad")) {
            out.gamepad = try enumTag(a, zoir, value);
        } else if (std.mem.eql(u8, name, "backend_package")) {
            const pkg = switch (value) {
                .struct_literal => |s| s,
                .null => continue,
                else => return error.ProjectFileInvalid,
            };
            for (pkg.names, 0..) |pkg_name, j| {
                if (!std.mem.eql(u8, pkg_name.get(zoir), "name")) continue;
                switch (pkg.vals.at(@intCast(j)).get(zoir)) {
                    .string_literal => |s| out.backend_package = try a.dupe(u8, s),
                    else => return error.ProjectFileInvalid,
                }
            }
        }
    }
    return out;
}

fn enumTag(a: std.mem.Allocator, zoir: std.zig.Zoir, value: std.zig.Zoir.Node) Error![]const u8 {
    return switch (value) {
        .enum_literal => |tag| try a.dupe(u8, tag.get(zoir)),
        else => error.ProjectFileInvalid,
    };
}

/// `<project_dir>/project.labelle`'s fields.
pub fn load(a: std.mem.Allocator, io: std.Io, project_dir: []const u8) !Fields {
    const path = try std.fs.path.join(a, &.{ project_dir, "project.labelle" });
    const bytes = try std.Io.Dir.cwd().readFileAllocOptions(io, path, a, .limited(4 * 1024 * 1024), .of(u8), 0);
    return parseFields(a, bytes);
}

// ── Tests ─────────────────────────────────────────────────────────────────

fn needs(source: [:0]const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    return (try parseFields(arena.allocator(), source)).needsSdl2();
}

test "the CLI's wants_sdl2 table: sdl always, raylib/sokol/bgfx unless .gamepad = .none" {
    try std.testing.expect(try needs(".{ .name = \"g\", .backend = .sdl }"));
    try std.testing.expect(try needs(".{ .name = \"g\", .backend = .sdl, .gamepad = .none }"));
    for ([_][:0]const u8{
        ".{ .name = \"g\", .backend = .raylib }",
        ".{ .name = \"g\", .backend = .sokol, .gamepad = .auto }",
        ".{ .name = \"g\", .backend = .bgfx }",
    }) |src| try std.testing.expect(try needs(src));
    for ([_][:0]const u8{
        ".{ .name = \"g\", .backend = .raylib, .gamepad = .none }",
        ".{ .name = \"g\", .backend = .sokol, .gamepad = .none }",
        ".{ .name = \"g\", .backend = .bgfx, .gamepad = .none }",
        ".{ .name = \"g\", .backend = .wgpu }",
        ".{ .name = \"g\", .backend = .null }",
    }) |src| try std.testing.expect(!try needs(src));
}

test "no .backend: the backend package's name, else the default bgfx" {
    // Nothing declared: bgfx with the default gamepad, so SDL2 is needed.
    try std.testing.expect(try needs(".{ .name = \"g\" }"));
    try std.testing.expect(!try needs(".{ .name = \"g\", .gamepad = .none }"));
    // The package name decides when there is no enum.
    try std.testing.expect(try needs(".{ .name = \"g\", .backend_package = .{ .name = \"sdl\", .repo = \"github.com/labelle-toolkit/labelle-sdl\", .version = \"0.3.2\" }, .gamepad = .none }"));
    // A third-party backend is not known to link SDL2.
    try std.testing.expect(!try needs(".{ .name = \"g\", .backend_package = .{ .name = \"acme\", .repo = \"local:../acme\" } }"));
    // `.backend` wins over the package name, as in the CLI.
    try std.testing.expect(!try needs(".{ .name = \"g\", .backend = .wgpu, .backend_package = .{ .name = \"sdl\", .repo = \"x\" } }"));
}

test "a real project.labelle shape parses: comments, nested plugins, unknown fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const f = try parseFields(arena.allocator(),
        \\.{
        \\    .name = "flying_platform",
        \\    // a comment
        \\    .backend = .bgfx,
        \\    .window = .{ .width = 1280, .height = 720, .title = "FP" },
        \\    .backend_package = .{ .name = "bgfx", .repo = "github.com/labelle-toolkit/labelle-bgfx", .version = "0.25.0" },
        \\    .gamepad = .none,
        \\    .plugins = .{
        \\        .{ .name = "sdl2", .repo = "github.com/labelle-toolkit/labelle-sdl", .version = "0.4.0" },
        \\    },
        \\    .future_field = .{ 1, 2.5, 'c', null, true },
        \\}
    );
    try std.testing.expectEqualStrings("bgfx", f.backend.?);
    try std.testing.expectEqualStrings("bgfx", f.backend_package.?);
    try std.testing.expectEqualStrings("none", f.gamepad.?);
    try std.testing.expect(!f.needsSdl2());
    try std.testing.expect(!f.sdlRenderer());
}

test "the sdl renderer needs the headers and mixer; a gamepad backend only the library" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sdl = try parseFields(a, ".{ .backend = .sdl, .gamepad = .none }");
    try std.testing.expect(sdl.sdlRenderer() and sdl.sdlGamepad());
    const raylib = try parseFields(a, ".{ .backend = .raylib }");
    try std.testing.expect(!raylib.sdlRenderer() and raylib.sdlGamepad());
}

test "a malformed project.labelle is refused, not guessed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.ProjectFileInvalid, parseFields(a, ".{ .backend = "));
    try std.testing.expectError(error.ProjectFileInvalid, parseFields(a, ".{ .backend = \"sdl\" }"));
    try std.testing.expectError(error.ProjectFileInvalid, parseFields(a, ".{ .backend_package = .sdl }"));
    try std.testing.expectError(error.ProjectFileInvalid, parseFields(a, "42"));
    _ = try parseFields(a, ".{}");
}

test "load reads project_dir/project.labelle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "project.labelle", .data = ".{ .name = \"g\", .backend = .sokol }" });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const f = try load(a, io, dir);
    try std.testing.expectEqualStrings("sokol", f.backendName());
    try std.testing.expect(f.needsSdl2());
}
