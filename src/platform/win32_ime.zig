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
const CFS_CANDIDATEPOS: u32 = 0x0040;

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

const CANDIDATEFORM = extern struct {
    dwIndex: u32 = 0,
    dwStyle: u32,
    ptCurrentPos: POINT,
    rcArea: RECT = .{},
};

const ImmApi = if (builtin.os.tag == .windows) struct {
    extern "imm32" fn ImmGetContext(hwnd: *anyopaque) callconv(.winapi) ?*anyopaque;
    extern "imm32" fn ImmSetCompositionWindow(himc: *anyopaque, form: *const COMPOSITIONFORM) callconv(.winapi) i32;
    extern "imm32" fn ImmSetCandidateWindow(himc: *anyopaque, form: *const CANDIDATEFORM) callconv(.winapi) i32;
    extern "imm32" fn ImmReleaseContext(hwnd: *anyopaque, himc: *anyopaque) callconv(.winapi) i32;
} else struct {};

/// Position the Imm32 composition and candidate windows at a logical caret point.
/// Safe to call every frame; no-ops when `hwnd` is null or not on Windows.
pub fn setCompositionSpot(hwnd: ?*anyopaque, point: Point(Pixels), scale: f32) void {
    if (builtin.os.tag != .windows) return;
    const handle = hwnd orelse return;
    const sx = if (scale > 0) scale else 1;
    const px: i32 = @intFromFloat(point.x * sx);
    const py: i32 = @intFromFloat(point.y * sx);
    const himc = ImmApi.ImmGetContext(handle) orelse return;
    defer _ = ImmApi.ImmReleaseContext(handle, himc);

    const composition = COMPOSITIONFORM{
        .dwStyle = CFS_POINT,
        .ptCurrentPos = .{ .x = px, .y = py },
    };
    _ = ImmApi.ImmSetCompositionWindow(himc, &composition);

    const candidate = CANDIDATEFORM{
        .dwStyle = CFS_CANDIDATEPOS,
        .ptCurrentPos = .{ .x = px, .y = py },
    };
    _ = ImmApi.ImmSetCandidateWindow(himc, &candidate);
}

test "setCompositionSpot is safe without a real HWND / on non-Windows" {
    setCompositionSpot(null, .{ .x = 10, .y = 20 }, 2.0);
}
