/// Shared SDL2 C import — all backend modules import this to avoid opaque type mismatch.
///
/// SDL_DISABLE_ARM_NEON_H prevents SDL_cpuinfo.h from transitively including
/// <arm_neon.h>. On macOS arm64 + Zig 0.16, the bundled clang ships an
/// arm_neon.h that uses the FP8 type `__mfp8`, but the matching `+fp8`
/// target feature isn't enabled by default — leading to 5000+ translation
/// errors (`unknown type 'mfloat8x8_t'`, `unknown builtin '__builtin_neon_*'`).
/// We don't use NEON intrinsics from Zig, so disabling the header is safe;
/// SDL still uses NEON internally in its precompiled library.
pub const c = @cImport({
    @cDefine("SDL_DISABLE_ARM_NEON_H", "1");
    @cInclude("SDL2/SDL.h");
});
