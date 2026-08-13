# IME (Input Method Editor) support

zgpui routes platform IME events into `TextInputState` preedit and commits via `text_input`.

## Platform comparison

| Feature | AppKit (macOS native) | GLFW |
| --- | --- | --- |
| Composition events (`composition_start` / `update` / `end`) | Yes — `NSTextInputClient` marked text | No — OS callbacks not exposed by GLFW |
| Committed text (`text_input`) | Yes — `insertText:` (+ `interpretKeyEvents`) | Yes — `glfwSetCharCallback` |
| Preedit display | `TextInput` paints `preedit` + underline | Same UI path if events are injected (e.g. tests) |
| Candidate window position | Yes — `PlatformWindow.setImePosition` → `firstRectForCharacterRange` | Best-effort — calls `glfwSetIMECursorPos` / `glfwSetInputMethodCursorPos` / `glfwSetIMEWindowPos` when the linked GLFW build exports them (stable 3.4–3.5 do not; no-op stub otherwise) |
| Duplicate ASCII on commit | Avoided — text commits via `insertText:` only | N/A |

## AppKit details

- `setMarkedText:selectedRange:` emits `composition_update` with a UTF-8 byte caret converted from the NSRange (UTF-16).
- While composing, editing keys (Backspace, Delete, arrows, Enter, Home, End, Escape) are not forwarded as `key_down` so they do not mutate committed buffer text.
- Focused `TextInput` writes the caret anchor each frame; `Window` calls `setImePosition` after paint.

## GLFW details

- GLFW has no cross-platform composition callbacks; use the AppKit backend on macOS for full IME, or drive composition through the headless test harness.
- `setImePosition` is wired for future GLFW IME APIs and is safe to call every frame.
- Post-0.1 options (see `docs/ROADMAP.md`): OS-specific IME (XIM, Win32 Imm/TSF) behind the same `composition_*` events, or a GLFW build that exports composition hooks.

## Testing

Composition behavior is covered by `TextInputState` unit tests, `text_field` harness tests, and `testing.Harness.composition*` helpers (no window required).
