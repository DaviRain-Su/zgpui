# zgpui architecture notes

Design intent for contributors. The public surface lives in `src/zgpui.zig`
and `README.md`; this document explains *why* the layers look the way they do.

## Immediate mode, retained state

Each frame rebuilds the element tree from a **frame arena** (reset every
frame). Persistent state lives in `App` entities (`Entity(T)`), not in the
tree. That matches GPUI’s model more closely than React’s VDOM:

1. `requestLayout` — Yoga flex tree
2. `prepaint` — hitboxes, focusables, a11y nodes
3. `paint` — scene primitives

Handlers must **not** point into the frame arena. Point at entities, demo
structs, or other long-lived memory.

## Controlled vs uncontrolled

`value.Value(T)` and `value.FieldValue(Store, "field")` are comptime unions:

- `.controlled` — parent owns the value; component reports intent via
  `on_change`
- `.uncontrolled` — component writes an entity store and `notify`s

Prefer these helpers over hand-rolled unions when adding components.

## Overlays

`OverlayStack` is a second element pipeline painted above the main tree.
Components register with `push` during the main render when open. Input
dispatches **topmost overlay first**; modal layers swallow outside clicks
and Escape.

Immediate-mode consequence: an overlay only exists while it re-registers.
Animated close (dialog fade-out) keeps `open=true` and sets `closing` until
the timeline opacity reaches ~0, then `finishClose()`.

## Animation

`Timeline` holds up to 32 tween/spring slots. `Window.anim_clock` ticks it
in `renderIfNeeded` and marks dirty while anything is active. Overlay
fade helpers (`fadeIn` / `fadeOut` / `opacityOf`) are opt-in via
`timeline: ?*Timeline` on props.

## Dirty tracking & partial present

`DirtyTracker` records full vs union bounds. Skipping clean frames is the
main win today. `Window.partial_present` (default **false**) can Load +
scissor the GPU pass. On partial frames it also sets a dilated logical
`paint_clip` so Div/Text/input paint walks and scene inserts skip work
outside the dirty union. Hover enter/leave uses `markDirtyBounds` on the
previous and next hit targets (via `classifyInputDirty`) so those frames
stay regional instead of `markFull`. ScrollView offset changes call
`App.requestRegionalRedraw` with the viewport bounds; TextInput/TextArea
edits use `App.notifyBounds` with the field's last prepainted bounds.
Entity `notify` still escalates to a full redraw. Layout/prepaint still
rebuild when dirty; true retained layout remains roadmap work. Prefer
`markDirtyBounds` / `requestRegionalRedraw` / `notifyBounds` only when you
can prove the changed region.

## Platform split

- **GLFW** — primary cross-platform path (macOS Metal layer via GLFW,
  Linux X11 / Wayland via runtime `glfwGetWayland*` lookup, Windows HWND via
  MinGW/MSYS2 + wgpu-native; see [WINDOWS.md](WINDOWS.md) /
  [LINUX.md](LINUX.md)); wgpu surface; OS clipboard wired
- **AppKit** — native `CAMetalLayer`, IME marked text, AX bridge, pasteboard

Upper layers only see `Platform` / `PlatformWindow` vtables. See
[ROADMAP.md](ROADMAP.md) for IME follow-ups.

## Accessibility

Elements declare `Role` / name / state on Div; `FrameState.a11y` collects
them in prepaint. Harness queries them headlessly (`a11yPressOn` simulates
AXPress → `on_click`). Semantic parents follow the nearest registered ancestor.
Explicit, chained `labelled_by`, and inverse `Label.for_id` names resolve only
inside their source frame. Before native sync, those names are materialized and
the main frame and overlays are composed in paint order; the topmost modal hides
everything below it. AppKit mirrors that hierarchy, exposes TextInput/TextArea
values plus caret/selection attributes, accepts value/selected-text/range
setters for editable text, routes enabled press/adjust actions, and posts
value/selection/expansion notifications when the snapshot changes. Semantic
variants such as switches, search fields, dialogs, tabs, and outline rows map
to AppKit subroles. Declarative `polite` / `assertive` live regions post native
announcements when visible text or priority changes; Toast uses this path by
default. Visible semantic roles also drive AppKit heading, link, image, list,
and text-field rotors with directional, filtered search. Author `rotor_group`
labels add custom AppKit rotors; `nav_order` reorders AX siblings and Tab focus.
See [A11Y.md](A11Y.md) for the snapshot contract. Full VoiceOver parity remains
roadmap work.

## Focus-visible

`InputState.focus_visible` is set on Tab focus moves and cleared on
pointer-driven focus. Components expose `StyleState.focus_visible` so
style rings can follow keyboard navigation only.

## Testing

`testing.Harness` runs the full CPU pipeline without a window or GPU.
Prefer harness behavior tests for components; keep GPU/examples as smoke
coverage (`zig build run-*`).

## Extending the library

1. New headless component → `src/components/<name>.zig`, export from
   `components.zig`, harness tests, set a11y role when interactive
2. New element primitive → `src/elements/`, implement the three phases,
   optionally `element.asElement(T, ptr)`
3. Avoid `@cImport`; use translate-c modules from `build.zig`
4. Zig 0.16: `ArrayList` starts `.empty` and takes an allocator on
   `append` / `deinit`

Shared overlay placement lives in `components/positioner.zig` (flip, align,
viewport clamp). For borrowing further headless behavior from upstream
gpui-component (`crates/base`), see [`PORT_GPUI_COMPONENT.md`](PORT_GPUI_COMPONENT.md).
