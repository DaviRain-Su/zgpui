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
| P1 | Windows CI + real smoke | MinGW + wgpu-native GNU; link via `lib*.dll.a` import libs (Zig 0.16 LLD); smoke job green |
| P1 | Linux desktop validation | X11 path live; Wayland attach resolves `glfwGetWayland*` via `dlsym` (`docs/LINUX.md`); CI stays on X11-only distro GLFW |
| P2 | Full GLFW IME composition | AppKit is the reference. Win32 Imm32 **caret + composition text** (HWND subclass) shipped; Linux still needs XIM/ibus |
| P2 | Stronger a11y | Labels, hierarchy, text edit/selection, state/subroles, notifications, live announcements, semantic rotors, author rotor groups, and nav_order overrides landed |
| P3 | Incremental layout/paint | Skip clean frames; partial present + paint_clip; **hover + ScrollView regional dirty**; layout/prepaint still full when dirty |
| P3 | CoreText / richer fonts | Optional beside FreeType |
| P3 | GPUI-like module split | `props` / `context` / `runtime` / `layers` naming parity |
| P2 | Port gpui-base Positioner / VirtualList / Dock | See [`PORT_GPUI_COMPONENT.md`](PORT_GPUI_COMPONENT.md) — phases 1–6 done (plot/markdown/code_input headless) |
| — | Native WinUI/Win32 widget backend | **Out of scope** — zgpui stays self-drawn UI on native windowing |

## Explicit non-goals (near term)

- Shipping system controls (`NSButton`, Win32 BUTTON, GTK widgets)
- API freeze / semver-strict stability before 0.2+
- Matching Zed `crates/gpui` line-for-line

## How to contribute against this list

1. Prefer harness tests (`zig build test`) over GPU-only demos.
2. Platform work goes behind `Platform` / `PlatformWindow` / `NativeSurface`.
3. Update this file when closing a row or discovering a new blocker.
