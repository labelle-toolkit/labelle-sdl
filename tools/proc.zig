//! Child processes (curl, tar, pkg-config). A child's stdout goes to the
//! provider's stderr: the CLI's stdout may carry its JSON progress feed.
const std = @import("std");
const builtin = @import("builtin");
const stdio = @import("stdio.zig");

/// Run `argv`, its output relayed to stderr. Returns the exit status (255
/// for a signal).
pub fn step(io: std.Io, a: std.mem.Allocator, argv: []const []const u8) !u8 {
    if (builtin.os.tag == .windows) {
        // Handing the stderr handle to a Windows child as its stdout fails
        // with NoDevice on windows-latest (labelle-web): capture, relay.
        const result = try std.process.run(a, io, .{ .argv = argv });
        defer a.free(result.stdout);
        defer a.free(result.stderr);
        var buf: [4096]u8 = undefined;
        var w = stdio.stderrWriter(io, &buf);
        w.interface.writeAll(result.stdout) catch {};
        w.interface.writeAll(result.stderr) catch {};
        w.interface.flush() catch {};
        return switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
    }
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = stdio.childStdout(),
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => 255,
    };
}

/// True when `argv` runs and exits 0; its output is discarded (doctor's
/// `pkg-config --exists`).
pub fn ok(io: std.Io, a: std.mem.Allocator, argv: []const []const u8) bool {
    const result = std.process.run(a, io, .{ .argv = argv }) catch return false;
    a.free(result.stdout);
    a.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}
