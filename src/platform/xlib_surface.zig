//! Linux glue: X11 window handle from GLFW for wgpu `WGPUSurfaceSourceXlibWindow`.
//!
//! glfw3native.h cannot be translated by translate-c, so X11 accessors are
//! declared manually (same approach as `metal_layer.zig` on macOS).

const glfw = @import("glfw_c");
const platform_mod = @import("../platform.zig");

extern fn glfwGetX11Display() callconv(.c) ?*anyopaque;
extern fn glfwGetX11Window(window: ?*glfw.GLFWwindow) callconv(.c) c_ulong;

pub const Error = error{
    NoX11Display,
    NoX11Window,
};

pub fn attach(window: ?*glfw.GLFWwindow) Error!platform_mod.NativeSurface {
    const display = glfwGetX11Display() orelse return error.NoX11Display;
    const xwindow = glfwGetX11Window(window);
    if (xwindow == 0) return error.NoX11Window;
    return .{ .xlib_window = .{
        .display = display,
        .window = xwindow,
    } };
}
