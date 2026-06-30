# labelle-sdl

The **SDL2** rendering backend for the [labelle](https://github.com/labelle-toolkit) 2D engine, as an **out-of-tree pluggable backend** (labelle-assembler#386).

Desktop-only, loop-style. SDL2 window + SDL_Renderer; gamepad via SDL's GameController API; audio via SDL_mixer.

## Use it
```zig
.backend = .sdl,
.backend_package = .{ .name = "sdl", .repo = "github.com/labelle-toolkit/labelle-sdl", .version = "0.1.0" },
```
(With the default-flip, `.backend = .sdl` resolves here automatically.)

## Layout
- `src/` — the four backend modules: `gfx`, `window`, `input`, `audio`
- `backend.manifest.zon` + `build_fragments/` — drive the assembler's manifest-splice codegen
- `templates/desktop.txt` — the generated run-loop
- `build_helpers.zig` — SDL link/discovery helpers (host-tested)
- `example/` — a standalone SDL demo

## Build
```sh
zig build test          # host + backend tests (needs SDL2 + SDL2_mixer)
cd example && zig build  # the demo
```
