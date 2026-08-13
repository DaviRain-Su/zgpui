# Changelog

All notable changes to zgpui are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Linux / Zig 0.16: `profile` monotonic clock uses `timespec.sec` / `.nsec`
  (CI compile failure on Ubuntu).
- Linux CI: text field/textarea tests leaked `FontSystem` when macOS-only
  font paths failed before `defer deinit`; shared `loadTestFont` + DejaVu
  paths + `errdefer`, and install `fonts-dejavu-core` in CI.
- AppKit AX selected-range writes reject reversed, out-of-bounds, overflowed,
  UTF-8 continuation-byte, and UTF-16 mid-surrogate ranges without mutation.
- AppKit AX proxies use the protocol's `isAccessibilityEnabled` /
  `isAccessibilityFocused` getters, and native notifications now receive
  `NSString` names instead of raw C-string pointers.

### Added
- Windows GLFW scaffolding: `NativeSurface.win32_hwnd` + `win32_surface.zig`
  + wgpu `WGPUSurfaceSourceWindowsHWND` (untested on hardware).
- Linux Wayland surface path (`wayland_surface` / `linux_surface` dispatch).
- A11y `parent_id` hierarchy (Div prepaint + AppKit root/children proxies).
- Native a11y snapshots now include overlays with topmost-modal isolation;
  AXPress routes through visible overlay frames, exposes only concrete enabled
  actions, and covers switches, radios, tabs, and selectable list/tree rows.
- Dialog, sheet, tooltip, and command-palette surfaces expose container roles
  and names; command-palette search/list/items expose values and selection.
- Accessible names now resolve chained `labelled_by` and inverse Label
  `for_id` relationships within their source frame, with cycle safety and
  cross-overlay isolation; TextInput/TextArea expose names, values, hierarchy,
  and distinct AppKit text-field/text-area roles.
- Text fields expose caret/selection UTF-8 offsets (and AppKit selected-text
  attributes); sliders expose numeric min/max/value plus AXIncrement/Decrement
  routed through the same keyboard step path as arrow keys.
- AppKit `setAccessibilityValue:` replaces editable text via select-all +
  insert/delete; sync posts `AXValueChanged` / `AXSelectedTextChanged` when
  snapshot values or selections change. TextArea gains Cmd/Ctrl editing
  shortcuts (select-all / copy / cut / paste / undo).
- AppKit `setAccessibilitySelectedText:` / `setAccessibilitySelectedTextRange:`
  replace the selection or move the caret (UTF-16 ranges convert at the bridge).
- AppKit exposes selected/expanded getters and switch/search/dialog/tab/outline
  subroles; checked, selected, and expanded snapshot transitions notify VoiceOver.
- Windows CI smoke: MSYS2 MinGW (GLFW/FreeType/HarfBuzz) + wgpu-native GNU zip
  (`docs/WINDOWS.md`); `build.zig` honors `MSYSTEM_PREFIX` and links `glfw3`.
- `docs/ROADMAP.md` — post-0.1.0 backlog and non-goals.

## [0.1.0] — 2026-08-13

First tagged development milestone: GPUI-inspired core + base-gpui-style
headless component library on Zig 0.16 (macOS).

### Added (post-milestone catalog fill)

Base-gpui gap components and aliases: `autocomplete`, `checkbox_group`,
`otp_field`, `drawer`, `field`, `fieldset`, `meter`, `menubar`,
`navigation_menu`, `toolbar`, `preview_card`, plus thin aliases
`toggle` / `input` / `number_field` / `scroll_area`.

### Added

#### Framework core
- Platform vtable with **GLFW** and **AppKit** backends (wgpu / CAMetalLayer)
- Scene primitives (quad, shadow, sprite, path) + WGSL renderer
- FreeType / HarfBuzz text, glyph atlas, text wrap / fallback
- Yoga flexbox layout; Div / Text / ScrollView / TextInput / TextArea elements
- App `Entity(T)` model, `Value` / `FieldValue` / `MaskValue` (comptime)
- Overlay stack (modal, focus trap, z-order)
- IME composition events (Harness + AppKit marked text; GLFW stub)
- Clipboard (in-memory + OS bridge on GLFW/AppKit) with text undo/redo shortcuts
- Animation timeline (tween / spring / fade helpers)
- Dirty tracker + optional partial GPU present (Load + scissor)
- A11y roles collected per frame; AppKit AX children skeleton
- Focus-visible tracking for keyboard vs pointer focus
- Hotkey keymap / router (overlay → hotkey → main dispatch)
- Frame profiler + optional debug HUD (FPS / dirty / overlays)

#### Components (headless)
Inputs, overlays, navigation, data (virtual list/table), tree, calendar /
datepicker, color picker, command palette, resizable split, toast/sheet, form
helpers, and more — see README component catalog.

#### Tooling
- Headless `testing.Harness` (synthetic input, overlays, a11y queries)
- Examples: window smoke, UI demo, native AppKit, component galleries,
  kitchen sink, **app template**
- `docs/ARCHITECTURE.md`

### Notes
- macOS Apple Silicon + Homebrew deps required for GPU examples
- Partial present and AX bridge are experimental / skeleton-level
- Version `0.1.0` signals “usable for prototypes”, not API freeze

[0.1.0]: https://github.com/local/zgpui/releases/tag/v0.1.0
