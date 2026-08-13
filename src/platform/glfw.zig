//! GLFW backend implementing the `platform.zig` vtable interfaces.
//!
//! `GlfwPlatform` owns the GLFW library lifetime; `GlfwWindow` wraps one
//! GLFWwindow and routes all GLFW callbacks to the window's `EventHandler`
//! via `glfwSetWindowUserPointer`.

const std = @import("std");
const builtin = @import("builtin");
const glfw = @import("glfw_c");
const platform_mod = @import("../platform.zig");
const geometry = @import("../geometry.zig");

const macos_surface = if (builtin.os.tag == .macos) @import("metal_layer.zig") else struct {};
const linux_surface = if (builtin.os.tag == .linux) @import("xlib_surface.zig") else struct {};

const Pixels = geometry.Pixels;
const DevicePixels = geometry.DevicePixels;
const Size = geometry.Size;
const Point = geometry.Point;

const log = std.log.scoped(.glfw);

fn attachNativeSurface(window: *glfw.GLFWwindow, content_scale: f32) !platform_mod.NativeSurface {
    return switch (builtin.os.tag) {
        .macos => .{ .metal_layer = try macos_surface.attach(window, content_scale) },
        .linux => try linux_surface.attach(window),
        else => @compileError("GLFW backend unsupported on this OS"),
    };
}

// ---------------------------------------------------------------------------
// Platform
// ---------------------------------------------------------------------------

pub const GlfwPlatform = struct {
    allocator: std.mem.Allocator,
    /// Most recently opened window; GLFW clipboard APIs require a window handle.
    clipboard_window: ?*GlfwWindow = null,

    /// Initializes the GLFW library. Only one instance may exist at a time.
    pub fn init(allocator: std.mem.Allocator) !*GlfwPlatform {
        const self = try allocator.create(GlfwPlatform);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator };

        _ = glfw.glfwSetErrorCallback(onError);
        if (glfw.glfwInit() == glfw.GLFW_FALSE) return error.GlfwInitFailed;
        return self;
    }

    pub fn platform(self: *GlfwPlatform) platform_mod.Platform {
        return .{ .ptr = self, .vtable = &platform_vtable };
    }

    const platform_vtable = platform_mod.Platform.VTable{
        .open_window = openWindowImpl,
        .poll_events = pollEventsImpl,
        .wait_events = waitEventsImpl,
        .deinit = deinitImpl,
        .get_clipboard_text = getClipboardTextImpl,
        .set_clipboard_text = setClipboardTextImpl,
    };

    fn openWindowImpl(ptr: *anyopaque, options: platform_mod.WindowOptions) anyerror!platform_mod.PlatformWindow {
        const self: *GlfwPlatform = @ptrCast(@alignCast(ptr));
        const window = try GlfwWindow.create(self.allocator, options);
        self.clipboard_window = window;
        return window.platformWindow();
    }

    fn pollEventsImpl(ptr: *anyopaque) void {
        _ = ptr;
        glfw.glfwPollEvents();
    }

    fn waitEventsImpl(ptr: *anyopaque) void {
        _ = ptr;
        glfw.glfwWaitEvents();
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *GlfwPlatform = @ptrCast(@alignCast(ptr));
        glfw.glfwTerminate();
        self.allocator.destroy(self);
    }

    fn getClipboardTextImpl(ptr: *anyopaque, gpa: std.mem.Allocator) ![]u8 {
        const self: *GlfwPlatform = @ptrCast(@alignCast(ptr));
        const window = self.clipboard_window orelse return error.NoClipboardWindow;
        const c_str = glfw.glfwGetClipboardString(window.handle);
        if (c_str == null) return try gpa.dupe(u8, "");
        return try gpa.dupe(u8, std.mem.span(c_str));
    }

    fn setClipboardTextImpl(ptr: *anyopaque, text: []const u8) !void {
        const self: *GlfwPlatform = @ptrCast(@alignCast(ptr));
        const window = self.clipboard_window orelse return error.NoClipboardWindow;
        const ztext = try self.allocator.dupeZ(u8, text);
        defer self.allocator.free(ztext);
        glfw.glfwSetClipboardString(window.handle, ztext.ptr);
    }

    fn onError(error_code: c_int, description: [*c]const u8) callconv(.c) void {
        log.err("GLFW error {d}: {s}", .{ error_code, description });
    }
};

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------

pub const GlfwWindow = struct {
    allocator: std.mem.Allocator,
    handle: *glfw.GLFWwindow,
    /// Native surface source for wgpu (Metal layer on macOS, X11 window on Linux).
    native_surface: platform_mod.NativeSurface,
    handler: ?platform_mod.EventHandler = null,
    /// Last-known modifier state, tracked from key/mouse-button callbacks so
    /// that cursor/scroll events can carry modifiers too.
    modifiers: platform_mod.Modifiers = .{},
    /// Multi-click tracker (presses only).
    last_click_button: ?platform_mod.MouseButton = null,
    last_click_time_s: f64 = 0,
    last_click_pos: Point(Pixels) = .{},
    click_count: u32 = 0,

    pub fn create(allocator: std.mem.Allocator, options: platform_mod.WindowOptions) !*GlfwWindow {
        const self = try allocator.create(GlfwWindow);
        errdefer allocator.destroy(self);

        // No OpenGL/EGL context: the renderer drives the surface via wgpu.
        glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);
        const handle = glfw.glfwCreateWindow(
            @intFromFloat(options.size.width),
            @intFromFloat(options.size.height),
            options.title.ptr,
            null,
            null,
        ) orelse return error.WindowCreationFailed;
        errdefer glfw.glfwDestroyWindow(handle);

        var xscale: f32 = 1;
        var yscale: f32 = 1;
        glfw.glfwGetWindowContentScale(handle, &xscale, &yscale);

        self.* = .{
            .allocator = allocator,
            .handle = handle,
            .native_surface = try attachNativeSurface(handle, xscale),
        };

        glfw.glfwSetWindowUserPointer(handle, self);
        _ = glfw.glfwSetCursorPosCallback(handle, onCursorPos);
        _ = glfw.glfwSetCursorEnterCallback(handle, onCursorEnter);
        _ = glfw.glfwSetMouseButtonCallback(handle, onMouseButton);
        _ = glfw.glfwSetScrollCallback(handle, onScroll);
        _ = glfw.glfwSetKeyCallback(handle, onKey);
        _ = glfw.glfwSetCharCallback(handle, onChar);
        _ = glfw.glfwSetWindowSizeCallback(handle, onWindowSize);
        _ = glfw.glfwSetFramebufferSizeCallback(handle, onFramebufferSize);
        _ = glfw.glfwSetWindowContentScaleCallback(handle, onContentScale);
        _ = glfw.glfwSetWindowFocusCallback(handle, onFocus);
        _ = glfw.glfwSetWindowCloseCallback(handle, onClose);

        return self;
    }

    pub fn platformWindow(self: *GlfwWindow) platform_mod.PlatformWindow {
        return .{ .ptr = self, .vtable = &window_vtable };
    }

    const window_vtable = platform_mod.PlatformWindow.VTable{
        .logical_size = logicalSizeImpl,
        .framebuffer_size = framebufferSizeImpl,
        .scale_factor = scaleFactorImpl,
        .set_title = setTitleImpl,
        .should_close = shouldCloseImpl,
        .native_surface = nativeSurfaceImpl,
        .set_event_handler = setEventHandlerImpl,
        .deinit = deinitImpl,
        .set_ime_position = setImePositionImpl,
    };

    fn logicalSizeImpl(ptr: *anyopaque) Size(Pixels) {
        const self: *GlfwWindow = @ptrCast(@alignCast(ptr));
        var width: c_int = 0;
        var height: c_int = 0;
        glfw.glfwGetWindowSize(self.handle, &width, &height);
        return .{ .width = @floatFromInt(width), .height = @floatFromInt(height) };
    }

    fn framebufferSizeImpl(ptr: *anyopaque) Size(DevicePixels) {
        const self: *GlfwWindow = @ptrCast(@alignCast(ptr));
        var width: c_int = 0;
        var height: c_int = 0;
        glfw.glfwGetFramebufferSize(self.handle, &width, &height);
        return .{ .width = width, .height = height };
    }

    fn scaleFactorImpl(ptr: *anyopaque) f32 {
        const self: *GlfwWindow = @ptrCast(@alignCast(ptr));
        var xscale: f32 = 1;
        var yscale: f32 = 1;
        glfw.glfwGetWindowContentScale(self.handle, &xscale, &yscale);
        return xscale;
    }

    fn setTitleImpl(ptr: *anyopaque, title: [:0]const u8) void {
        const self: *GlfwWindow = @ptrCast(@alignCast(ptr));
        glfw.glfwSetWindowTitle(self.handle, title.ptr);
    }

    fn shouldCloseImpl(ptr: *anyopaque) bool {
        const self: *GlfwWindow = @ptrCast(@alignCast(ptr));
        return glfw.glfwWindowShouldClose(self.handle) != glfw.GLFW_FALSE;
    }

    fn nativeSurfaceImpl(ptr: *anyopaque) platform_mod.NativeSurface {
        const self: *GlfwWindow = @ptrCast(@alignCast(ptr));
        return self.native_surface;
    }

    fn setEventHandlerImpl(ptr: *anyopaque, handler: platform_mod.EventHandler) void {
        const self: *GlfwWindow = @ptrCast(@alignCast(ptr));
        self.handler = handler;
    }

    fn setImePositionImpl(ptr: *anyopaque, point: Point(Pixels)) void {
        const self: *GlfwWindow = @ptrCast(@alignCast(ptr));
        setGlfwImePosition(self.handle, point);
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *GlfwWindow = @ptrCast(@alignCast(ptr));
        glfw.glfwDestroyWindow(self.handle);
        self.allocator.destroy(self);
    }

    // -- GLFW callbacks -----------------------------------------------------

    fn fromHandle(handle: ?*glfw.GLFWwindow) ?*GlfwWindow {
        const user_ptr = glfw.glfwGetWindowUserPointer(handle) orelse return null;
        return @ptrCast(@alignCast(user_ptr));
    }

    fn emit(self: *GlfwWindow, event: platform_mod.WindowEvent) void {
        if (self.handler) |handler| handler.invoke(event);
    }

    fn cursorPosition(self: *GlfwWindow) Point(Pixels) {
        var x: f64 = 0;
        var y: f64 = 0;
        glfw.glfwGetCursorPos(self.handle, &x, &y);
        return .{ .x = @floatCast(x), .y = @floatCast(y) };
    }

    /// Updates tracked modifier state, emitting `modifiers_changed` on change.
    fn updateModifiers(self: *GlfwWindow, mods: c_int) void {
        const new_mods = mapModifiers(mods);
        if (!modifiersEqual(self.modifiers, new_mods)) {
            self.modifiers = new_mods;
            self.emit(.{ .input = .{ .modifiers_changed = new_mods } });
        }
    }

    fn onCursorPos(handle: ?*glfw.GLFWwindow, x: f64, y: f64) callconv(.c) void {
        const self = fromHandle(handle) orelse return;
        self.emit(.{ .input = .{ .mouse_moved = .{
            .position = .{ .x = @floatCast(x), .y = @floatCast(y) },
            .modifiers = self.modifiers,
        } } });
    }

    fn onCursorEnter(handle: ?*glfw.GLFWwindow, entered: c_int) callconv(.c) void {
        const self = fromHandle(handle) orelse return;
        if (entered == glfw.GLFW_FALSE) {
            self.emit(.{ .input = .mouse_exited });
        }
    }

    fn onMouseButton(handle: ?*glfw.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
        const self = fromHandle(handle) orelse return;
        self.updateModifiers(mods);
        const mapped = mapMouseButton(button) orelse return;
        const position = self.cursorPosition();
        var click_count: u32 = 1;
        if (action == glfw.GLFW_PRESS) {
            click_count = self.noteClick(mapped, position);
        }
        const event = platform_mod.MouseButtonEvent{
            .button = mapped,
            .position = position,
            .modifiers = self.modifiers,
            .click_count = click_count,
        };
        self.emit(.{ .input = if (action == glfw.GLFW_PRESS)
            .{ .mouse_down = event }
        else
            .{ .mouse_up = event } });
    }

    /// Update multi-click state. Same button within 500ms and 4px → count++.
    fn noteClick(self: *GlfwWindow, button: platform_mod.MouseButton, position: Point(Pixels)) u32 {
        const now = glfw.glfwGetTime();
        const within_time = now - self.last_click_time_s <= 0.5;
        const dx = position.x - self.last_click_pos.x;
        const dy = position.y - self.last_click_pos.y;
        const within_dist = dx * dx + dy * dy <= 16; // 4px radius
        if (self.last_click_button) |prev| {
            if (prev == button and within_time and within_dist) {
                self.click_count += 1;
            } else {
                self.click_count = 1;
            }
        } else {
            self.click_count = 1;
        }
        self.last_click_button = button;
        self.last_click_time_s = now;
        self.last_click_pos = position;
        return self.click_count;
    }

    fn onScroll(handle: ?*glfw.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.c) void {
        const self = fromHandle(handle) orelse return;
        // Deltas are GLFW scroll units (~lines for wheels; macOS trackpads
        // deliver smooth fractional values). Marked as `.lines`; AppKit uses
        // `.pixels` when hasPreciseScrollingDeltas.
        self.emit(.{ .input = .{ .scroll = .{
            .position = self.cursorPosition(),
            .delta = .{ .x = @floatCast(xoffset), .y = @floatCast(yoffset) },
            .unit = .lines,
            .modifiers = self.modifiers,
        } } });
    }

    fn onKey(handle: ?*glfw.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
        _ = scancode;
        const self = fromHandle(handle) orelse return;
        self.updateModifiers(mods);
        const event = platform_mod.KeyEvent{
            .key = mapKey(key),
            .modifiers = self.modifiers,
            .is_repeat = action == glfw.GLFW_REPEAT,
        };
        self.emit(.{ .input = if (action == glfw.GLFW_RELEASE)
            .{ .key_up = event }
        else
            .{ .key_down = event } });
    }

    fn onChar(handle: ?*glfw.GLFWwindow, codepoint: c_uint) callconv(.c) void {
        const self = fromHandle(handle) orelse return;
        const cp = std.math.cast(u21, codepoint) orelse return;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        // NOTE: the text slice points at this stack buffer and is only valid
        // for the duration of the handler invocation. Handlers that need to
        // keep the text must copy it.
        // IME: GLFW has no cross-platform composition callbacks. OS IME
        // preedit must be wired per-platform (see AppKit marked-text IMPs).
        // Use glfwSetIMEWindowPos when positioning the system IME candidate
        // window. Composition events are available via the test harness.
        self.emit(.{ .input = .{ .text_input = .{ .text = buf[0..len] } } });
    }

    fn onWindowSize(handle: ?*glfw.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
        const self = fromHandle(handle) orelse return;
        self.emit(.{ .resized = .{
            .width = @floatFromInt(width),
            .height = @floatFromInt(height),
        } });
    }

    fn onFramebufferSize(handle: ?*glfw.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
        _ = width;
        _ = height;
        // Emit both: logical resize for layout, framebuffer resize for GPU.
        const self = fromHandle(handle) orelse return;
        self.emit(.{ .resized = logicalSizeImpl(self) });
        self.emit(.{ .framebuffer_resized = framebufferSizeImpl(self) });
    }

    fn onContentScale(handle: ?*glfw.GLFWwindow, xscale: f32, yscale: f32) callconv(.c) void {
        _ = yscale;
        const self = fromHandle(handle) orelse return;
        self.emit(.{ .scale_factor_changed = xscale });
    }

    fn onFocus(handle: ?*glfw.GLFWwindow, focused: c_int) callconv(.c) void {
        const self = fromHandle(handle) orelse return;
        self.emit(.{ .focus_changed = focused != glfw.GLFW_FALSE });
    }

    fn onClose(handle: ?*glfw.GLFWwindow) callconv(.c) void {
        const self = fromHandle(handle) orelse return;
        self.emit(.close_requested);
    }
};

// ---------------------------------------------------------------------------
// IME positioning (optional GLFW APIs)
// ---------------------------------------------------------------------------

/// Position the OS IME candidate window when the linked GLFW build exposes
/// IME helpers (not present in stable 3.4–3.5 headers; no-op otherwise).
fn setGlfwImePosition(handle: *glfw.GLFWwindow, point: Point(Pixels)) void {
    if (@hasDecl(glfw, "glfwSetIMECursorPos")) {
        glfw.glfwSetIMECursorPos(handle, point.x, point.y);
        return;
    }
    if (@hasDecl(glfw, "glfwSetInputMethodCursorPos")) {
        glfw.glfwSetInputMethodCursorPos(handle, point.x, point.y);
        return;
    }
    if (@hasDecl(glfw, "glfwSetIMEWindowPos")) {
        glfw.glfwSetIMEWindowPos(handle, @intFromFloat(point.x), @intFromFloat(point.y));
    }
}

// ---------------------------------------------------------------------------
// Input mapping
// ---------------------------------------------------------------------------

fn modifiersEqual(a: platform_mod.Modifiers, b: platform_mod.Modifiers) bool {
    const Bits = @Int(.unsigned, @bitSizeOf(platform_mod.Modifiers));
    return @as(Bits, @bitCast(a)) == @as(Bits, @bitCast(b));
}

fn mapModifiers(mods: c_int) platform_mod.Modifiers {
    return .{
        .shift = mods & glfw.GLFW_MOD_SHIFT != 0,
        .control = mods & glfw.GLFW_MOD_CONTROL != 0,
        .alt = mods & glfw.GLFW_MOD_ALT != 0,
        .command = mods & glfw.GLFW_MOD_SUPER != 0,
        .caps_lock = mods & glfw.GLFW_MOD_CAPS_LOCK != 0,
    };
}

fn mapMouseButton(button: c_int) ?platform_mod.MouseButton {
    return switch (button) {
        glfw.GLFW_MOUSE_BUTTON_LEFT => .left,
        glfw.GLFW_MOUSE_BUTTON_RIGHT => .right,
        glfw.GLFW_MOUSE_BUTTON_MIDDLE => .middle,
        glfw.GLFW_MOUSE_BUTTON_4 => .back,
        glfw.GLFW_MOUSE_BUTTON_5 => .forward,
        else => null,
    };
}

fn mapKey(key: c_int) platform_mod.Key {
    return switch (key) {
        glfw.GLFW_KEY_A => .a,
        glfw.GLFW_KEY_B => .b,
        glfw.GLFW_KEY_C => .c,
        glfw.GLFW_KEY_D => .d,
        glfw.GLFW_KEY_E => .e,
        glfw.GLFW_KEY_F => .f,
        glfw.GLFW_KEY_G => .g,
        glfw.GLFW_KEY_H => .h,
        glfw.GLFW_KEY_I => .i,
        glfw.GLFW_KEY_J => .j,
        glfw.GLFW_KEY_K => .k,
        glfw.GLFW_KEY_L => .l,
        glfw.GLFW_KEY_M => .m,
        glfw.GLFW_KEY_N => .n,
        glfw.GLFW_KEY_O => .o,
        glfw.GLFW_KEY_P => .p,
        glfw.GLFW_KEY_Q => .q,
        glfw.GLFW_KEY_R => .r,
        glfw.GLFW_KEY_S => .s,
        glfw.GLFW_KEY_T => .t,
        glfw.GLFW_KEY_U => .u,
        glfw.GLFW_KEY_V => .v,
        glfw.GLFW_KEY_W => .w,
        glfw.GLFW_KEY_X => .x,
        glfw.GLFW_KEY_Y => .y,
        glfw.GLFW_KEY_Z => .z,
        glfw.GLFW_KEY_0 => .zero,
        glfw.GLFW_KEY_1 => .one,
        glfw.GLFW_KEY_2 => .two,
        glfw.GLFW_KEY_3 => .three,
        glfw.GLFW_KEY_4 => .four,
        glfw.GLFW_KEY_5 => .five,
        glfw.GLFW_KEY_6 => .six,
        glfw.GLFW_KEY_7 => .seven,
        glfw.GLFW_KEY_8 => .eight,
        glfw.GLFW_KEY_9 => .nine,
        glfw.GLFW_KEY_F1 => .f1,
        glfw.GLFW_KEY_F2 => .f2,
        glfw.GLFW_KEY_F3 => .f3,
        glfw.GLFW_KEY_F4 => .f4,
        glfw.GLFW_KEY_F5 => .f5,
        glfw.GLFW_KEY_F6 => .f6,
        glfw.GLFW_KEY_F7 => .f7,
        glfw.GLFW_KEY_F8 => .f8,
        glfw.GLFW_KEY_F9 => .f9,
        glfw.GLFW_KEY_F10 => .f10,
        glfw.GLFW_KEY_F11 => .f11,
        glfw.GLFW_KEY_F12 => .f12,
        glfw.GLFW_KEY_ESCAPE => .escape,
        glfw.GLFW_KEY_TAB => .tab,
        glfw.GLFW_KEY_SPACE => .space,
        glfw.GLFW_KEY_ENTER => .enter,
        glfw.GLFW_KEY_BACKSPACE => .backspace,
        glfw.GLFW_KEY_DELETE => .delete,
        glfw.GLFW_KEY_LEFT => .left,
        glfw.GLFW_KEY_RIGHT => .right,
        glfw.GLFW_KEY_UP => .up,
        glfw.GLFW_KEY_DOWN => .down,
        glfw.GLFW_KEY_HOME => .home,
        glfw.GLFW_KEY_END => .end,
        glfw.GLFW_KEY_PAGE_UP => .page_up,
        glfw.GLFW_KEY_PAGE_DOWN => .page_down,
        glfw.GLFW_KEY_MINUS => .minus,
        glfw.GLFW_KEY_EQUAL => .equal,
        glfw.GLFW_KEY_LEFT_BRACKET => .left_bracket,
        glfw.GLFW_KEY_RIGHT_BRACKET => .right_bracket,
        glfw.GLFW_KEY_BACKSLASH => .backslash,
        glfw.GLFW_KEY_SEMICOLON => .semicolon,
        glfw.GLFW_KEY_APOSTROPHE => .apostrophe,
        glfw.GLFW_KEY_GRAVE_ACCENT => .grave,
        glfw.GLFW_KEY_COMMA => .comma,
        glfw.GLFW_KEY_PERIOD => .period,
        glfw.GLFW_KEY_SLASH => .slash,
        glfw.GLFW_KEY_LEFT_SHIFT => .left_shift,
        glfw.GLFW_KEY_RIGHT_SHIFT => .right_shift,
        glfw.GLFW_KEY_LEFT_CONTROL => .left_control,
        glfw.GLFW_KEY_RIGHT_CONTROL => .right_control,
        glfw.GLFW_KEY_LEFT_ALT => .left_alt,
        glfw.GLFW_KEY_RIGHT_ALT => .right_alt,
        glfw.GLFW_KEY_LEFT_SUPER => .left_command,
        glfw.GLFW_KEY_RIGHT_SUPER => .right_command,
        else => .unknown,
    };
}

// ---------------------------------------------------------------------------
// Tests (logic only — no window or GPU access)
// ---------------------------------------------------------------------------

test "key mapping covers letters, digits, and named keys" {
    try std.testing.expectEqual(platform_mod.Key.a, mapKey(glfw.GLFW_KEY_A));
    try std.testing.expectEqual(platform_mod.Key.z, mapKey(glfw.GLFW_KEY_Z));
    try std.testing.expectEqual(platform_mod.Key.zero, mapKey(glfw.GLFW_KEY_0));
    try std.testing.expectEqual(platform_mod.Key.nine, mapKey(glfw.GLFW_KEY_9));
    try std.testing.expectEqual(platform_mod.Key.escape, mapKey(glfw.GLFW_KEY_ESCAPE));
    try std.testing.expectEqual(platform_mod.Key.enter, mapKey(glfw.GLFW_KEY_ENTER));
    try std.testing.expectEqual(platform_mod.Key.f12, mapKey(glfw.GLFW_KEY_F12));
    try std.testing.expectEqual(platform_mod.Key.left_command, mapKey(glfw.GLFW_KEY_LEFT_SUPER));
    try std.testing.expectEqual(platform_mod.Key.grave, mapKey(glfw.GLFW_KEY_GRAVE_ACCENT));
    try std.testing.expectEqual(platform_mod.Key.unknown, mapKey(glfw.GLFW_KEY_WORLD_1));
    try std.testing.expectEqual(platform_mod.Key.unknown, mapKey(-1));
}

test "modifier mapping" {
    const none = mapModifiers(0);
    try std.testing.expect(!none.shift and !none.control and !none.alt and
        !none.command and !none.caps_lock);

    const all = mapModifiers(glfw.GLFW_MOD_SHIFT | glfw.GLFW_MOD_CONTROL |
        glfw.GLFW_MOD_ALT | glfw.GLFW_MOD_SUPER | glfw.GLFW_MOD_CAPS_LOCK);
    try std.testing.expect(all.shift and all.control and all.alt and
        all.command and all.caps_lock);

    // NUM_LOCK has no platform equivalent and must not leak into other bits.
    const num = mapModifiers(glfw.GLFW_MOD_NUM_LOCK);
    try std.testing.expect(modifiersEqual(num, .{}));

    try std.testing.expect(modifiersEqual(all, all));
    try std.testing.expect(!modifiersEqual(all, none));
}

test "mouse button mapping" {
    try std.testing.expectEqual(platform_mod.MouseButton.left, mapMouseButton(glfw.GLFW_MOUSE_BUTTON_LEFT).?);
    try std.testing.expectEqual(platform_mod.MouseButton.right, mapMouseButton(glfw.GLFW_MOUSE_BUTTON_RIGHT).?);
    try std.testing.expectEqual(platform_mod.MouseButton.middle, mapMouseButton(glfw.GLFW_MOUSE_BUTTON_MIDDLE).?);
    try std.testing.expectEqual(platform_mod.MouseButton.back, mapMouseButton(glfw.GLFW_MOUSE_BUTTON_4).?);
    try std.testing.expectEqual(platform_mod.MouseButton.forward, mapMouseButton(glfw.GLFW_MOUSE_BUTTON_5).?);
    try std.testing.expectEqual(@as(?platform_mod.MouseButton, null), mapMouseButton(glfw.GLFW_MOUSE_BUTTON_6));
}

test "text input utf8 encoding" {
    var buf: [4]u8 = undefined;
    var len = try std.unicode.utf8Encode('a', &buf);
    try std.testing.expectEqualStrings("a", buf[0..len]);
    len = try std.unicode.utf8Encode(0x4e2d, &buf); // 中
    try std.testing.expectEqualStrings("\xe4\xb8\xad", buf[0..len]);
}

test "setGlfwImePosition is safe when GLFW lacks IME APIs" {
    // Current Homebrew GLFW (3.5.x) does not export IME positioning symbols;
    // this path must compile and be callable without a real window handle.
    setGlfwImePosition(undefined, .{ .x = 4, .y = 8 });
}
