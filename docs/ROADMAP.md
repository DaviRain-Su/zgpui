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

## Done (post-0.1)

| Item | Notes |
| --- | --- |
| Windows CI + GNU smoke | MinGW + wgpu-native import libs; required `test (windows-gnu)` job |
| Linux desktop attach | X11 + Wayland via `dlsym` + `resolve_fns` harness tests |
| Win32 Imm32 IME | HWND subclass composition on GLFW Windows |
| Stronger a11y (catalog) | Roles, AppKit maps, live regions, adjustable scrollbar/splitter, control `label`s |
| Incremental layout/paint | `partial_present` default on; retained tree; harness retain + paint_clip |
| CoreText font resolve | macOS `loadUiFont` / `loadSystemFont` → FreeType; shaping still HB |
| GPUI-like module split | `zgpui.props` / `context` / `runtime` / `layers` re-exports |
| gpui-base port phases 1–6 | Positioner, variable list, scrollbar, searchable list, sidebar/dock/tiles, plot/markdown/code_input — see [`PORT_GPUI_COMPONENT.md`](PORT_GPUI_COMPONENT.md) |
| Optional comet-kit theme tokens | `src/theme.zig` + OKLCH helpers in `color.zig` — apps opt in; catalog stays headless |
| Optional comet-kit icons + Geist | `src/icons.zig` / `src/fonts.zig` + `src/assets/` — SVG bytes + FT memory faces |
| Theme paint helpers | `ink` / `hairline` / `wash` / `scrim` / `band` + `Theme.glass*` — appearance-aware fills |
| SVG icon rasterizer | `src/svg.zig` via vendored NanoSVG → alpha masks for monochrome sprites |
| SVG icon paint helper + selection recipes | NanoSVG rasterizer; glass/card selected fills + inset rings |
| Icon element + theme kit example | `elements/icon.zig`; `examples/08_theme_kit.zig` |

## Remaining / ongoing

| Priority | Item | Notes |
| --- | --- | --- |
| P0 | Keep Linux CI green | Ongoing watch of Ubuntu job (not a finite feature) |
| P2 | Full GLFW IME on Linux | **Blocked:** Linux XIM while GLFW owns the XIC — needs GLFW IME PR / custom build. AppKit + Win32 Imm shipped. |
| P2 | Deeper VoiceOver / AX polish | Catalog + AppKit bridge are usable; full VoiceOver parity is open-ended |
| — | Native WinUI/Win32 widget backend | **Out of scope** — zgpui stays self-drawn UI on native windowing |

## Explicit non-goals (near term)

- Shipping system controls (`NSButton`, Win32 BUTTON, GTK widgets)
- API freeze / semver-strict stability before 0.2+
- Matching Zed `crates/gpui` line-for-line
- Full LSP client / CommonMark HTML tables / Path-painted charts (see port doc)

## How to contribute against this list

1. Prefer harness tests (`zig build test`) over GPU-only demos.
2. Platform work goes behind `Platform` / `PlatformWindow` / `NativeSurface`.
3. Update this file when closing a row or discovering a new blocker.
