//! Compile-proof that this backend satisfies labelle-core's contracts
//! (labelle-assembler#502). Mirrors the check the assembler emits into every
//! generated main.zig (assembler src/codegen/blocks/imports.zig).
const core = @import("labelle_core");
const window = @import("window");
const input = @import("input");
const gfx = @import("gfx");

/// Force every wrapper method body of a labelle-core typed wrapper to be
/// semantically analyzed at comptime. Merely instantiating `core.Backend(gfx)`
/// re-runs the name-shape `assertBackend`, but the inline method bodies — where
/// the conversions to the contract value types (`DecodedImage`, `Texture`, …)
/// live — are analyzed lazily, only when referenced. Referencing each one here
/// makes a SIGNATURE/type drift between a backend decl and the contract fail at
/// this proof instead of only later in a generated adapter (codex/#502 review).
fn forceMethods(comptime T: type) void {
    for (@typeInfo(T).@"struct".decls) |decl| {
        const member = @field(T, decl.name);
        if (@typeInfo(@TypeOf(member)) == .@"fn") _ = &member;
    }
}

comptime {
    // Decl-shape proof: the required method NAMES exist.
    core.assertWindow(window);
    core.assertInput(input);
    core.assertBackend(gfx);

    // Type/signature proof: instantiate the typed wrappers the generated adapter
    // uses AND force their method bodies, so a decl whose signature drifts from
    // the contract value types is caught here. Compile-only — no runtime, no I/O.
    forceMethods(core.Backend(gfx));
    forceMethods(core.Window(window));
    forceMethods(core.InputInterface(input));
}

// Loop-style backend: shouldQuit must be present (drives ownsLoop() and the
// splice's loop-vs-callback entry choice, in step with manifest loop_style).
comptime {
    if (!@hasDecl(window, "shouldQuit")) @compileError("loop-style backend must declare shouldQuit");
}

test "behavioral window conformance" {
    try core.conformance.runWindowSuite(window);
}
