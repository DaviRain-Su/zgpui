//! Linux GLFW → wgpu surface: prefer Wayland when GLFW is on Wayland,
//! otherwise X11 (`WGPUSurfaceSourceXlibWindow`).

const glfw = @import("glfw_c");
const platform_mod = @import("../platform.zig");
const xlib = @import("xlib_surface.zig");
const wayland = @import("wayland_surface.zig");

pub const Error = xlib.Error || wayland.Error || error{UnsupportedLinuxPlatform};

pub fn attach(window: ?*glfw.GLFWwindow) Error!platform_mod.NativeSurface {
    if (@hasDecl(glfw, "glfwGetPlatform") and @hasDecl(glfw, "GLFW_PLATFORM_WAYLAND")) {
        if (glfw.glfwGetPlatform() == glfw.GLFW_PLATFORM_WAYLAND) {
            return try wayland.attach(window);
        }
    }
    if (@hasDecl(glfw, "glfwGetPlatform") and @hasDecl(glfw, "GLFW_PLATFORM_X11")) {
        if (glfw.glfwGetPlatform() == glfw.GLFW_PLATFORM_X11) {
            return try xlib.attach(window);
        }
    }
    // Older GLFW without glfwGetPlatform: try Wayland then X11.
    if (wayland.attach(window)) |surface| {
        return surface;
    } else |_| {}
    return try xlib.attach(window);
}
