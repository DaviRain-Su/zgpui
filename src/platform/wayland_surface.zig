//! Linux glue: Wayland display + wl_surface from GLFW for
//! `WGPUSurfaceSourceWaylandSurface`.
//!
//! GLFW packages on many distros (and GitHub Actions) are X11-only and do not
//! export `glfwGetWayland*`. Until we ship a Wayland-enabled GLFW recipe,
//! this attach path returns `WaylandUnavailable` and `linux_surface` falls
//! back to X11. The `NativeSurface.wayland_surface` + wgpu path remains wired.

const glfw = @import("glfw_c");
const platform_mod = @import("../platform.zig");

pub const Error = error{
    NoWaylandDisplay,
    NoWaylandSurface,
    WaylandUnavailable,
};

pub fn attach(window: ?*glfw.GLFWwindow) Error!platform_mod.NativeSurface {
    _ = window;
    // Enable when linking a GLFW build that exports glfwGetWaylandDisplay /
    // glfwGetWaylandWindow (see docs/ROADMAP.md).
    return error.WaylandUnavailable;
}
