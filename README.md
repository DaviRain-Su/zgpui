# zgpui

A GPUI-inspired UI framework for Zig, plus a base-gpui-style headless
component layer on top.

- Framework architecture follows [gpui](https://github.com/zed-industries/zed/tree/main/crates/gpui)
  (element system, scene primitives, entity/context model).
- Component APIs follow [base-gpui](https://github.com/LukeTandjung/base-gpui)
  (compound parts, controlled/uncontrolled state, style states).

## Requirements

- Zig 0.16.0
- **macOS** (Apple Silicon or Intel): Homebrew packages

```sh
brew install glfw wgpu-native freetype harfbuzz
```

- **Linux** (x86_64, X11; Wayland when GLFW exports `glfwGetWayland*`):
  distro packages — see [docs/LINUX.md](docs/LINUX.md)

```sh
# Debian / Ubuntu
sudo apt install libglfw3-dev libfreetype6-dev libharfbuzz-dev libx11-dev

# wgpu-native is not packaged on most distros — build or install manually, e.g.:
#   https://github.com/gfx-rs/wgpu-native/releases
# Then set the prefix if headers/libs are not under /usr:
export ZGPUI_PREFIX=/path/to/wgpu-native/prefix   # optional
# or: export HOMEBREW_PREFIX=... on Linux if you use a Homebrew-style layout
```

- **Windows** (x86_64): MSYS2 MinGW + wgpu-native GNU — see
  [docs/WINDOWS.md](docs/WINDOWS.md). Full link remains experimental on Zig 0.16.

Override library search paths when headers or `.so` / `.dll` / `.lib` files
live outside the default prefix (`/opt/homebrew` on macOS, `/usr` on Linux):

```sh
export ZGPUI_PREFIX=/custom/prefix
# or
export HOMEBREW_PREFIX=/custom/prefix
```

## Building

```sh
zig build                 # library + examples
zig build test            # unit tests (no window/GPU required)
zig build run-01_window   # GLFW clear-color smoke test
zig build run-02_ui       # full UI demo (components + text)
zig build run-03_native   # native AppKit + CAMetalLayer (macOS only)
zig build run-04_components  # component gallery
zig build run-05_advanced    # split + tree + color picker
zig build run-06_kitchen_sink # hotkeys + palette + dialog + virtual list
zig build run-07_app_template # minimal starter app (copy this)
```

Cross-compile for Linux from macOS (or vice versa):

```sh
zig build -Dtarget=x86_64-linux
zig build test -Dtarget=x86_64-linux
```

Version **0.1.0** — see [docs/CHANGELOG.md](docs/CHANGELOG.md).
Post-0.1 backlog: [docs/ROADMAP.md](docs/ROADMAP.md).

## Architecture (bottom → top)

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for design intent (immediate
mode, overlays, animation, a11y, dirty/partial present) and
[docs/A11Y.md](docs/A11Y.md) for the native accessibility snapshot contract.

| Layer | Path | Responsibility |
|-------|------|----------------|
| Geometry / color | `src/geometry.zig`, `src/color.zig` | `Point`/`Size`/`Bounds`, `Rgba`/`Hsv` |
| Platform | `src/platform.zig`, `src/platform/` | Window/input vtable; GLFW + AppKit backends; IME composition; clipboard OS bridge; AppKit AX sync |
| GPU | `src/renderer/` | wgpu surface, scene renderer, WGSL shaders |
| Scene | `src/scene.zig`, `src/path.zig` | Quads, shadows, sprites, paths |
| Text | `src/text/` | FreeType + HarfBuzz + glyph atlas; macOS CoreText name/UI resolve |
| Layout | `src/layout/` | Yoga flexbox |
| Element | `src/element.zig`, `src/elements/` | Three-phase tree (`requestLayout` → `prepaint` → `paint`); Div / Text / Scroll / TextInput / TextArea |
| App / value | `src/app.zig`, `src/value.zig`, `src/clipboard.zig` | `Entity(T)`, `Value`/`FieldValue`, in-memory + OS clipboard |
| Overlay | `src/overlay.zig` | Modal/non-modal layers, focus trap, z-order |
| Animation / dirty | `src/animation.zig`, `src/dirty.zig` | Timeline tweens/springs; dirty union / optional partial present |
| A11y | `src/a11y.zig` | Roles, frame-local names/hierarchy, overlay isolation, AppKit AX bridge |
| Window | `src/window.zig` | Ties platform + GPU + elements + overlays + timeline |
| Naming modules | `src/props.zig`, `context.zig`, `runtime.zig`, `layers.zig` | Optional GPUI-style namespaces (`zgpui.props` …); flat API unchanged |
| Components | `src/components/` | Headless base-gpui-style controls |
| Testing | `src/testing.zig` | Headless harness (synthetic input, overlays, a11y queries) |

## Component catalog

Aligned with [base-gpui](https://github.com/LukeTandjung/base-gpui) docs (headless Zig APIs; aliases in parentheses).

**Inputs:** `button`, `checkbox`, `checkbox_group`, `switch_` (`toggle`), `slider`, `radio_group`, `toggle_group`, `text_field` (`input`), `textarea`, `number_input` (`number_field`), `otp_field`, `autocomplete`, `form`, `field`, `fieldset`

**Overlays:** `dialog`, `alert_dialog`, `drawer`, `sheet`, `tooltip`, `hover_card`, `preview_card`, `popover`, `menu`, `menubar`, `context_menu`, `select`, `combobox`, `command_palette`, `toast`, `datepicker`

**Navigation / chrome:** `tabs`, `navigation_menu`, `toolbar`, `breadcrumb`, `pagination`, `link`, `label`, `badge`, `avatar`, `skeleton`, `spinner`, `kbd`, `aspect_ratio`, `separator`, `progress`, `meter`

**Structure / data:** `collapsible`, `accordion`, `scroll_area`, `resizable`, `tree`, `list`, `table`, `calendar`, `color_picker`

Most interactive components support controlled/uncontrolled state via `value.Value(T)` or `FieldValue(Store, "field")`. Overlay components optionally take `timeline: ?*Timeline` for fade-in.

## Zig idioms used

- **Comptime generics:** `Entity(T)`, `Value(T)`, `FieldValue(Store, "field")`, `Point(T)` / `Bounds(T)`
- **Compile-time reflection:** `@hasDecl` (`asElement`), `@FieldType`/`@field`, `std.meta.hasFn`, `inline for` over enums
- **Type erasure:** Element vtables; platform/window vtables; entity storage via `@typeName`

## Partial present (experimental)

```zig
window.partial_present = true;
window.markDirtyBounds(bounds); // prefer over markDirty() when bounds known
```

Default is off (full Clear each dirty frame). Partial mode uses Load + scissor and
culls CPU paint/scene inserts outside the dirty union; layout/prepaint still run
when the frame is dirty. Hover enter/leave automatically dirties only the
previous and next hit targets instead of the whole window. ScrollView offset
changes request a regional redraw of the viewport. Examples `02` / `04`–`07`
enable `partial_present` by default.

## License

MIT
