# IME (Input Method Editor) support

zgpui routes platform IME events into `TextInputState` preedit and commits via `text_input`.

## Platform comparison

| Feature | AppKit (macOS native) | GLFW |
| --- | --- | --- |
| Composition events (`composition_start` / `update` / `end`) | Yes — `NSTextInputClient` marked text | No — OS callbacks not exposed by GLFW |
| Committed text (`text_input`) | Yes — `insertText:` (+ `interpretKeyEvents`) | Yes — `glfwSetCharCallback` |
| Preedit display | `TextInput` paints `preedit` + underline | Same UI path if events are injected (e.g. tests) |
| Candidate window position | Yes — `PlatformWindow.setImePosition` → `firstRectForCharacterRange` | Best-effort GLFW IME APIs when linked; **Windows** also Imm32 `ImmSetCompositionWindow` via `win32_ime.zig` |
| Duplicate ASCII on commit | Avoided — text commits via `insertText:` only | N/A |

## AppKit details

- `setMarkedText:selectedRange:` emits `composition_update` with a UTF-8 byte caret converted from the NSRange (UTF-16).
- While composing, editing keys (Backspace, Delete, arrows, Enter, Home, End, Escape) are not forwarded as `key_down` so they do not mutate committed buffer text.
- Focused `TextInput` writes the caret anchor each frame; `Window` calls `setImePosition` after paint.

## GLFW details

- GLFW has no cross-platform composition callbacks; use the AppKit backend on macOS for full IME, or drive composition through the headless test harness.
- `setImePosition` is wired for optional GLFW IME APIs and is safe to call every frame.
- **Windows (GLFW HWND):** `setImePosition` also calls Imm32
  `ImmSetCompositionWindow` / `ImmSetCandidateWindow` via `platform/win32_ime.zig`
  so the OS composition and candidate windows track the caret. Composition
  *text* events are still not available from stable GLFW — only positioning.
- Follow-ups: full OS-specific composition (XIM / Win32 Imm/TSF message hooks)
  behind the same `composition_*` events, or a GLFW build that exports composition hooks.

## Testing

Composition behavior is covered by `TextInputState` unit tests, `text_field` harness tests, and `testing.Harness.composition*` helpers (no window required).
