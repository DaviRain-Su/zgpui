//! Linux glue: X11 window handle from GLFW for wgpu `WGPUSurfaceSourceXlibWindow`.
//!
//! Accessors are resolved at runtime via `dlsym(RTLD_DEFAULT, …)` (same pattern
//! as `wayland_surface.zig`) so non-Linux test builds stay linkable and the
//! harness can inject fakes. See `docs/LINUX.md`.

const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw_c");
const platform_mod = @import("../platform.zig");

pub const Error = error{
    NoX11Display,
    NoX11Window,
    X11Unavailable,
};

const GetDisplayFn = *const fn () callconv(.c) ?*anyopaque;
const GetWindowFn = *const fn (?*glfw.GLFWwindow) callconv(.c) c_ulong;

pub const X11Fns = struct {
    get_display: GetDisplayFn,
    get_window: GetWindowFn,
};

/// Test seam: override to inject fake GLFW X11 accessors.
pub var resolve_fns: *const fn () ?X11Fns = resolveX11Fns;

fn dlsymSymbol(comptime T: type, name: [:0]const u8) ?T {
    if (builtin.os.tag != .linux) return null;
    // glibc / musl: RTLD_DEFAULT is a null handle.
    const symbol = std.c.dlsym(null, name.ptr) orelse return null;
    return @ptrCast(@alignCast(symbol));
}

fn resolveX11Fns() ?X11Fns {
    const get_display = dlsymSymbol(GetDisplayFn, "glfwGetX11Display") orelse return null;
    const get_window = dlsymSymbol(GetWindowFn, "glfwGetX11Window") orelse return null;
    return .{
        .get_display = get_display,
        .get_window = get_window,
    };
}

pub fn attach(window: ?*glfw.GLFWwindow) Error!platform_mod.NativeSurface {
    const fns = resolve_fns() orelse return error.X11Unavailable;
    const display = fns.get_display() orelse return error.NoX11Display;
    const xwindow = fns.get_window(window);
    if (xwindow == 0) return error.NoX11Window;
    return .{ .xlib_window = .{
        .display = display,
        .window = xwindow,
    } };
}

test "attach returns X11Unavailable when accessors are missing" {
    const previous = resolve_fns;
    defer resolve_fns = previous;
    resolve_fns = struct {
        fn missing() ?X11Fns {
            return null;
        }
    }.missing;

    try std.testing.expectError(error.X11Unavailable, attach(null));
}

test "attach builds xlib_window when accessors succeed" {
    const previous = resolve_fns;
    defer resolve_fns = previous;

    const display_addr: usize = 0x3333d15a;
    const window_id: c_ulong = 0x4444;

    resolve_fns = struct {
        fn fake() ?X11Fns {
            return .{
                .get_display = struct {
                    fn call() callconv(.c) ?*anyopaque {
                        return @ptrFromInt(0x3333d15a);
                    }
                }.call,
                .get_window = struct {
                    fn call(_: ?*glfw.GLFWwindow) callconv(.c) c_ulong {
                        return 0x4444;
                    }
                }.call,
            };
        }
    }.fake;

    const surface = try attach(null);
    try std.testing.expect(surface == .xlib_window);
    try std.testing.expectEqual(display_addr, @intFromPtr(surface.xlib_window.display));
    try std.testing.expectEqual(window_id, surface.xlib_window.window);
}

test "attach maps null display and zero window to typed errors" {
    const previous = resolve_fns;
    defer resolve_fns = previous;

    resolve_fns = struct {
        fn noDisplay() ?X11Fns {
            return .{
                .get_display = struct {
                    fn call() callconv(.c) ?*anyopaque {
                        return null;
                    }
                }.call,
                .get_window = struct {
                    fn call(_: ?*glfw.GLFWwindow) callconv(.c) c_ulong {
                        return 1;
                    }
                }.call,
            };
        }
    }.noDisplay;
    try std.testing.expectError(error.NoX11Display, attach(null));

    resolve_fns = struct {
        fn noWindow() ?X11Fns {
            return .{
                .get_display = struct {
                    fn call() callconv(.c) ?*anyopaque {
                        return @ptrFromInt(1);
                    }
                }.call,
                .get_window = struct {
                    fn call(_: ?*glfw.GLFWwindow) callconv(.c) c_ulong {
                        return 0;
                    }
                }.call,
            };
        }
    }.noWindow;
    try std.testing.expectError(error.NoX11Window, attach(null));
}
