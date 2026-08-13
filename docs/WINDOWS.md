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
zig build test --summary all
zig build
```

`build.zig` reads `ZGPUI_PREFIX` for wgpu-native and `MSYSTEM_PREFIX` for the
MinGW include/lib trees. On Windows it links `glfw3` (MinGW) rather than
`glfw`.

## CI

The `windows smoke` job uses `msys2/setup-msys2`, installs the MinGW packages
above, fetches `wgpu-windows-x86_64-gnu-release` (same wgpu-native major as
Linux CI), and runs `zig build test` / `zig build`. GPU presentation is not
exercised in CI; the smoke is compile + headless unit tests.

## MSVC / vcpkg

MSVC + vcpkg can work if you assemble an equivalent prefix and adjust library
names, but the supported path today is MinGW GNU matching the CI job.
