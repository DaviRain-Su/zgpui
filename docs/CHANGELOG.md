# Changelog

All notable changes to zgpui are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Examples `02_ui`, `04_components`, `05_advanced`, `06_kitchen_sink`, and
  `07_app_template` enable `Window.partial_present` by default.

### Fixed
- Retained layout slice: when dirty is paint-only (`layout` clear), keep the
  element/Yoga tree and only re-prepaint/paint via a per-frame scratch arena.
- `partial_present`: TextInput / TextArea edits use `App.notifyBounds` with
  the field's last prepainted rect instead of a full-window dirty.
- `partial_present`: ScrollView scroll requests a regional redraw via
  `App.requestRegionalRedraw` (entity `notify` still escalates to full).
- `partial_present`: hover enter/leave no longer forces a full-surface dirty;
  `classifyInputDirty` marks previous/next hit bounds so Load+scissor can apply.
- Linux / Zig 0.16: `profile` monotonic clock uses `timespec.sec` / `.nsec`
  (CI compile failure on Ubuntu).
- Windows / Zig 0.16: `profile` monotonic clock uses `QueryPerformanceCounter`
  instead of unavailable `clock_gettime`.
- Linux CI: text field/textarea tests leaked `FontSystem` when macOS-only
  font paths failed before `defer deinit`; shared `loadTestFont` + DejaVu
  paths + `errdefer`, and install `fonts-dejavu-core` in CI.
- AppKit AX selected-range writes reject reversed, out-of-bounds, overflowed,
  UTF-8 continuation-byte, and UTF-16 mid-surrogate ranges without mutation.
- AppKit AX proxies use the protocol's `isAccessibilityEnabled` /
  `isAccessibilityFocused` getters, and native notifications now receive
  `NSString` names instead of raw C-string pointers.

### Added
- Checkbox / toggle group a11y: groups publish `.list` + orientation;
  toggles are `.button` with `checked` for pressed. Toolbar and navigation
  menu lists publish orientation alongside existing roles.
- Pagination a11y: nav is `.list` + horizontal orientation (default name
  "Pagination"); prev/next and page controls are named `.button`s with
  selected state on the current page.
- Rating / stepper a11y: rating publishes slider numeric range, orientation,
  and value description with selected star buttons; stepper is a `.list` with
  oriented layout and selected step buttons.
- Badge / tag / kbd / skeleton a11y: badges and tags expose `.label` (optional
  `a11y_label`); kbd uses the caption as its accessible name; skeletons are
  busy `.progressbar` placeholders named "Loading".
- Breadcrumb a11y: trail is `.list` + horizontal orientation (default name
  "Breadcrumb"); items are `.link` or current `.list_item`/`selected`;
  separators use `.separator`.
- Collapsible / accordion a11y: triggers expose `role(.button)` with
  `expanded` (and AppKit `AXShowMenu` via existing expandable pressables).
- Scrollbar a11y: `Role.scrollbar` maps to AppKit `AXScrollBar` with axis
  orientation and numeric offset range (`0..maxOffset`).
- Avatar a11y: registers `role(.img)` (AppKit `AXImage`) with optional
  `a11y_label` accessible name.
- A11y identifier: `Node.identifier` from `Div.withId` maps to AppKit
  `accessibilityIdentifier` for stable VoiceOver / automation ids.
- Radio group a11y: `Role.radio_group` maps to AppKit `AXRadioGroup`; the
  radio list publishes horizontal orientation while options keep `.radio` +
  checked state.
- Separator a11y: registers `role(.separator)` and maps layout orientation to
  AppKit `accessibilityOrientation`.
- Link a11y URL: `Node.url` from `Div.href` maps to AppKit `accessibilityURL`
  so VoiceOver can announce link destinations.
- Progress / meter a11y: determinate bars publish numeric min/max/value,
  percent `value_description`, and horizontal orientation; indeterminate
  progress marks `busy` without a fake numeric value.
- A11y orientation: `Node.orientation` / `Div.a11yOrientation` map to AppKit
  `accessibilityOrientation` (Unknown/Vertical/Horizontal); Slider and tab
  lists default to horizontal.
- Select / combobox a11y: `Role.pop_up_button` / `Role.combobox` map to
  AppKit `AXPopUpButton` / `AXComboBox`; open lists are modal + expanded;
  options expose `a11y_label` names.
- Menu / popover a11y: triggers expose `expanded`; menu lists are modal +
  expanded; popover panels are dialog + modal; AppKit adds `AXShowMenu` /
  `accessibilityPerformShowMenu` for expandable pressables; menubar items use
  expanded instead of selected-for-open.
- A11y modal surfaces: `Node.modal` / `Div.a11yModal` map to AppKit
  `isAccessibilityModal`; dialog, sheet, drawer, and modal command palette
  panels set it.
- A11y placeholder / value description: `Node.placeholder` /
  `Node.value_description` map to AppKit `accessibilityPlaceholderValue` /
  `accessibilityValueDescription`; TextInput/TextArea publish placeholders;
  Slider speaks a percent value description.
- A11y `invalid` state: `Node.invalid` / `Div.a11yInvalid` map to AppKit
  `AXInvalid` (`"true"`/`"false"`) with `AXInvalidStatusChanged`; Field
  `applyValidationA11y` / `control` wire validation, and error messages announce
  as assertive live labels.
- AppKit AX structural tree diff: `Store.syncFromNodes` reuses AX proxies for
  matching `ElementId`s and posts `AXLayoutChanged` only when identity / role /
  parent / order / `nav_order` changes (value-only frames keep VoiceOver focus).
- A11y `busy` / `required` states: `Node.busy` / `Node.required` map to AppKit
  `isAccessibilityBusy` / `isAccessibilityRequired`; Spinner marks busy while
  `active`.
- A11y heading levels + descriptions: `Node.heading_level` /
  `Div.a11yHeadingLevel`, `Node.description` / `Div.a11yDescription` map to
  AppKit `accessibilityLevel` / `accessibilityHelp`; Markdown headings and
  GroupBox titles set levels.
- GPUI naming modules: `zgpui.props`, `zgpui.context`, `zgpui.runtime`,
  `zgpui.layers` re-export existing types (flat `zgpui.*` paths unchanged).
- macOS CoreText font discovery: `FontSystem.loadUiFont` / `loadSystemFont`
  resolve system/UI faces to paths then load with FreeType (`text/coretext.zig`).
- Win32 Imm32 HWND subclass maps `WM_IME_*` to `composition_start` /
  `composition_update` / `composition_end` / `text_input` (GLFW has no
  composition callbacks); result commits swallow duplicate WM_CHAR.
- Win32 Imm32 also sets `ImmSetCandidateWindow` (CFS_CANDIDATEPOS) alongside
  the composition window when positioning the caret.
- Win32 Imm32 caret positioning: GLFW `setImePosition` places the OS
  composition window via `ImmSetCompositionWindow` (`platform/win32_ime.zig`).
- Plot line dots + pie slice angles; Markdown inline spans (`strong` / `emphasis` /
  `code` / `link`); component gallery + catalog smoke cover plot/markdown/code_input.
- Headless Plot / Markdown / Code Input: linear+band scales and bar chart shell,
  Markdown block parse + TextView column, line map with LSP-shaped diagnostic
  slots (phase 6 contracts; no LSP client).
- Headless Sidebar / Dock / Tiles: collapse layout widths, dock area insets,
  and freeform tile move/resize/z-order (gpui-component phase 5 contracts).
- Headless `searchable_list`: query filter (`substring` / `subsequence`),
  `collectMatches`, and virtualized matched rows with keyboard select.
- Scrollbar thumb geometry (`thumbLength` / `thumbStart` / track-click offset) and
  headless Stepper, Rating, Tag, Alert, GroupBox, DescriptionList catalog pieces.
- Virtual list variable-height mode: `item_heights` + `visibleRangeVariable`
  (gpui-base virtual_list contract; fixed-height path unchanged).
- Headless `positioner` (`resolveSide` / `resolveCorner`) shared by Popover,
  Menu, and Tooltip for flip, align, and viewport clamp; port plan in
  `docs/PORT_GPUI_COMPONENT.md`.
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
- Declarative a11y live regions expose `polite` / `assertive` priorities and
  post native AppKit announcements for visible insertions, text changes, and
  priority changes. Toast messages are polite by default and may opt into
  assertive delivery.
- Toast rendering keeps accessibility-name slices anchored in persistent toast
  entries instead of a per-frame stack copy.
- AppKit exposes semantic custom rotors for visible headings, links, images,
  lists, and text inputs, with ordered forward/backward search and name/value
  filtering; rotor results retain stable element identity across AX proxy
  rebuilds.
- Author-defined `rotor_group` labels create AppKit custom rotors (after
  semantic ones); `nav_order` reorders accessibility siblings/roots and Tab
  focus. Div exposes `.a11yRotorGroup` / `.a11yNavOrder`.
- Linux Wayland attach resolves `glfwGetWaylandDisplay` /
  `glfwGetWaylandWindow` at runtime (`dlsym`) so X11-only GLFW still links;
  docs in `docs/LINUX.md`.
- Incremental paint: `partial_present` frames apply a dilated dirty
  `paint_clip` so scene inserts and element paint walks skip work outside
  the dirty union (layout/prepaint still full when dirty).
- Windows MinGW builds keep Zig's LLD and link `lib*.dll.a` import libs for
  GLFW/FreeType/HarfBuzz/wgpu-native (avoids static `_setjmp` /
  `use_lld=false` emit bugs); Windows GNU CI is required.
- OTP `readText` returns slices from entity/union storage instead of a
  temporary `Value.get()` copy (dangling pointer that failed on Windows).
- Windows CI smoke: MSYS2 MinGW (GLFW/FreeType/HarfBuzz) + wgpu-native GNU zip
  (`docs/WINDOWS.md`); `build.zig` honors `MSYSTEM_PREFIX`, links `glfw3` and
  FreeType/HarfBuzz transitive libs, and prefers `x86_64-windows-gnu`. Full
  link remains experimental (Zig 0.16 MinGW CRT / `lld` issues).
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
