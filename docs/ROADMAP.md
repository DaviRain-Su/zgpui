# zgpui roadmap

Status relative to the **0.1.0** “usable for prototypes” milestone (macOS
first). Items below are **not** API commitments.

## Done (0.1.0)

- GPUI-inspired core: platform vtable, scene/WGSL, text, Yoga, element phases,
  App/Entity, overlays, animation, dirty/partial present hooks, hotkeys, HUD
- GLFW backend (macOS / Linux / **Windows HWND scaffolding**)
- AppKit + CAMetalLayer backend (macOS), IME marked text, AX press bridge
- base-gpui-style headless component catalog + harness tests
- Examples `01`–`07`, docs (`ARCHITECTURE`, `IME`, `CHANGELOG`)
- CI: macOS + Linux (`zig build test` / `zig build`)

## Next (post-0.1)

| Priority | Item | Notes |
| --- | --- | --- |
| P0 | Keep Linux CI green | timespec + font path leaks addressed; watch Ubuntu job |
| P1 | Windows CI + real smoke | HWND path is wired; needs runner with GLFW/wgpu/FT/HB |
| P1 | Linux desktop validation | X11 path live; Wayland wgpu surface type ready, GLFW Wayland symbols gated until Wayland GLFW recipe |
| P2 | Full GLFW IME composition | Stable GLFW has no cross-platform composition API; AppKit is the reference. Future: OS-specific (XIM / Win32 IME) or GLFW forks |
| P2 | Stronger a11y | Labels, hierarchy, TextArea, slider adjust, text caret/selection, AX set-value/selected-text/range setters + notifications landed; rotors remain |
| P3 | Incremental layout/paint | Skip clean frames + hover region dirty when `partial_present`; CPU still full rebuild when dirty |
| P3 | CoreText / richer fonts | Optional beside FreeType |
| P3 | GPUI-like module split | `props` / `context` / `runtime` / `layers` naming parity |
| — | Native WinUI/Win32 widget backend | **Out of scope** — zgpui stays self-drawn UI on native windowing |

## Explicit non-goals (near term)

- Shipping system controls (`NSButton`, Win32 BUTTON, GTK widgets)
- API freeze / semver-strict stability before 0.2+
- Matching Zed `crates/gpui` line-for-line

## How to contribute against this list

1. Prefer harness tests (`zig build test`) over GPU-only demos.
2. Platform work goes behind `Platform` / `PlatformWindow` / `NativeSurface`.
3. Update this file when closing a row or discovering a new blocker.
