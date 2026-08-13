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

### MSYS2 static archives and Zig's MinGW CRT

MSYS2's static archives (`libfreetype.a`, `libharfbuzz.a`, …) reference CRT
symbols as dllimport (e.g. `__imp__setjmp`) that Zig's bundled MinGW CRT does
not export, so linking them fails with `lld-link: undefined symbol:
__declspec(dllimport) _setjmp`. `build.zig` works around this on Windows by
linking the DLL import libraries directly (`libfreetype.dll.a`,
`libharfbuzz.dll.a`); the symbols are resolved from `glfw3.dll`,
`libfreetype-6.dll`, `libharfbuzz-0.dll`, … at runtime, so `D:\msys64\mingw64\bin`
must stay on `PATH` when running examples.

## CI

The `windows smoke` job uses `msys2/setup-msys2`, installs the MinGW packages
above, fetches `wgpu-windows-x86_64-gnu-release` (same wgpu-native major as
Linux CI), and runs `zig build test` / `zig build`. GPU presentation is not
exercised in CI; the smoke is compile + headless unit tests.

## MSVC / vcpkg

MSVC + vcpkg can work if you assemble an equivalent prefix and adjust library
names, but the supported path today is MinGW GNU matching the CI job.
