//! Windows glue: HWND from GLFW for wgpu `WGPUSurfaceSourceWindowsHWND`.
//!
//! glfw3native.h cannot be translated by translate-c, so Win32 accessors are
//! declared manually (same approach as `xlib_surface.zig` on Linux).
//!
//! **Status:** scaffolding only — not exercised on a Windows machine in CI yet.

const glfw = @import("glfw_c");
const platform_mod = @import("../platform.zig");

extern fn glfwGetWin32Window(window: ?*glfw.GLFWwindow) callconv(.c) ?*anyopaque;
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;

pub const Error = error{
    NoWin32Window,
    NoModuleHandle,
};

pub fn attach(window: ?*glfw.GLFWwindow) Error!platform_mod.NativeSurface {
    const hwnd = glfwGetWin32Window(window) orelse return error.NoWin32Window;
    const hinstance = GetModuleHandleW(null) orelse return error.NoModuleHandle;
    return .{ .win32_hwnd = .{
        .hinstance = hinstance,
        .hwnd = hwnd,
    } };
}
