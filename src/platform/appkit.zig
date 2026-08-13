//! Native macOS AppKit backend implementing `platform.zig` vtables.
//!
//! Windowing and input are AppKit (no GLFW). Rendering still goes through
//! wgpu via `NativeSurface.metal_layer` (CAMetalLayer*).

const std = @import("std");
const objc = @import("objc_c");
const platform_mod = @import("../platform.zig");
const geometry = @import("../geometry.zig");
const a11y = @import("../a11y.zig");
const element = @import("../element.zig");
const view = @import("appkit_view.zig");
const keys = @import("appkit_keys.zig");
const a11y_bridge = @import("appkit_a11y.zig");

const Pixels = geometry.Pixels;
const DevicePixels = geometry.DevicePixels;
const Size = geometry.Size;

const log = std.log.scoped(.appkit);

const NSApplicationActivationPolicyRegular: c_long = 0;
const NSWindowStyleMaskTitled: c_ulong = 1 << 0;
const NSWindowStyleMaskClosable: c_ulong = 1 << 1;
const NSWindowStyleMaskMiniaturizable: c_ulong = 1 << 2;
const NSWindowStyleMaskResizable: c_ulong = 1 << 3;
const NSBackingStoreBuffered: c_ulong = 2;

fn sel(name: [:0]const u8) objc.SEL {
    return objc.sel_registerName(name.ptr);
}

fn msgId(obj: objc.id, s: objc.SEL) objc.id {
    const f: *const fn (objc.id, objc.SEL) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    return f(obj, s);
}

fn msgClassId(cls: objc.Class, s: objc.SEL) objc.id {
    const f: *const fn (objc.Class, objc.SEL) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    return f(cls, s);
}

fn msgVoid(obj: objc.id, s: objc.SEL) void {
    const f: *const fn (objc.id, objc.SEL) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    f(obj, s);
}

fn msgSetId(obj: objc.id, s: objc.SEL, v: objc.id) void {
    const f: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    f(obj, s, v);
}

fn msgSetBool(obj: objc.id, s: objc.SEL, v: bool) void {
    const f: *const fn (objc.id, objc.SEL, bool) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    f(obj, s, v);
}

fn msgSetLong(obj: objc.id, s: objc.SEL, v: c_long) void {
    const f: *const fn (objc.id, objc.SEL, c_long) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    f(obj, s, v);
}

fn msgBoolId(obj: objc.id, s: objc.SEL, arg: objc.id) bool {
    const f: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) objc.BOOL = @ptrCast(&objc.objc_msgSend);
    return f(obj, s, arg) != 0;
}

fn msgIdId(obj: objc.id, s: objc.SEL, arg: objc.id) objc.id {
    const f: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    return f(obj, s, arg);
}

fn msgBoolIdId(obj: objc.id, s: objc.SEL, a: objc.id, b: objc.id) bool {
    const f: *const fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) objc.BOOL = @ptrCast(&objc.objc_msgSend);
    return f(obj, s, a, b) != 0;
}

fn nsStringUtf8Slice(ns_str: objc.id) ?[]const u8 {
    if (ns_str == null) return null;
    const utf8_fn: *const fn (objc.id, objc.SEL) callconv(.c) [*c]const u8 = @ptrCast(&objc.objc_msgSend);
    const utf8 = utf8_fn(ns_str, sel("UTF8String"));
    if (utf8 == null) return null;
    return std.mem.span(utf8);
}

fn generalPasteboard() ?objc.id {
    const cls = objc.objc_getClass("NSPasteboard") orelse return null;
    return msgClassId(cls, sel("generalPasteboard"));
}

fn pasteboardStringType() objc.id {
    return nsString("public.utf8-plain-text");
}

fn readPasteboardText(gpa: std.mem.Allocator) ![]u8 {
    const pasteboard = generalPasteboard() orelse return try gpa.dupe(u8, "");
    const ns_str = msgIdId(pasteboard, sel("stringForType:"), pasteboardStringType());
    const slice = nsStringUtf8Slice(ns_str) orelse return try gpa.dupe(u8, "");
    return try gpa.dupe(u8, slice);
}

fn writePasteboardText(text: [:0]const u8) void {
    const pasteboard = generalPasteboard() orelse return;
    msgVoid(pasteboard, sel("clearContents"));
    const ns_str = nsString(text);
    _ = msgBoolIdId(pasteboard, sel("setString:forType:"), ns_str, pasteboardStringType());
}

fn nsString(utf8: [:0]const u8) objc.id {
    const cls = objc.objc_getClass("NSString").?;
    const f: *const fn (objc.Class, objc.SEL, [*:0]const u8) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    return f(cls, sel("stringWithUTF8String:"), utf8.ptr);
}

fn distantPast() objc.id {
    const cls = objc.objc_getClass("NSDate").?;
    return msgClassId(cls, sel("distantPast"));
}

fn distantFuture() objc.id {
    const cls = objc.objc_getClass("NSDate").?;
    return msgClassId(cls, sel("distantFuture"));
}

fn defaultRunLoopMode() objc.id {
    // NSDefaultRunLoopMode == @"kCFRunLoopDefaultMode"
    return nsString("kCFRunLoopDefaultMode");
}

fn sharedApplication() !objc.id {
    const cls = objc.objc_getClass("NSApplication") orelse return error.MissingNSApplication;
    const app = msgClassId(cls, sel("sharedApplication"));
    if (app == null) return error.NSApplicationUnavailable;
    return app;
}

fn pumpOnce(app: objc.id, until: objc.id) void {
    const next: *const fn (objc.id, objc.SEL, c_ulong, objc.id, objc.id, bool) callconv(.c) objc.id =
        @ptrCast(&objc.objc_msgSend);
    const event = next(
        app,
        sel("nextEventMatchingMask:untilDate:inMode:dequeue:"),
        view.event_mask_any,
        until,
        defaultRunLoopMode(),
        true,
    );
    if (event != null) {
        const send: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
        send(app, sel("sendEvent:"), event);
    }
}

fn pollAppKit(app: objc.id) void {
    // Drain the queue without blocking (untilDate: distantPast).
    while (true) {
        const next: *const fn (objc.id, objc.SEL, c_ulong, objc.id, objc.id, bool) callconv(.c) objc.id =
            @ptrCast(&objc.objc_msgSend);
        const event = next(
            app,
            sel("nextEventMatchingMask:untilDate:inMode:dequeue:"),
            view.event_mask_any,
            distantPast(),
            defaultRunLoopMode(),
            true,
        );
        if (event == null) break;
        const send: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
        send(app, sel("sendEvent:"), event);
    }
}

fn waitAppKit(app: objc.id) void {
    // Block until one event, then drain the rest (GLFW waitEvents semantics).
    pumpOnce(app, distantFuture());
    pollAppKit(app);
}

// ---------------------------------------------------------------------------
// Platform
// ---------------------------------------------------------------------------

pub const AppKitPlatform = struct {
    allocator: std.mem.Allocator,
    ns_app: objc.id,

    pub fn init(allocator: std.mem.Allocator) !*AppKitPlatform {
        try view.ensureClassesRegistered();

        const self = try allocator.create(AppKitPlatform);
        errdefer allocator.destroy(self);

        const app = try sharedApplication();
        msgSetLong(app, sel("setActivationPolicy:"), NSApplicationActivationPolicyRegular);
        msgVoid(app, sel("finishLaunching"));

        self.* = .{
            .allocator = allocator,
            .ns_app = app,
        };
        return self;
    }

    pub fn platform(self: *AppKitPlatform) platform_mod.Platform {
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
        const self: *AppKitPlatform = @ptrCast(@alignCast(ptr));
        const window = try AppKitWindow.create(self.allocator, self.ns_app, options);
        return window.platformWindow();
    }

    fn pollEventsImpl(ptr: *anyopaque) void {
        const self: *AppKitPlatform = @ptrCast(@alignCast(ptr));
        pollAppKit(self.ns_app);
    }

    fn waitEventsImpl(ptr: *anyopaque) void {
        const self: *AppKitPlatform = @ptrCast(@alignCast(ptr));
        waitAppKit(self.ns_app);
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *AppKitPlatform = @ptrCast(@alignCast(ptr));
        // NSApplication is a shared singleton; do not release it.
        self.allocator.destroy(self);
    }

    fn getClipboardTextImpl(ptr: *anyopaque, gpa: std.mem.Allocator) ![]u8 {
        _ = ptr;
        return try readPasteboardText(gpa);
    }

    fn setClipboardTextImpl(ptr: *anyopaque, text: []const u8) !void {
        const self: *AppKitPlatform = @ptrCast(@alignCast(ptr));
        const ztext = try self.allocator.dupeZ(u8, text);
        defer self.allocator.free(ztext);
        writePasteboardText(ztext);
    }
};

// ---------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------

pub const AppKitWindow = struct {
    allocator: std.mem.Allocator,
    ns_window: objc.id,
    ns_view: objc.id,
    ns_delegate: objc.id,
    metal_layer: *anyopaque,
    host: view.ViewHost,
    a11y_store: a11y_bridge.Store,
    handler: ?platform_mod.EventHandler = null,
    should_close: bool = false,
    modifiers: platform_mod.Modifiers = .{},
    /// Caret anchor for NSTextInputClient (logical px, top-left origin).
    ime_position: ?geometry.Point(Pixels) = null,
    ime_caret_height: Pixels = 16,
    /// True while marked text / IME preedit is active.
    composing: bool = false,

    fn emit(self: *AppKitWindow, event: platform_mod.WindowEvent) void {
        if (event == .input) {
            switch (event.input) {
                .modifiers_changed => |m| {
                    if (!keys.modifiersEqual(self.modifiers, m)) {
                        self.modifiers = m;
                    } else return;
                },
                else => {},
            }
        }
        if (self.handler) |handler| handler.invoke(event);
    }

    fn emitFromHost(ctx: *anyopaque, event: platform_mod.WindowEvent) void {
        const self: *AppKitWindow = @ptrCast(@alignCast(ctx));
        self.emit(event);
    }

    fn requestCloseFromHost(ctx: *anyopaque) void {
        const self: *AppKitWindow = @ptrCast(@alignCast(ctx));
        self.should_close = true;
        self.emit(.close_requested);
    }

    fn syncLayerFromHost(ctx: *anyopaque) void {
        _ = ctx;
        // Layer geometry is updated inside the view IMP path.
    }

    fn imeAnchorFromHost(ctx: *anyopaque, caret_height_out: *Pixels) ?geometry.Point(Pixels) {
        const self: *AppKitWindow = @ptrCast(@alignCast(ctx));
        caret_height_out.* = self.ime_caret_height;
        return self.ime_position;
    }

    fn setComposingFromHost(ctx: *anyopaque, composing: bool) void {
        const self: *AppKitWindow = @ptrCast(@alignCast(ctx));
        self.composing = composing;
    }

    fn isComposingFromHost(ctx: *anyopaque) bool {
        const self: *AppKitWindow = @ptrCast(@alignCast(ctx));
        return self.composing;
    }

    fn a11yPressFromHost(ctx: *anyopaque, id: element.ElementId) void {
        const self: *AppKitWindow = @ptrCast(@alignCast(ctx));
        if (self.handler) |handler| handler.invoke(.{ .a11y_press = id });
    }

    fn a11yAdjustFromHost(ctx: *anyopaque, id: element.ElementId, increment: bool) void {
        const self: *AppKitWindow = @ptrCast(@alignCast(ctx));
        if (self.handler) |handler| handler.invoke(.{ .a11y_adjust = .{
            .id = id,
            .increment = increment,
        } });
    }

    pub fn create(
        allocator: std.mem.Allocator,
        ns_app: objc.id,
        options: platform_mod.WindowOptions,
    ) !*AppKitWindow {
        const self = try allocator.create(AppKitWindow);
        errdefer allocator.destroy(self);

        // Host callbacks are filled before creating the view/delegate so IMPs
        // can safely resolve the ivar as soon as objects exist.
        self.* = .{
            .allocator = allocator,
            .ns_window = null,
            .ns_view = null,
            .ns_delegate = null,
            .metal_layer = undefined,
            .host = .{
                .ctx = self,
                .emit = emitFromHost,
                .request_close = requestCloseFromHost,
                .sync_layer = syncLayerFromHost,
                .ime_anchor = imeAnchorFromHost,
                .set_composing = setComposingFromHost,
                .is_composing = isComposingFromHost,
            },
            .a11y_store = a11y_bridge.Store.init(allocator),
        };
        errdefer self.a11y_store.deinit();

        const frame = view.NSRect{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{
                .width = options.size.width,
                .height = options.size.height,
            },
        };

        const content_view = try view.createMetalView(frame, &self.host);
        errdefer view.releaseObject(content_view);

        const layer = view.metalLayerOf(content_view) orelse return error.MetalLayerMissing;

        const delegate = try view.createWindowDelegate(&self.host);
        errdefer view.releaseObject(delegate);

        const window_class = objc.objc_getClass("NSWindow") orelse return error.MissingNSWindow;
        const alloc = msgClassId(window_class, sel("alloc"));
        if (alloc == null) return error.WindowAllocFailed;

        const style: c_ulong = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
            NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
        const init_fn: *const fn (
            objc.id,
            objc.SEL,
            view.NSRect,
            c_ulong,
            c_ulong,
            bool,
        ) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
        const ns_window = init_fn(
            alloc,
            sel("initWithContentRect:styleMask:backing:defer:"),
            frame,
            style,
            NSBackingStoreBuffered,
            false,
        );
        if (ns_window == null) {
            view.releaseObject(alloc);
            return error.WindowInitFailed;
        }
        errdefer view.releaseObject(ns_window);

        msgSetId(ns_window, sel("setTitle:"), nsString(options.title));
        msgSetId(ns_window, sel("setContentView:"), content_view);
        msgSetId(ns_window, sel("setDelegate:"), delegate);
        msgSetBool(ns_window, sel("setAcceptsMouseMovedEvents:"), true);
        msgSetBool(ns_window, sel("setReleasedWhenClosed:"), false);
        _ = msgBoolId(ns_window, sel("makeFirstResponder:"), content_view);
        msgVoid(ns_window, sel("center"));
        msgSetId(ns_window, sel("makeKeyAndOrderFront:"), null);

        // Activate so the window receives key events without clicking first.
        const activate: *const fn (objc.id, objc.SEL, bool) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
        activate(ns_app, sel("activateIgnoringOtherApps:"), true);

        // Sync CAMetalLayer contentsScale now that the view is window-attached.
        const scale = view.viewScaleFactor(content_view);
        const set_scale: *const fn (objc.id, objc.SEL, f64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
        set_scale(@ptrCast(@alignCast(layer)), sel("setContentsScale:"), scale);

        self.ns_window = ns_window;
        self.ns_view = content_view;
        self.ns_delegate = delegate;
        self.metal_layer = layer;
        a11y_bridge.attachStore(
            content_view,
            &self.a11y_store,
            .{
                .ctx = self,
                .func = a11yPressFromHost,
            },
            .{
                .ctx = self,
                .func = a11yAdjustFromHost,
            },
        );
        return self;
    }

    pub fn platformWindow(self: *AppKitWindow) platform_mod.PlatformWindow {
        return .{ .ptr = self, .vtable = &window_vtable };
    }

    fn setEventHandlerImpl(ptr: *anyopaque, handler: platform_mod.EventHandler) void {
        const self: *AppKitWindow = @ptrCast(@alignCast(ptr));
        self.handler = handler;
    }

    fn setImePositionImpl(ptr: *anyopaque, point: geometry.Point(Pixels)) void {
        const self: *AppKitWindow = @ptrCast(@alignCast(ptr));
        self.ime_position = point;
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
        .sync_accessibility = syncAccessibilityImpl,
        .set_ime_position = setImePositionImpl,
    };

    fn logicalSizeImpl(ptr: *anyopaque) Size(Pixels) {
        const self: *AppKitWindow = @ptrCast(@alignCast(ptr));
        return view.viewLogicalSize(self.ns_view);
    }

    fn framebufferSizeImpl(ptr: *anyopaque) Size(DevicePixels) {
        const self: *AppKitWindow = @ptrCast(@alignCast(ptr));
        return view.viewFramebufferSize(self.ns_view);
    }

    fn scaleFactorImpl(ptr: *anyopaque) f32 {
        const self: *AppKitWindow = @ptrCast(@alignCast(ptr));
        return view.viewScaleFactor(self.ns_view);
    }

    fn setTitleImpl(ptr: *anyopaque, title: [:0]const u8) void {
        const self: *AppKitWindow = @ptrCast(@alignCast(ptr));
        msgSetId(self.ns_window, sel("setTitle:"), nsString(title));
    }

    fn shouldCloseImpl(ptr: *anyopaque) bool {
        const self: *AppKitWindow = @ptrCast(@alignCast(ptr));
        return self.should_close;
    }

    fn nativeSurfaceImpl(ptr: *anyopaque) platform_mod.NativeSurface {
        const self: *AppKitWindow = @ptrCast(@alignCast(ptr));
        return .{ .metal_layer = self.metal_layer };
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *AppKitWindow = @ptrCast(@alignCast(ptr));
        // Clear delegate before closing to avoid callbacks into freed memory.
        msgSetId(self.ns_window, sel("setDelegate:"), null);
        msgVoid(self.ns_window, sel("close"));
        view.releaseObject(self.ns_delegate);
        view.releaseObject(self.ns_view);
        view.releaseObject(self.ns_window);
        // Extra retain from createMetalView's CAMetalLayer.
        view.releaseObject(@ptrCast(@alignCast(self.metal_layer)));
        self.a11y_store.deinit();
        self.allocator.destroy(self);
    }

    fn syncAccessibilityImpl(
        ptr: *anyopaque,
        nodes: []const a11y.Node,
        scale: f32,
        focused: ?element.ElementId,
    ) void {
        const self: *AppKitWindow = @ptrCast(@alignCast(ptr));
        a11y_bridge.syncAccessibilityTree(self.ns_view, &self.a11y_store, nodes, scale, focused);
    }
};

// Re-export key mapping tests via this module so `refAllDecls` picks them up.
comptime {
    _ = keys;
    _ = view;
    _ = a11y_bridge;
}

test {
    _ = @import("appkit_keys.zig");
    _ = @import("appkit_a11y.zig");
}
