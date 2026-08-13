# Windows build notes

zgpui draws with wgpu on a GLFW Win32 HWND (`NativeSurface.win32_hwnd`). There
is no WinUI / Win32 widget backend.

## Recommended layout (CI and local)

1. Install **MSYS2** MinGW packages for GLFW, FreeType, and HarfBuzz.
2. Download a **wgpu-native** Windows GNU release zip and unpack it to a prefix
   (headers under `include/`, `include/webgpu/`; import libs under `lib/`).
3. Point the build at that prefix and the MinGW root:

```bash
export ZGPUI_PREFIX="$HOME/wgpu-native"
export MSYSTEM_PREFIX="/mingw64"   # set automatically inside MSYS2 MinGW64
# Ensure DLLs resolve at runtime:
export PATH="$MSYSTEM_PREFIX/bin:$ZGPUI_PREFIX/lib:$ZGPUI_PREFIX/bin:$PATH"
zig build test -Dtarget=x86_64-windows-gnu --summary all
zig build -Dtarget=x86_64-windows-gnu
```

`build.zig` reads `ZGPUI_PREFIX` for wgpu-native and `MSYSTEM_PREFIX` for the
MinGW include/lib trees. Prefer `-Dtarget=x86_64-windows-gnu`.

On Windows GNU, GLFW / FreeType / HarfBuzz / wgpu-native are linked via their
`lib*.dll.a` import libraries (not static `.a` archives). Transitive codec
deps stay inside those DLLs at runtime. The build also links `imm32` for
caret positioning (`ImmSetCompositionWindow` via `platform/win32_ime.zig`).

## IME

GLFW does not expose composition text callbacks on Windows. zgpui still calls
`ImmSetCompositionWindow` from `PlatformWindow.setImePosition` so the OS
candidate window tracks the text caret. Full Imm/TSF composition events remain
a follow-up (see `docs/IME.md`).

## CI

The `test (windows-gnu)` job uses `msys2/setup-msys2`, installs the MinGW
packages above, fetches `wgpu-windows-x86_64-gnu-release` (same wgpu-native
major as Linux CI), and runs `zig build test` / `zig build` with
`-Dtarget=x86_64-windows-gnu`. GPU presentation is not exercised in CI. The
job is required (same as macOS/Linux).

**Zig 0.16 note:** `lld-link` fails on MinGW *static* FreeType/HarfBuzz with
`undefined symbol: __declspec(dllimport) _setjmp`. Disabling LLD
(`use_lld=false`) hits a separate LLVM “emit path is a directory” bug.
Linking the import libs directly avoids both issues.

## MSVC / vcpkg

MSVC + vcpkg can work if you assemble an equivalent prefix and adjust library
names, but the supported path today is MinGW GNU matching the CI job.
