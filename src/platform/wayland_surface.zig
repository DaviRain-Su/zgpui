//! Linux glue: Wayland display + wl_surface from GLFW for
//! `WGPUSurfaceSourceWaylandSurface`.
//!
//! Symbols are resolved via `dlsym` so linking still works when the
//! installed GLFW was built without Wayland support (common on CI).

const std = @import("std");
const glfw = @import("glfw_c");
const platform_mod = @import("../platform.zig");

const GetWaylandDisplayFn = *const fn () callconv(.c) ?*anyopaque;
const GetWaylandWindowFn = *const fn (window: ?*glfw.GLFWwindow) callconv(.c) ?*anyopaque;

pub const Error = error{
    NoWaylandDisplay,
    NoWaylandSurface,
    WaylandUnavailable,
};

fn loadSym(comptime name: [:0]const u8) ?*anyopaque {
    const RTLD_LAZY: c_int = 1;
    const lib = std.c.dlopen("libglfw.so.3", RTLD_LAZY) orelse
        std.c.dlopen("libglfw.so", RTLD_LAZY) orelse
        return null;
    return std.c.dlsym(lib, name);
}

pub fn attach(window: ?*glfw.GLFWwindow) Error!platform_mod.NativeSurface {
    const get_display: GetWaylandDisplayFn = @ptrCast(loadSym("glfwGetWaylandDisplay") orelse return error.WaylandUnavailable);
    const get_surface: GetWaylandWindowFn = @ptrCast(loadSym("glfwGetWaylandWindow") orelse return error.WaylandUnavailable);
    const display = get_display() orelse return error.NoWaylandDisplay;
    const surface = get_surface(window) orelse return error.NoWaylandSurface;
    return .{ .wayland_surface = .{
        .display = display,
        .surface = surface,
    } };
}
