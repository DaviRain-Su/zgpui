# Changelog

All notable changes to zgpui are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
