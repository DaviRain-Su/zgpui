//! Linux glue: Wayland display + wl_surface from GLFW for
//! `WGPUSurfaceSourceWaylandSurface`.

const glfw = @import("glfw_c");
const platform_mod = @import("../platform.zig");

extern fn glfwGetWaylandDisplay() callconv(.c) ?*anyopaque;
extern fn glfwGetWaylandWindow(window: ?*glfw.GLFWwindow) callconv(.c) ?*anyopaque;

pub const Error = error{
    NoWaylandDisplay,
    NoWaylandSurface,
};

pub fn attach(window: ?*glfw.GLFWwindow) Error!platform_mod.NativeSurface {
    const display = glfwGetWaylandDisplay() orelse return error.NoWaylandDisplay;
    const surface = glfwGetWaylandWindow(window) orelse return error.NoWaylandSurface;
    return .{ .wayland_surface = .{
        .display = display,
        .surface = surface,
    } };
}
