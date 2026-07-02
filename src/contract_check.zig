//! Compile-proof that this backend satisfies labelle-core's contracts
//! (labelle-assembler#502). Mirrors the check the assembler emits into every
//! generated main.zig (assembler src/codegen/blocks/imports.zig).
const core = @import("labelle_core");
const window = @import("window");
const input = @import("input");
const gfx = @import("gfx");

comptime {
    core.assertWindow(window);
    core.assertInput(input);
    core.assertBackend(gfx);
}

// Loop-style backend: shouldQuit must be present (drives ownsLoop() and the
// splice's loop-vs-callback entry choice, in step with manifest loop_style).
comptime {
    if (!@hasDecl(window, "shouldQuit")) @compileError("loop-style backend must declare shouldQuit");
}

test "behavioral window conformance" {
    try core.conformance.runWindowSuite(window);
}
