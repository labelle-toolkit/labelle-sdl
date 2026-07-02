/// SDL2 window backend — windowing lifecycle functions.
const c = @import("sdl").c;
const audio = @import("audio");
const gfx = @import("gfx");
const input = @import("input");

// Contract-version tag (labelle-assembler#453 item 1). The assembler emits a
// directional `@compileError` version assert in the generated game's main.zig
// comparing this against labelle-core's `WINDOW_CONTRACT_VERSION`. v1 is the
// initial revision. This module satisfies the window contract's required
// core (width/height/frameDuration/requestQuit) and is a loop-model backend
// (it declares `shouldQuit`).
pub const targets_window_contract: u32 = 1;

pub const ConfigFlags = struct {
    window_hidden: bool = false,
};

var sdl_window: ?*c.SDL_Window = null;
var should_close: bool = false;
var target_fps_val: i32 = 60;
var last_frame_time: u64 = 0;
var frame_dur_last: u64 = 0; // baseline for the canonical frameDuration() dt source
var frame_dur_seconds: f64 = 1.0 / 60.0; // cached per-frame dt; updated once per beginFrame
var window_hidden: bool = false;

pub fn setConfigFlags(flags: ConfigFlags) void {
    window_hidden = flags.window_hidden;
}

pub fn initWindow(width_px: i32, height_px: i32, title: [:0]const u8) void {
    // Clear any latched state so a close→reopen starts clean (the canonical
    // `requestQuit` and the `SDL_QUIT` event both set `should_close`).
    should_close = false;
    _ = c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO | c.SDL_INIT_GAMECONTROLLER);
    // Bring up the gamepad subsystem and enumerate already-connected pads.
    input.initGamepads();
    const window_flags: u32 = if (window_hidden) c.SDL_WINDOW_HIDDEN else c.SDL_WINDOW_SHOWN;
    sdl_window = c.SDL_CreateWindow(
        title.ptr,
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        width_px,
        height_px,
        window_flags,
    );
    if (sdl_window) |win| {
        const renderer = c.SDL_CreateRenderer(win, -1, c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC);
        // Enable alpha blending for the renderer's primitive draw path so
        // translucent fills (drawTriangle/drawPolygon/drawCircle/drawLine/
        // drawRectangleRec with tint.a < 255) composite correctly. Without
        // this SDL_RenderDrawLine/FillRect ignore alpha and render opaque.
        // Textures set their own blend mode separately; blend-on is the
        // expected default for 2D and does not regress opaque primitives.
        if (renderer) |ren| _ = c.SDL_SetRenderDrawBlendMode(ren, c.SDL_BLENDMODE_BLEND);
        gfx.sdl_renderer = renderer;
        gfx.setScreenSize(width_px, height_px);
    }
    const now = c.SDL_GetPerformanceCounter();
    last_frame_time = now;
    frame_dur_last = now; // reset the frameDuration() baseline too
    frame_dur_seconds = 1.0 / 60.0; // and its cached value, so a re-open starts clean
}

pub fn closeWindow() void {
    input.deinitGamepads(); // close controllers before SDL_Quit
    audio.deinit(); // close mixer before SDL_Quit
    gfx.cleanup(); // release textures before destroying the renderer
    if (gfx.sdl_renderer) |r| c.SDL_DestroyRenderer(r);
    if (sdl_window) |w| c.SDL_DestroyWindow(w);
    c.SDL_Quit();
    gfx.sdl_renderer = null;
    sdl_window = null;
}

// ── Canonical window contract (labelle-core/src/window_contract.zig) ─────
// The uniform window surface the pluggable-backends contract standardizes on
// (labelle-assembler#386) — the SDL backend's only window surface. SDL is a
// *loop-style* backend (it owns `while (!shouldQuit())`), so it declares
// `shouldQuit` — whose presence signals loop-ownership to the splice.

/// Current framebuffer width (physical px).
pub fn width() i32 {
    return gfx.getScreenWidth();
}
/// Current framebuffer height (physical px).
pub fn height() i32 {
    return gfx.getScreenHeight();
}
/// Seconds elapsed for the last frame — the engine's `dt` source. Returns the
/// value cached by `beginFrame` (computed once per frame), so this is
/// idempotent: repeated calls within a frame all report the same dt. Seeded to
/// 1/60 until the first frame completes; reset in `initWindow`.
pub fn frameDuration() f64 {
    return frame_dur_seconds;
}
/// Ask the run loop to end. Latches the same `should_close` flag the `SDL_QUIT`
/// event sets, which `shouldQuit` reports (no behavior change unless a
/// script/engine calls this).
pub fn requestQuit() void {
    should_close = true;
}
/// Whether the run loop should end. Reports the `should_close` flag latched by
/// the `SDL_QUIT` event or `requestQuit`. Its presence marks SDL as a
/// loop-model backend (`Window(Impl).ownsLoop()`).
pub fn shouldQuit() bool {
    return should_close;
}

/// Query whether the window is currently fullscreen. Mirrors the
/// sokol/raylib/bgfx backends' `isFullscreen`. SDL stores the mode in the
/// window flags; we treat either the desktop ("fake" borderless) or real
/// video-mode fullscreen bit as fullscreen. Returns false before the
/// window exists.
pub fn isFullscreen() bool {
    const win = sdl_window orelse return false;
    const flags = c.SDL_GetWindowFlags(win);
    return (flags & (c.SDL_WINDOW_FULLSCREEN | c.SDL_WINDOW_FULLSCREEN_DESKTOP)) != 0;
}

/// Switch the window to fullscreen (`on=true`) or windowed (`on=false`).
/// The generated frame loop polls `g.takeFullscreenRequest()` and calls
/// this when a script flipped `game.setFullscreen`. Unlike raylib/sokol's
/// toggle-only API, SDL takes the target mode directly; we still guard on
/// the current state so the call is idempotent. Uses
/// `SDL_WINDOW_FULLSCREEN_DESKTOP` (borderless desktop-resolution
/// fullscreen) — it avoids a video-mode switch and matches the windowed
/// pixel layout the renderer is already configured for. No-op before the
/// window exists.
pub fn setFullscreen(on: bool) void {
    const win = sdl_window orelse return;
    if (isFullscreen() == on) return;
    const flags: u32 = if (on) c.SDL_WINDOW_FULLSCREEN_DESKTOP else 0;
    _ = c.SDL_SetWindowFullscreen(win, flags);
    // The drawable area just changed (desktop resolution in fullscreen, window
    // size back in windowed). Re-sync the stored screen size immediately so the
    // scanline clip bounds in gfx.drawPolygon/fillTriangleScreen — and the
    // window-contract width()/height() — reflect the new framebuffer this same
    // frame, before any shapes are drawn into the expanded area.
    gfx.refreshOutputSize();
}

pub fn setTargetFPS(fps: i32) void {
    target_fps_val = fps;
}

pub fn beginFrame() void {
    // Compute this frame's dt ONCE here (the per-frame entry) and cache it, so
    // `frameDuration()` is idempotent — safe to query any number of times per
    // frame and always returns the same value. (Updating the baseline inside
    // frameDuration() itself made a 2nd call/frame return ~0.)
    const freq = c.SDL_GetPerformanceFrequency();
    const now = c.SDL_GetPerformanceCounter();
    if (freq != 0 and frame_dur_last != 0) {
        frame_dur_seconds = @as(f64, @floatFromInt(now - frame_dur_last)) / @as(f64, @floatFromInt(freq));
    }
    frame_dur_last = now;

    // Clear per-frame keyboard/mouse edges, then pump events (which refreshes
    // SDL's controller state), then snapshot gamepad button edges. Snapshotting
    // after the pump keeps "pressed" detection from lagging a frame.
    input.newFrame();
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event) != 0) {
        if (event.type == c.SDL_QUIT) {
            should_close = true;
        } else if (event.type == c.SDL_WINDOWEVENT and
            (event.window.event == c.SDL_WINDOWEVENT_SIZE_CHANGED or
                event.window.event == c.SDL_WINDOWEVENT_RESIZED))
        {
            // Drawable area changed (fullscreen transition, HiDPI, or a manual
            // resize): keep the stored screen size current so gfx scanline clip
            // bounds don't go stale and clip away legitimately on-screen shapes.
            gfx.refreshOutputSize();
        }
        input.handleEvent(&event);
    }
    input.snapshotGamepads();
}

pub fn endFrame() void {
    if (gfx.sdl_renderer) |r| c.SDL_RenderPresent(r);

    // Frame timing
    if (target_fps_val > 0) {
        const freq = c.SDL_GetPerformanceFrequency();
        const now = c.SDL_GetPerformanceCounter();
        const elapsed = now - last_frame_time;
        const target_ticks = freq / @as(u64, @intCast(target_fps_val));
        if (elapsed < target_ticks) {
            const delay_ms: u32 = @intCast((target_ticks - elapsed) * 1000 / freq);
            c.SDL_Delay(delay_ms);
        }
        last_frame_time = c.SDL_GetPerformanceCounter();
    }
}

pub fn clearBackground(r: u8, g: u8, b: u8, a: u8) void {
    if (gfx.sdl_renderer) |ren| {
        _ = c.SDL_SetRenderDrawColor(ren, r, g, b, a);
        _ = c.SDL_RenderClear(ren);
    }
}

pub fn drawText(text: [:0]const u8, x: i32, y: i32, font_size: i32, r: u8, g: u8, b: u8, a: u8) void {
    gfx.drawText(text, @floatFromInt(x), @floatFromInt(y), @floatFromInt(font_size), gfx.color(r, g, b, a));
}
