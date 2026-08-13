//! Linux glue: Wayland display + wl_surface from GLFW for
//! `WGPUSurfaceSourceWaylandSurface`.
//!
//! Many distro / CI GLFW builds are X11-only and do not export
//! `glfwGetWaylandDisplay` / `glfwGetWaylandWindow`. Accessors are resolved at
//! runtime via `dlsym(RTLD_DEFAULT, …)` so X11-only linkers stay happy while
//! Wayland-capable GLFW builds attach a real wl_surface. See `docs/LINUX.md`.

const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw_c");
const platform_mod = @import("../platform.zig");

pub const Error = error{
    NoWaylandDisplay,
    NoWaylandSurface,
    WaylandUnavailable,
};

const GetDisplayFn = *const fn () callconv(.c) ?*anyopaque;
const GetWindowFn = *const fn (?*glfw.GLFWwindow) callconv(.c) ?*anyopaque;

pub const WaylandFns = struct {
    get_display: GetDisplayFn,
    get_window: GetWindowFn,
};

/// Test seam: override to inject fake GLFW Wayland accessors.
pub var resolve_fns: *const fn () ?WaylandFns = resolveWaylandFns;

fn dlsymSymbol(comptime T: type, name: [:0]const u8) ?T {
    if (builtin.os.tag != .linux) return null;
    // glibc / musl: RTLD_DEFAULT is a null handle.
    const symbol = std.c.dlsym(null, name.ptr) orelse return null;
    return @ptrCast(@alignCast(symbol));
}

fn resolveWaylandFns() ?WaylandFns {
    const get_display = dlsymSymbol(GetDisplayFn, "glfwGetWaylandDisplay") orelse return null;
    const get_window = dlsymSymbol(GetWindowFn, "glfwGetWaylandWindow") orelse return null;
    return .{
        .get_display = get_display,
        .get_window = get_window,
    };
}

pub fn attach(window: ?*glfw.GLFWwindow) Error!platform_mod.NativeSurface {
    const fns = resolve_fns() orelse return error.WaylandUnavailable;
    const display = fns.get_display() orelse return error.NoWaylandDisplay;
    const surface = fns.get_window(window) orelse return error.NoWaylandSurface;
    return .{ .wayland_surface = .{
        .display = display,
        .surface = surface,
    } };
}

test "attach returns WaylandUnavailable when accessors are missing" {
    const previous = resolve_fns;
    defer resolve_fns = previous;
    resolve_fns = struct {
        fn missing() ?WaylandFns {
            return null;
        }
    }.missing;

    try std.testing.expectError(error.WaylandUnavailable, attach(null));
}

test "attach builds wayland_surface when accessors succeed" {
    const previous = resolve_fns;
    defer resolve_fns = previous;

    const display_addr: usize = 0x1111d15a;
    const surface_addr: usize = 0x222251fc;

    resolve_fns = struct {
        fn fake() ?WaylandFns {
            return .{
                .get_display = struct {
                    fn call() callconv(.c) ?*anyopaque {
                        return @ptrFromInt(0x1111d15a);
                    }
                }.call,
                .get_window = struct {
                    fn call(_: ?*glfw.GLFWwindow) callconv(.c) ?*anyopaque {
                        return @ptrFromInt(0x222251fc);
                    }
                }.call,
            };
        }
    }.fake;

    const surface = try attach(null);
    try std.testing.expect(surface == .wayland_surface);
    try std.testing.expectEqual(display_addr, @intFromPtr(surface.wayland_surface.display));
    try std.testing.expectEqual(surface_addr, @intFromPtr(surface.wayland_surface.surface));
}

test "attach maps null display and surface to typed errors" {
    const previous = resolve_fns;
    defer resolve_fns = previous;

    resolve_fns = struct {
        fn noDisplay() ?WaylandFns {
            return .{
                .get_display = struct {
                    fn call() callconv(.c) ?*anyopaque {
                        return null;
                    }
                }.call,
                .get_window = struct {
                    fn call(_: ?*glfw.GLFWwindow) callconv(.c) ?*anyopaque {
                        return @ptrFromInt(1);
                    }
                }.call,
            };
        }
    }.noDisplay;
    try std.testing.expectError(error.NoWaylandDisplay, attach(null));

    resolve_fns = struct {
        fn noSurface() ?WaylandFns {
            return .{
                .get_display = struct {
                    fn call() callconv(.c) ?*anyopaque {
                        return @ptrFromInt(1);
                    }
                }.call,
                .get_window = struct {
                    fn call(_: ?*glfw.GLFWwindow) callconv(.c) ?*anyopaque {
                        return null;
                    }
                }.call,
            };
        }
    }.noSurface;
    try std.testing.expectError(error.NoWaylandSurface, attach(null));
}
