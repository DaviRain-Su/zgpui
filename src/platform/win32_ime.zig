//! Win32 Imm32 IME: caret/candidate positioning + composition text via HWND
//! subclassing (GLFW has no composition callbacks on Windows).
//!
//! Compiles to positioning/composition no-ops on non-Windows targets.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("../geometry.zig");
const platform_mod = @import("../platform.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point;

const CFS_POINT: u32 = 0x0002;
const CFS_CANDIDATEPOS: u32 = 0x0040;

const GCS_COMPSTR: u32 = 0x0008;
const GCS_CURSORPOS: u32 = 0x0080;
const GCS_RESULTSTR: u32 = 0x0800;

const WM_IME_STARTCOMPOSITION: u32 = 0x010D;
const WM_IME_ENDCOMPOSITION: u32 = 0x010E;
const WM_IME_COMPOSITION: u32 = 0x010F;

const GWLP_WNDPROC: i32 = -4;

const POINT_ = extern struct {
    x: i32,
    y: i32,
};

const RECT = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
};

const COMPOSITIONFORM = extern struct {
    dwStyle: u32,
    ptCurrentPos: POINT_,
    rcArea: RECT = .{},
};

const CANDIDATEFORM = extern struct {
    dwIndex: u32 = 0,
    dwStyle: u32,
    ptCurrentPos: POINT_,
    rcArea: RECT = .{},
};

const WinApi = if (builtin.os.tag == .windows) struct {
    extern "imm32" fn ImmGetContext(hwnd: *anyopaque) callconv(.winapi) ?*anyopaque;
    extern "imm32" fn ImmSetCompositionWindow(himc: *anyopaque, form: *const COMPOSITIONFORM) callconv(.winapi) i32;
    extern "imm32" fn ImmSetCandidateWindow(himc: *anyopaque, form: *const CANDIDATEFORM) callconv(.winapi) i32;
    extern "imm32" fn ImmReleaseContext(hwnd: *anyopaque, himc: *anyopaque) callconv(.winapi) i32;
    extern "imm32" fn ImmGetCompositionStringW(
        himc: *anyopaque,
        index: u32,
        buf: ?*anyopaque,
        buf_len: u32,
    ) callconv(.winapi) i32;

    extern "user32" fn SetWindowLongPtrW(hwnd: *anyopaque, index: i32, value: isize) callconv(.winapi) isize;
    extern "user32" fn CallWindowProcW(
        prev: isize,
        hwnd: *anyopaque,
        msg: u32,
        wparam: usize,
        lparam: isize,
    ) callconv(.winapi) isize;
    extern "user32" fn SetPropW(hwnd: *anyopaque, name: [*:0]const u16, data: *anyopaque) callconv(.winapi) i32;
    extern "user32" fn GetPropW(hwnd: *anyopaque, name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "user32" fn RemovePropW(hwnd: *anyopaque, name: [*:0]const u16) callconv(.winapi) ?*anyopaque;

    extern "kernel32" fn WideCharToMultiByte(
        code_page: u32,
        flags: u32,
        wide: [*]const u16,
        wide_len: i32,
        out: ?[*]u8,
        out_len: i32,
        default_char: ?[*:0]const u8,
        used_default: ?*i32,
    ) callconv(.winapi) i32;
} else struct {};

const CP_UTF8: u32 = 65001;
const prop_name = std.unicode.utf8ToUtf16LeStringLiteral("zgpui_ime_hook");

pub const EmitFn = *const fn (ctx: ?*anyopaque, event: platform_mod.WindowEvent) void;

/// Installed Imm32 HWND subclass state (Windows only).
pub const Hook = struct {
    hwnd: *anyopaque,
    prev_wndproc: isize,
    emit_ctx: ?*anyopaque,
    emit_fn: EmitFn,
    composing: bool = false,
    utf8_buf: [2048]u8 = undefined,
};

/// Position the Imm32 composition and candidate windows at a logical caret point.
pub fn setCompositionSpot(hwnd: ?*anyopaque, point: Point(Pixels), scale: f32) void {
    if (builtin.os.tag != .windows) return;
    const handle = hwnd orelse return;
    const sx = if (scale > 0) scale else 1;
    const px: i32 = @intFromFloat(point.x * sx);
    const py: i32 = @intFromFloat(point.y * sx);
    const himc = WinApi.ImmGetContext(handle) orelse return;
    defer _ = WinApi.ImmReleaseContext(handle, himc);

    const composition = COMPOSITIONFORM{
        .dwStyle = CFS_POINT,
        .ptCurrentPos = .{ .x = px, .y = py },
    };
    _ = WinApi.ImmSetCompositionWindow(himc, &composition);

    const candidate = CANDIDATEFORM{
        .dwStyle = CFS_CANDIDATEPOS,
        .ptCurrentPos = .{ .x = px, .y = py },
    };
    _ = WinApi.ImmSetCandidateWindow(himc, &candidate);
}

/// Subclass `hwnd` so Imm composition messages become `composition_*` / `text_input`.
pub fn installHook(
    allocator: std.mem.Allocator,
    hwnd: *anyopaque,
    emit_ctx: ?*anyopaque,
    emit_fn: EmitFn,
) !*Hook {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;

    const hook = try allocator.create(Hook);
    errdefer allocator.destroy(hook);
    hook.* = .{
        .hwnd = hwnd,
        .prev_wndproc = 0,
        .emit_ctx = emit_ctx,
        .emit_fn = emit_fn,
    };

    if (WinApi.SetPropW(hwnd, prop_name.ptr, hook) == 0) {
        allocator.destroy(hook);
        return error.SetPropFailed;
    }

    const prev = WinApi.SetWindowLongPtrW(hwnd, GWLP_WNDPROC, @intFromPtr(&imeWndProc));
    if (prev == 0) {
        _ = WinApi.RemovePropW(hwnd, prop_name.ptr);
        allocator.destroy(hook);
        return error.SubclassFailed;
    }
    hook.prev_wndproc = prev;
    return hook;
}

pub fn uninstallHook(allocator: std.mem.Allocator, hook: *Hook) void {
    if (builtin.os.tag != .windows) {
        allocator.destroy(hook);
        return;
    }
    _ = WinApi.SetWindowLongPtrW(hook.hwnd, GWLP_WNDPROC, hook.prev_wndproc);
    _ = WinApi.RemovePropW(hook.hwnd, prop_name.ptr);
    allocator.destroy(hook);
}

fn emitInput(hook: *Hook, input: platform_mod.InputEvent) void {
    hook.emit_fn(hook.emit_ctx, .{ .input = input });
}

fn utf16ToUtf8(wide: []const u16, out: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    if (wide.len == 0) return out[0..0];
    const n = WinApi.WideCharToMultiByte(
        CP_UTF8,
        0,
        wide.ptr,
        @intCast(wide.len),
        out.ptr,
        @intCast(out.len),
        null,
        null,
    );
    if (n <= 0) return null;
    return out[0..@intCast(n)];
}

fn readImmString(himc: *anyopaque, index: u32, out: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    const byte_len = WinApi.ImmGetCompositionStringW(himc, index, null, 0);
    if (byte_len <= 0) return if (byte_len == 0) out[0..0] else null;
    const wchar_count: usize = @intCast(@divTrunc(byte_len, 2));
    var wbuf: [1024]u16 = undefined;
    const n = @min(wchar_count, wbuf.len);
    const written = WinApi.ImmGetCompositionStringW(
        himc,
        index,
        @ptrCast(&wbuf),
        @intCast(n * 2),
    );
    if (written <= 0) return null;
    const got: usize = @intCast(@divTrunc(written, 2));
    return utf16ToUtf8(wbuf[0..got], out);
}

fn cursorByteOffset(comp_utf8: []const u8, wchar_cursor: i32) i32 {
    if (wchar_cursor < 0) return -1;
    // Approximate: treat each UTF-8 codepoint boundary; Imm cursor is in WCHARs.
    // For BMP text, one wchar ≈ one codepoint. Walk UTF-8 by codepoints up to wchar_cursor.
    var i: usize = 0;
    var seen: i32 = 0;
    while (i < comp_utf8.len and seen < wchar_cursor) {
        const len = std.unicode.utf8ByteSequenceLength(comp_utf8[i]) catch break;
        i += len;
        seen += 1;
    }
    return @intCast(i);
}

fn handleComposition(hook: *Hook, lparam: isize) bool {
    if (builtin.os.tag != .windows) return false;
    const flags: u32 = @truncate(@as(usize, @bitCast(lparam)));
    const himc = WinApi.ImmGetContext(hook.hwnd) orelse return false;
    defer _ = WinApi.ImmReleaseContext(hook.hwnd, himc);

    var handled_result = false;

    if (flags & GCS_RESULTSTR != 0) {
        if (readImmString(himc, GCS_RESULTSTR, &hook.utf8_buf)) |text| {
            if (hook.composing) {
                emitInput(hook, .composition_end);
                hook.composing = false;
            }
            if (text.len > 0) {
                emitInput(hook, .{ .text_input = .{ .text = text } });
            }
            handled_result = true;
        }
    }

    if (flags & GCS_COMPSTR != 0) {
        if (readImmString(himc, GCS_COMPSTR, &hook.utf8_buf)) |text| {
            if (!hook.composing) {
                emitInput(hook, .composition_start);
                hook.composing = true;
            }
            var cursor: i32 = -1;
            if (flags & GCS_CURSORPOS != 0) {
                const cp = WinApi.ImmGetCompositionStringW(himc, GCS_CURSORPOS, null, 0);
                cursor = cursorByteOffset(text, cp);
            }
            emitInput(hook, .{ .composition_update = .{ .text = text, .cursor = cursor } });
        }
    }

    // Swallow RESULTSTR so GLFW's WM_CHAR path does not double-commit.
    return handled_result and (flags & GCS_COMPSTR == 0);
}

fn imeWndProc(hwnd: *anyopaque, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    if (builtin.os.tag != .windows) return 0;

    const hook_ptr = WinApi.GetPropW(hwnd, prop_name.ptr) orelse {
        return WinApi.CallWindowProcW(0, hwnd, msg, wparam, lparam);
    };
    const hook: *Hook = @ptrCast(@alignCast(hook_ptr));

    switch (msg) {
        WM_IME_STARTCOMPOSITION => {
            if (!hook.composing) {
                emitInput(hook, .composition_start);
                hook.composing = true;
            }
            return WinApi.CallWindowProcW(hook.prev_wndproc, hwnd, msg, wparam, lparam);
        },
        WM_IME_COMPOSITION => {
            const swallow = handleComposition(hook, lparam);
            if (swallow) return 0;
            return WinApi.CallWindowProcW(hook.prev_wndproc, hwnd, msg, wparam, lparam);
        },
        WM_IME_ENDCOMPOSITION => {
            if (hook.composing) {
                emitInput(hook, .composition_end);
                hook.composing = false;
            }
            return WinApi.CallWindowProcW(hook.prev_wndproc, hwnd, msg, wparam, lparam);
        },
        else => return WinApi.CallWindowProcW(hook.prev_wndproc, hwnd, msg, wparam, lparam),
    }
}

/// Test helper: map Imm wchar cursor into a UTF-8 byte offset.
pub fn cursorByteOffsetForTest(comp_utf8: []const u8, wchar_cursor: i32) i32 {
    return cursorByteOffset(comp_utf8, wchar_cursor);
}

test "setCompositionSpot is safe without a real HWND / on non-Windows" {
    setCompositionSpot(null, .{ .x = 10, .y = 20 }, 2.0);
}

test "installHook is unsupported off Windows" {
    if (builtin.os.tag == .windows) return;
    const fake: *anyopaque = @ptrFromInt(1);
    try std.testing.expectError(
        error.UnsupportedPlatform,
        installHook(std.testing.allocator, fake, null, struct {
            fn emit(_: ?*anyopaque, _: platform_mod.WindowEvent) void {}
        }.emit),
    );
}

test "cursorByteOffset walks UTF-8 codepoints" {
    try std.testing.expectEqual(@as(i32, 0), cursorByteOffsetForTest("abc", 0));
    try std.testing.expectEqual(@as(i32, 1), cursorByteOffsetForTest("abc", 1));
    try std.testing.expectEqual(@as(i32, 3), cursorByteOffsetForTest("abc", 3));
    // 你 = 3 bytes
    try std.testing.expectEqual(@as(i32, 3), cursorByteOffsetForTest("你a", 1));
    try std.testing.expectEqual(@as(i32, 4), cursorByteOffsetForTest("你a", 2));
}
