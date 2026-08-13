//! Platform abstraction, modeled on gpui's `platform.rs`.
//!
//! Backends implement `Platform` and `PlatformWindow` as vtable interfaces.
//! The first backend is GLFW + wgpu (`platform/glfw.zig`); native backends
//! (AppKit + Metal, etc.) can be added later without touching upper layers.

const std = @import("std");
const geometry = @import("geometry.zig");
const a11y = @import("a11y.zig");
const element = @import("element.zig");

const Pixels = geometry.Pixels;
const Size = geometry.Size;
const Point = geometry.Point;

// ---------------------------------------------------------------------------
// Input types
// ---------------------------------------------------------------------------

pub const Modifiers = packed struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    command: bool = false,
    caps_lock: bool = false,
};

pub const MouseButton = enum {
    left,
    right,
    middle,
    back,
    forward,
};

/// Physical-ish key identifiers (layout-independent where possible).
pub const Key = enum {
    a, b, c, d, e, f, g, h, i, j, k, l, m,
    n, o, p, q, r, s, t, u, v, w, x, y, z,
    zero, one, two, three, four, five, six, seven, eight, nine,
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    escape, tab, space, enter, backspace, delete,
    left, right, up, down,
    home, end, page_up, page_down,
    minus, equal, left_bracket, right_bracket, backslash,
    semicolon, apostrophe, grave, comma, period, slash,
    left_shift, right_shift, left_control, right_control,
    left_alt, right_alt, left_command, right_command,
    unknown,
};

pub const MouseMoveEvent = struct {
    position: Point(Pixels),
    modifiers: Modifiers = .{},
};

pub const MouseButtonEvent = struct {
    button: MouseButton,
    position: Point(Pixels),
    modifiers: Modifiers = .{},
    click_count: u32 = 1,
};

pub const ScrollUnit = enum {
    /// Wheel ticks / trackpad line equivalents (GLFW default).
    lines,
    /// Precise pixel deltas (macOS trackpad / AppKit).
    pixels,
};

pub const ScrollEvent = struct {
    position: Point(Pixels),
    delta: Point(Pixels),
    unit: ScrollUnit = .lines,
    modifiers: Modifiers = .{},
};

pub const KeyEvent = struct {
    key: Key,
    modifiers: Modifiers = .{},
    is_repeat: bool = false,
};

pub const TextInputEvent = struct {
    /// UTF-8 encoded text produced by this input.
    text: []const u8,
};

/// IME preedit / marked text (may be empty to clear the current preedit).
pub const CompositionEvent = struct {
    text: []const u8,
    /// Caret within preedit, byte offset, or -1 when unknown.
    cursor: i32 = -1,
};

pub const InputEvent = union(enum) {
    mouse_moved: MouseMoveEvent,
    mouse_down: MouseButtonEvent,
    mouse_up: MouseButtonEvent,
    mouse_exited: void,
    scroll: ScrollEvent,
    key_down: KeyEvent,
    key_up: KeyEvent,
    modifiers_changed: Modifiers,
    text_input: TextInputEvent,
    composition_start: void,
    composition_update: CompositionEvent,
    composition_end: void,
};

pub const WindowEvent = union(enum) {
    input: InputEvent,
    /// Logical size changed. New size is queryable via `logicalSize`.
    resized: Size(Pixels),
    /// Backing framebuffer size changed (device pixels). Prefer this over
    /// re-querying after `resized` when configuring GPU surfaces.
    framebuffer_resized: Size(geometry.DevicePixels),
    scale_factor_changed: f32,
    focus_changed: bool,
    /// VoiceOver / AXPress on an accessibility element (element id).
    a11y_press: element.ElementId,
    close_requested: void,
};

/// Callback invoked by the platform for every window event.
pub const EventHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, event: WindowEvent) void,

    pub fn invoke(self: EventHandler, event: WindowEvent) void {
        self.func(self.ctx, event);
    }
};

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------

pub const WindowOptions = struct {
    title: [:0]const u8 = "zgpui",
    size: Size(Pixels) = .{ .width = 800, .height = 600 },
};

/// Handle the renderer uses to create a GPU surface.
pub const NativeSurface = union(enum) {
    /// CAMetalLayer* attached to the window's content view (macOS).
    metal_layer: *anyopaque,
    /// X11 display + window from GLFW (Linux).
    xlib_window: struct {
        display: *anyopaque,
        window: u64,
    },
    /// Wayland display + wl_surface from GLFW (Linux).
    wayland_surface: struct {
        display: *anyopaque,
        surface: *anyopaque,
    },
    /// Win32 HWND + HINSTANCE from GLFW (Windows; scaffolding).
    win32_hwnd: struct {
        hinstance: *anyopaque,
        hwnd: *anyopaque,
    },
};

pub const PlatformWindow = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        logical_size: *const fn (ptr: *anyopaque) Size(Pixels),
        /// Backing framebuffer size in device pixels (authoritative for GPU surfaces).
        framebuffer_size: *const fn (ptr: *anyopaque) Size(geometry.DevicePixels),
        scale_factor: *const fn (ptr: *anyopaque) f32,
        set_title: *const fn (ptr: *anyopaque, title: [:0]const u8) void,
        should_close: *const fn (ptr: *anyopaque) bool,
        native_surface: *const fn (ptr: *anyopaque) NativeSurface,
        set_event_handler: *const fn (ptr: *anyopaque, handler: EventHandler) void,
        deinit: *const fn (ptr: *anyopaque) void,
        /// Optional: push the latest frame accessibility tree to the native layer.
        sync_accessibility: ?*const fn (
            ptr: *anyopaque,
            nodes: []const a11y.Node,
            scale: f32,
            focused: ?element.ElementId,
        ) void = null,
        /// Optional: position the OS IME candidate window near the text caret
        /// (logical pixels, top-left origin, window content coordinates).
        set_ime_position: ?*const fn (ptr: *anyopaque, point: Point(Pixels)) void = null,
    };

    pub fn logicalSize(self: PlatformWindow) Size(Pixels) {
        return self.vtable.logical_size(self.ptr);
    }

    pub fn framebufferSize(self: PlatformWindow) Size(geometry.DevicePixels) {
        return self.vtable.framebuffer_size(self.ptr);
    }

    pub fn scaleFactor(self: PlatformWindow) f32 {
        return self.vtable.scale_factor(self.ptr);
    }

    pub fn setTitle(self: PlatformWindow, title: [:0]const u8) void {
        self.vtable.set_title(self.ptr, title);
    }

    pub fn shouldClose(self: PlatformWindow) bool {
        return self.vtable.should_close(self.ptr);
    }

    pub fn nativeSurface(self: PlatformWindow) NativeSurface {
        return self.vtable.native_surface(self.ptr);
    }

    pub fn setEventHandler(self: PlatformWindow, handler: EventHandler) void {
        self.vtable.set_event_handler(self.ptr, handler);
    }

    pub fn deinit(self: PlatformWindow) void {
        self.vtable.deinit(self.ptr);
    }

    /// Push accessibility nodes when the backend implements native AX sync.
    pub fn syncAccessibility(
        self: PlatformWindow,
        nodes: []const a11y.Node,
        scale: f32,
        focused: ?element.ElementId,
    ) void {
        if (self.vtable.sync_accessibility) |sync| sync(self.ptr, nodes, scale, focused);
    }

    /// Position the OS IME candidate window when the backend supports it.
    /// No-op when `set_ime_position` is unset.
    pub fn setImePosition(self: PlatformWindow, point: Point(Pixels)) void {
        if (self.vtable.set_ime_position) |set| set(self.ptr, point);
    }
};

test "PlatformWindow setImePosition is no-op without vtable hook" {
    const win = PlatformWindow{
        .ptr = @ptrFromInt(1),
        .vtable = &.{
            .logical_size = undefined,
            .framebuffer_size = undefined,
            .scale_factor = undefined,
            .set_title = undefined,
            .should_close = undefined,
            .native_surface = undefined,
            .set_event_handler = undefined,
            .deinit = undefined,
        },
    };
    win.setImePosition(.{ .x = 12, .y = 34 });
}

// ---------------------------------------------------------------------------
// Platform
// ---------------------------------------------------------------------------

pub const Platform = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        open_window: *const fn (ptr: *anyopaque, options: WindowOptions) anyerror!PlatformWindow,
        /// Process pending OS events, dispatching them to event handlers.
        poll_events: *const fn (ptr: *anyopaque) void,
        /// Block until at least one event arrives, then process pending events.
        wait_events: *const fn (ptr: *anyopaque) void,
        deinit: *const fn (ptr: *anyopaque) void,
        /// Optional OS clipboard read. Caller owns the returned slice.
        get_clipboard_text: ?*const fn (ptr: *anyopaque, gpa: std.mem.Allocator) anyerror![]u8 = null,
        /// Optional OS clipboard write.
        set_clipboard_text: ?*const fn (ptr: *anyopaque, text: []const u8) anyerror!void = null,
    };

    pub fn openWindow(self: Platform, options: WindowOptions) !PlatformWindow {
        return self.vtable.open_window(self.ptr, options);
    }

    pub fn pollEvents(self: Platform) void {
        self.vtable.poll_events(self.ptr);
    }

    pub fn waitEvents(self: Platform) void {
        self.vtable.wait_events(self.ptr);
    }

    pub fn deinit(self: Platform) void {
        self.vtable.deinit(self.ptr);
    }

    /// Read OS clipboard text when the backend implements it. Returns `null`
    /// when unavailable; otherwise caller must free the returned slice.
    pub fn getClipboardText(self: Platform, gpa: std.mem.Allocator) !?[]u8 {
        const read = self.vtable.get_clipboard_text orelse return null;
        return try read(self.ptr, gpa);
    }

    /// Write OS clipboard text when the backend implements it. No-op when
    /// unavailable.
    pub fn setClipboardText(self: Platform, text: []const u8) !void {
        const write = self.vtable.set_clipboard_text orelse return;
        try write(self.ptr, text);
    }
};
