# Linux build notes

zgpui on Linux uses GLFW + wgpu. Surfaces go through `linux_surface.zig`:

1. If GLFW reports **Wayland**, attach via `glfwGetWaylandDisplay` /
   `glfwGetWaylandWindow` → `NativeSurface.wayland_surface`.
2. If GLFW reports **X11**, attach via `glfwGetX11Display` /
   `glfwGetX11Window` → `NativeSurface.xlib_window`.
3. Older GLFW without `glfwGetPlatform`: try Wayland, then fall back to X11.

Both Wayland and X11 accessors are resolved with `dlsym` so the modules stay
linkable in cross-host tests; `wayland_surface` / `xlib_surface` expose
`resolve_fns` seams for harness injection (see unit tests).

## Dependencies

Typical packages (Debian/Ubuntu):

```bash
sudo apt-get install -y \
  libglfw3-dev libfreetype6-dev libharfbuzz-dev \
  fonts-dejavu-core
```

CI also installs wgpu-native (see `.github/workflows/ci.yml`). Point a local
build with `ZGPUI_PREFIX` at a wgpu-native unpack if headers/libs are not
under `/usr`.

## Wayland

Many distro `libglfw3` packages are **X11-only** and do not export
`glfwGetWayland*`. zgpui resolves those symbols at runtime with `dlsym`, so:

- X11-only GLFW still links and runs (X11 surface path).
- A Wayland-enabled GLFW that exports the accessors attaches a real wl_surface
  when `glfwGetPlatform()` is `GLFW_PLATFORM_WAYLAND`.

### Enabling Wayland GLFW

Install a GLFW build with Wayland support, or build from source:

```bash
cmake -S . -B build \
  -DGLFW_BUILD_WAYLAND=ON \
  -DGLFW_BUILD_X11=ON \
  -DBUILD_SHARED_LIBS=ON
cmake --build build
sudo cmake --install build
```

You also need Wayland client development packages (names vary by distro), e.g.
`libwayland-dev`, `libxkbcommon-dev`, and related scanner packages.

Force GLFW onto Wayland when both backends are available:

```bash
export GLFW_PLATFORM=wayland
# or before glfwInit: glfwInitHint(GLFW_PLATFORM, GLFW_PLATFORM_WAYLAND)
```

If the process is on Wayland but `glfwGetWayland*` is missing, window open
fails with `WaylandUnavailable` — install/link a Wayland-capable GLFW rather
than expecting an X11 fallback on an exclusive Wayland platform.

## IME

Typical distro GLFW builds do **not** expose composition callbacks, and GLFW
already owns the XIC on X11 — a second XIM client on the same window fights
that ownership. zgpui still calls optional `glfwSetIMECursorPos` / related
symbols from `setImePosition` when present. Full XIM / ibus composition text
events are not wired; use AppKit on macOS, Win32 Imm subclass on Windows, or
the harness `composition*` helpers in tests. See `docs/IME.md`.
