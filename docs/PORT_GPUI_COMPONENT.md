# Porting gpui-component → zgpui

Strategy for borrowing hard shared behavior from
[longbridge/gpui-component](https://github.com/longbridge/gpui-component)
without adopting its styled theme stack.

## Layering

| Upstream | Role | zgpui counterpart |
| --- | --- | --- |
| `crates/base` (gpui-base) | Headless behavior: positioner, virtual list, scrollbars, docks | `src/components/*` — **alignment target** |
| `crates/ui` | Themed Button / inputs / chrome | **Out of scope** — apps style via `Style` / `StyleFn` |

zgpui stays a base-gpui-style catalog: behavior + a11y, no prescribed visuals.
APIs follow Zig/zgpui conventions; contracts (flip, clamp, virtualization)
track gpui-base where we port them.

## Coverage matrix (today)

| Area | Upstream (base/ui) | zgpui | Notes |
| --- | --- | --- | --- |
| Button / toggle / checkbox / radio | ui + base patterns | yes | Headless + StyleFn |
| Text field / textarea / OTP | ui | yes | |
| Dialog / alert / sheet / drawer | base/ui | yes | Overlay stack |
| Popover / tooltip / menu | base Positioner | **Positioner** (phase 1) | Shared flip/align/clamp |
| List / table / tree | virtual_list, etc. | fixed + **variable-height** list + table | `item_heights` on `list` |
| Select / combobox / autocomplete | ui | yes | Still local insets in places |
| Scroll area | scrollbar semantics | **scrollbar** + scroll_area | Thumb geometry + track jump |
| Sidebar / Dock / Tiles | base | no | Phase 5 |
| Searchable list | base | no | Phase 4 |
| Chart / Markdown / LSP editor | ui extras | no | Phase 6 / separate track |
| Theme / native_menu / webview | ui | **non-goal** | |
| Stepper / Rating / Tag / Alert / GroupBox / DescriptionList | ui | **yes** (headless) | Phase 3 |

## Phased backlog

| Phase | Content | Status |
| --- | --- | --- |
| 0 | This document + ROADMAP / ARCHITECTURE links | done |
| 1 | **Positioner** + Popover / Menu / Tooltip | done (this change) |
| 2 | Variable-height VirtualList (extend `list.zig`) | done |
| 3 | Scrollbar handle semantics; Stepper / Rating / Tag / Alert / GroupBox / DescriptionList | done |
| 4 | SearchableList | later |
| 5 | Sidebar / Dock / Tiles | later |
| 6 | Chart/Plot; Markdown TextView; Code Input + LSP | far |

## Non-goals

- Copying `crates/ui` themes, tokens, or styled Button chrome
- `native_menu`, webview, or whole-package LSP editor
- Line-for-line Rust API parity
- Changing Windows / CI policy as part of port work

## Acceptance per phase

1. `zig build test` green
2. Relevant harness coverage for new behavior
3. Short `CHANGELOG` note + export from `components.zig` when adding a module
4. Update the matrix / backlog row in this file when shipping

## Phase 1 reference

- Upstream: `crates/base/src/positioner.rs`
- zgpui: `src/components/positioner.zig` (`resolveSide`, `resolveCorner`)
- Consumers: `popover.zig`, `tooltip.zig`, `menu.zig`

## Phase 2 reference

- Upstream: `crates/base/src/virtual_list.rs` (known per-item sizes, visible window)
- zgpui: `src/components/list.zig` — `item_heights`, `visibleRangeVariable`, `itemTop` / `totalHeight`

## Phase 3 reference

- Upstream: `crates/base/src/scrollbar.rs`; ui `stepper` / `rating` / `tag` / `alert` / `group_box` / `description_list`
- zgpui: `scrollbar.zig` (thumb geometry), `stepper.zig`, `rating.zig`, `tag.zig`, `alert.zig`, `group_box.zig`, `description_list.zig`

