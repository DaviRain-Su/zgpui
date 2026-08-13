//! Win32 Imm32 composition-window positioning for GLFW HWND surfaces.
//!
//! Stable GLFW does not emit composition callbacks; this only places the OS
//! candidate / composition window near the caret via `ImmSetCompositionWindow`.
//! Compiles to a no-op on non-Windows targets.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("../geometry.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point;

const CFS_POINT: u32 = 0x0002;

const POINT = extern struct {
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
    ptCurrentPos: POINT,
    rcArea: RECT = .{},
};

/// Position the Imm32 composition window at a logical caret point.
/// Safe to call every frame; no-ops when Imm32 is unavailable or `hwnd` is null.
pub fn setCompositionSpot(hwnd: ?*anyopaque, point: Point(Pixels), scale: f32) void {
    if (builtin.os.tag != .windows) return;
    const handle = hwnd orelse return;
    const sx = if (scale > 0) scale else 1;
    const form = COMPOSITIONFORM{
        .dwStyle = CFS_POINT,
        .ptCurrentPos = .{
            .x = @intFromFloat(point.x * sx),
            .y = @intFromFloat(point.y * sx),
        },
    };
    setCompositionForm(handle, &form);
}

fn setCompositionForm(hwnd: *anyopaque, form: *const COMPOSITIONFORM) void {
    if (builtin.os.tag != .windows) return;

    const ImmGetContext = *const fn (hwnd: *anyopaque) callconv(.winapi) ?*anyopaque;
    const ImmSetCompositionWindow = *const fn (himc: *anyopaque, form: *const COMPOSITIONFORM) callconv(.winapi) i32;
    const ImmReleaseContext = *const fn (hwnd: *anyopaque, himc: *anyopaque) callconv(.winapi) i32;

    const lib = std.DynLib.open("imm32.dll") catch return;
    defer lib.close();

    const get_ctx: ImmGetContext = lib.lookup(ImmGetContext, "ImmGetContext") orelse return;
    const set_form: ImmSetCompositionWindow = lib.lookup(ImmSetCompositionWindow, "ImmSetCompositionWindow") orelse return;
    const release: ImmReleaseContext = lib.lookup(ImmReleaseContext, "ImmReleaseContext") orelse return;

    const himc = get_ctx(hwnd) orelse return;
    defer _ = release(hwnd, himc);
    _ = set_form(himc, form);
}

test "setCompositionSpot is safe without Imm32 / on non-Windows" {
    setCompositionSpot(null, .{ .x = 10, .y = 20 }, 2.0);
    // Non-null pointer is still safe when Imm32 open fails or OS is not Windows.
    setCompositionSpot(@ptrFromInt(1), .{ .x = 0, .y = 0 }, 1.0);
}
