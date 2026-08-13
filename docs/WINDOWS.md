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
zig build test -Dtarget=x86_64-windows-gnu --summary all
zig build -Dtarget=x86_64-windows-gnu
```

`build.zig` reads `ZGPUI_PREFIX` for wgpu-native and `MSYSTEM_PREFIX` for the
MinGW include/lib trees. On Windows it links `glfw3` (MinGW) rather than
`glfw`, plus FreeType/HarfBuzz transitive libs (`graphite2`, `z`, `bz2`,
`dwrite`, …). Prefer the `x86_64-windows-gnu` target so Zig uses the MinGW
linker instead of `lld-link` against MSVC.

## CI

The `windows smoke (experimental)` job uses `msys2/setup-msys2`, installs the
MinGW packages above, fetches `wgpu-windows-x86_64-gnu-release` (same
wgpu-native major as Linux CI), and runs `zig build test` / `zig build` with
`-Dtarget=x86_64-windows-gnu`. GPU presentation is not exercised in CI.

**Current blocker (Zig 0.16):** linking MinGW FreeType/HarfBuzz archives with
Zig's `lld-link` fails on CRT imports such as `_setjmp`. Setting
`use_lld = false` hits a separate LLVM “emit path is a directory” bug on the
Windows host. The job is `continue-on-error` until one of those toolchain
issues is resolved; macOS/Linux remain required.

## MSVC / vcpkg

MSVC + vcpkg can work if you assemble an equivalent prefix and adjust library
names, but the attempted path today is MinGW GNU matching the CI job.
