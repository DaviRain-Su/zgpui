# IME (Input Method Editor) support

zgpui routes platform IME events into `TextInputState` preedit and commits via `text_input`.

## Platform comparison

| Feature | AppKit (macOS native) | GLFW |
| --- | --- | --- |
| Composition events (`composition_start` / `update` / `end`) | Yes — `NSTextInputClient` marked text | **Windows:** Imm32 HWND subclass → same events; **Linux/macOS GLFW:** no (use AppKit on macOS) |
| Committed text (`text_input`) | Yes — `insertText:` (+ `interpretKeyEvents`) | Yes — `glfwSetCharCallback`; **Windows Imm** also commits `GCS_RESULTSTR` (swallows duplicate WM_CHAR) |
| Preedit display | `TextInput` paints `preedit` + underline | Same UI path (Win32 Imm + harness inject) |
| Candidate window position | Yes — `PlatformWindow.setImePosition` → `firstRectForCharacterRange` | Best-effort GLFW IME APIs when linked; **Windows** Imm32 composition + candidate windows via `win32_ime.zig` |
| Duplicate ASCII on commit | Avoided — text commits via `insertText:` only | Windows Imm result path returns 0 so GLFW char does not double-commit |

## AppKit details

- `setMarkedText:selectedRange:` emits `composition_update` with a UTF-8 byte caret converted from the NSRange (UTF-16).
- While composing, editing keys (Backspace, Delete, arrows, Enter, Home, End, Escape) are not forwarded as `key_down` so they do not mutate committed buffer text.
- Focused `TextInput` writes the caret anchor each frame; `Window` calls `setImePosition` after paint.

## GLFW details

- GLFW has no cross-platform composition callbacks. On macOS prefer the AppKit
  backend; elsewhere use the harness `composition*` helpers in tests.
- `setImePosition` is wired for optional GLFW IME APIs and is safe to call every frame.
- **Windows (GLFW HWND):** `platform/win32_ime.zig` subclasses the HWND to map
  `WM_IME_STARTCOMPOSITION` / `WM_IME_COMPOSITION` / `WM_IME_ENDCOMPOSITION`
  into `composition_start` / `composition_update` / `composition_end` and
  commits via `text_input` from `GCS_RESULTSTR`. `setImePosition` also drives
  `ImmSetCompositionWindow` / `ImmSetCandidateWindow` for caret tracking.
- Follow-ups: XIM / ibus composition on Linux behind the same events; optional
  TSF refinement on Windows.

## Testing

Composition behavior is covered by `TextInputState` unit tests, `text_field` harness tests, and `testing.Harness.composition*` helpers (no window required).
