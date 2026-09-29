# labelle-sdl

The **SDL2** rendering backend for the [labelle](https://github.com/labelle-toolkit) 2D engine, as an **out-of-tree pluggable backend** (labelle-assembler#386).

Desktop-only, loop-style. SDL2 window + SDL_Renderer; gamepad via SDL's GameController API; audio via SDL_mixer.

## Use it
```zig
.backend = .sdl,
.backend_package = .{ .name = "sdl", .repo = "github.com/labelle-toolkit/labelle-sdl", .version = "0.1.0" },
```
(With the default-flip, `.backend = .sdl` resolves here automatically.)

## The `sdl2` provider
This package is also the labelle-cli **`sdl2` provider** (`plugin.labelle`, RFC labelle-cli#471 S1), which took over what the CLI did in `sdl_provision.zig`. It is opt-in and works with any backend whose desktop build links SDL2 — the `sdl` renderer, and raylib / sokol / bgfx for their gamepad source:
```zig
.plugins = .{ .{ .name = "sdl2", .repo = "github.com/labelle-toolkit/labelle-sdl", .version = "<v>" } },
```
- **`env` hook** (before `generate`, `desktop`): on a **Windows** host, when the project needs SDL2 and `LABELLE_SDL2_LIB` isn't already set, downloads the pinned SDL2 2.30.11 MinGW dev package (SHA-256 checked) into the provider cache (`~/.labelle/providers/…/sdl2-v1/<host>/…`, locked, staged, renamed into place) and hands the build `LABELLE_SDL2_LIB` (plus the same dir on PATH) through `env_file`. On Linux and macOS it does nothing: the system / Homebrew SDL2 is used as before.
- **`stage` hook** (after `build`, `desktop`): on Windows, copies `SDL2.dll` next to the built exe (`<target_dir>/zig-out/bin`), from `LABELLE_SDL2_LIB` as the build saw it or the cache.
- **`labelle sdl2 doctor [--json] [--fix]`**: the library / runtime DLL / headers / SDL2_mixer rows (headers and mixer only for the `sdl` backend). **`labelle sdl2 install`**: provision now (Windows), or print the package-manager command.

"Needs SDL2" is read from `project.labelle`, the CLI's `wants_sdl2` rule: backend `sdl`, or raylib / sokol / bgfx without `.gamepad = .none` (backend = `.backend`, else `.backend_package.name`, else `bgfx`). SDL2_mixer is not provisioned (as before): on Windows it comes with your own `LABELLE_SDL2_LIB`.

The tool is `tools/` (std only; `zig build install-provider` / `zig build test-provider`). The plugin's module, `labelle_sdl2`, is empty.

## Layout
- `src/` — the four backend modules: `gfx`, `window`, `input`, `audio`
- `backend.manifest.zon` + `build_fragments/` — drive the assembler's manifest-splice codegen
- `templates/desktop.txt` — the generated run-loop
- `build_helpers.zig` — SDL link/discovery helpers (host-tested)
- `example/` — a standalone SDL demo
- `plugin.labelle` + `tools/` — the `sdl2` provider (above)

## Build
```sh
zig build test          # host + backend + provider tests (needs SDL2 + SDL2_mixer)
zig build test-provider # provider tests only (no SDL2 needed)
cd example && zig build  # the demo
```
