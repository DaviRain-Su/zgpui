//! Custom NSView subclass (objc runtime) hosting a CAMetalLayer, plus a
//! minimal NSWindowDelegate. Event IMPs forward into an opaque `ViewHost`.

const std = @import("std");
const objc = @import("objc_c");
const platform_mod = @import("../platform.zig");
const geometry = @import("../geometry.zig");
const keys = @import("appkit_keys.zig");
const a11y_mod = @import("appkit_a11y.zig");

const Pixels = geometry.Pixels;
const DevicePixels = geometry.DevicePixels;
const Size = geometry.Size;
const Point = geometry.Point;

const log = std.log.scoped(.appkit_view);

pub const NSPoint = extern struct { x: f64, y: f64 };
pub const NSSize = extern struct { width: f64, height: f64 };
pub const NSRect = extern struct { origin: NSPoint, size: NSSize };
pub const NSRange = extern struct { location: c_ulong, length: c_ulong };

const YES: objc.BOOL = 1;
const NO: objc.BOOL = 0;

const NSEventMaskAny: c_ulong = std.math.maxInt(c_ulong);
const NSTrackingMouseEnteredAndExited: c_ulong = 0x01;
const NSTrackingActiveInKeyWindow: c_ulong = 0x20;
const NSTrackingInVisibleRect: c_ulong = 0x200;
const NSTrackingEnabledDuringMouseDrag: c_ulong = 0x400;

const view_class_name = "ZgpuiMetalView";
const delegate_class_name = "ZgpuiWindowDelegate";
const host_ivar = "zgpuiHost";

/// Opaque bridge from objc IMPs back into `AppKitWindow`.
pub const ViewHost = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, event: platform_mod.WindowEvent) void,
    /// Sets should_close; windowShouldClose returns NO so the window stays
    /// alive until `deinit` (GLFW-like semantics).
    request_close: *const fn (ctx: *anyopaque) void,
    sync_layer: *const fn (ctx: *anyopaque) void,
    /// Caret anchor for `firstRectForCharacterRange` (top-left logical px).
    ime_anchor: *const fn (ctx: *anyopaque, caret_height_out: *Pixels) ?Point(Pixels),
    set_composing: *const fn (ctx: *anyopaque, composing: bool) void,
    is_composing: *const fn (ctx: *anyopaque) bool,
};

var view_class: objc.Class = null;
var delegate_class: objc.Class = null;
var classes_registered = false;

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

fn msgSetBool(obj: objc.id, s: objc.SEL, v: bool) void {
    const f: *const fn (objc.id, objc.SEL, bool) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    f(obj, s, v);
}

fn msgSetId(obj: objc.id, s: objc.SEL, v: objc.id) void {
    const f: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    f(obj, s, v);
}

fn msgSetF64(obj: objc.id, s: objc.SEL, v: f64) void {
    const f: *const fn (objc.id, objc.SEL, f64) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    f(obj, s, v);
}

fn msgGetF64(obj: objc.id, s: objc.SEL) f64 {
    const f: *const fn (objc.id, objc.SEL) callconv(.c) f64 = @ptrCast(&objc.objc_msgSend);
    return f(obj, s);
}

fn msgGetBool(obj: objc.id, s: objc.SEL) bool {
    const f: *const fn (objc.id, objc.SEL) callconv(.c) objc.BOOL = @ptrCast(&objc.objc_msgSend);
    return f(obj, s) != NO;
}

fn msgGetULong(obj: objc.id, s: objc.SEL) c_ulong {
    const f: *const fn (objc.id, objc.SEL) callconv(.c) c_ulong = @ptrCast(&objc.objc_msgSend);
    return f(obj, s);
}

fn msgGetLong(obj: objc.id, s: objc.SEL) c_long {
    const f: *const fn (objc.id, objc.SEL) callconv(.c) c_long = @ptrCast(&objc.objc_msgSend);
    return f(obj, s);
}

fn msgGetUShort(obj: objc.id, s: objc.SEL) c_ushort {
    const f: *const fn (objc.id, objc.SEL) callconv(.c) c_ushort = @ptrCast(&objc.objc_msgSend);
    return f(obj, s);
}

fn msgGetRect(obj: objc.id, s: objc.SEL) NSRect {
    const f: *const fn (objc.id, objc.SEL) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
    return f(obj, s);
}

fn msgGetPoint(obj: objc.id, s: objc.SEL) NSPoint {
    const f: *const fn (objc.id, objc.SEL) callconv(.c) NSPoint = @ptrCast(&objc.objc_msgSend);
    return f(obj, s);
}

fn msgConvertPoint(view: objc.id, s: objc.SEL, point: NSPoint, from: objc.id) NSPoint {
    const f: *const fn (objc.id, objc.SEL, NSPoint, objc.id) callconv(.c) NSPoint = @ptrCast(&objc.objc_msgSend);
    return f(view, s, point, from);
}

fn msgRetain(obj: objc.id) objc.id {
    return msgId(obj, sel("retain"));
}

fn msgRelease(obj: objc.id) void {
    msgVoid(obj, sel("release"));
}

fn hostFrom(obj: objc.id) ?*ViewHost {
    var value: ?*anyopaque = null;
    _ = objc.object_getInstanceVariable(obj, host_ivar, &value);
    if (value == null) return null;
    return @ptrCast(@alignCast(value));
}

fn setHost(obj: objc.id, host: *ViewHost) void {
    _ = objc.object_setInstanceVariable(obj, host_ivar, host);
}

fn emitHost(host: *ViewHost, event: platform_mod.WindowEvent) void {
    host.emit(host.ctx, event);
}

fn logicalSizeOf(view: objc.id) Size(Pixels) {
    const bounds = msgGetRect(view, sel("bounds"));
    return .{ .width = @floatCast(bounds.size.width), .height = @floatCast(bounds.size.height) };
}

fn scaleOf(view: objc.id) f32 {
    const window = msgId(view, sel("window"));
    if (window == null) return 1.0;
    return @floatCast(msgGetF64(window, sel("backingScaleFactor")));
}

fn framebufferSizeOf(view: objc.id) Size(DevicePixels) {
    const logical = logicalSizeOf(view);
    const scale = scaleOf(view);
    return .{
        .width = @intFromFloat(@round(logical.width * scale)),
        .height = @intFromFloat(@round(logical.height * scale)),
    };
}

/// AppKit is bottom-left; zgpui/GLFW are top-left.
fn mousePosition(view: objc.id, event: objc.id) Point(Pixels) {
    const win_point = msgGetPoint(event, sel("locationInWindow"));
    const local = msgConvertPoint(view, sel("convertPoint:fromView:"), win_point, null);
    const bounds = msgGetRect(view, sel("bounds"));
    return .{
        .x = @floatCast(local.x),
        .y = @floatCast(bounds.size.height - local.y),
    };
}

fn updateLayerGeometry(view: objc.id) void {
    const layer = msgId(view, sel("layer"));
    if (layer == null) return;
    const scale = scaleOf(view);
    msgSetF64(layer, sel("setContentsScale:"), scale);
    // Keep drawableSize in sync for Metal; wgpu also configures via surface.
    const fb = framebufferSizeOf(view);
    const size = NSSize{
        .width = @floatFromInt(fb.width),
        .height = @floatFromInt(fb.height),
    };
    const set_drawable: *const fn (objc.id, objc.SEL, NSSize) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    set_drawable(layer, sel("setDrawableSize:"), size);
}

fn emitResizeIfChanged(view_obj: objc.id, host: *ViewHost, old_logical: Size(Pixels), old_scale: f32) void {
    updateLayerGeometry(view_obj);
    host.sync_layer(host.ctx);
    const logical = logicalSizeOf(view_obj);
    const scale = scaleOf(view_obj);
    const size_changed = logical.width != old_logical.width or logical.height != old_logical.height;
    const scale_changed = scale != old_scale;
    if (size_changed) {
        emitHost(host, .{ .resized = logical });
        emitHost(host, .{ .framebuffer_resized = framebufferSizeOf(view_obj) });
    }
    if (scale_changed) {
        emitHost(host, .{ .scale_factor_changed = scale });
    }
}

// ---------------------------------------------------------------------------
// Class registration
// ---------------------------------------------------------------------------

fn addMethod(cls: objc.Class, name: [:0]const u8, imp: objc.IMP, types: [:0]const u8) void {
    if (objc.class_addMethod(cls, sel(name), imp, types.ptr) == NO) {
        log.warn("class_addMethod failed for {s}", .{name});
    }
}

pub fn ensureClassesRegistered() !void {
    if (classes_registered) return;

    const ns_view = objc.objc_getClass("NSView") orelse return error.MissingNSView;
    const ns_object = objc.objc_getClass("NSObject") orelse return error.MissingNSObject;

    view_class = objc.objc_allocateClassPair(ns_view, view_class_name, 0) orelse
        return error.ViewClassAllocationFailed;
    if (objc.class_addIvar(
        view_class,
        host_ivar,
        @sizeOf(*anyopaque),
        std.math.log2_int(u16, @alignOf(*anyopaque)),
        "?",
    ) == NO) return error.ViewIvarFailed;

    a11y_mod.registerViewAccessibilityIvar(view_class);
    a11y_mod.registerViewAccessibilityMethods(view_class);

    addMethod(view_class, "acceptsFirstResponder", @ptrCast(&impAcceptsFirstResponder), "c@:");
    addMethod(view_class, "isOpaque", @ptrCast(&impIsOpaque), "c@:");
    addMethod(view_class, "mouseDown:", @ptrCast(&impMouseDown), "v@:@");
    addMethod(view_class, "mouseUp:", @ptrCast(&impMouseUp), "v@:@");
    addMethod(view_class, "rightMouseDown:", @ptrCast(&impRightMouseDown), "v@:@");
    addMethod(view_class, "rightMouseUp:", @ptrCast(&impRightMouseUp), "v@:@");
    addMethod(view_class, "otherMouseDown:", @ptrCast(&impOtherMouseDown), "v@:@");
    addMethod(view_class, "otherMouseUp:", @ptrCast(&impOtherMouseUp), "v@:@");
    addMethod(view_class, "mouseDragged:", @ptrCast(&impMouseDragged), "v@:@");
    addMethod(view_class, "rightMouseDragged:", @ptrCast(&impMouseDragged), "v@:@");
    addMethod(view_class, "otherMouseDragged:", @ptrCast(&impMouseDragged), "v@:@");
    addMethod(view_class, "mouseMoved:", @ptrCast(&impMouseMoved), "v@:@");
    addMethod(view_class, "mouseEntered:", @ptrCast(&impMouseEntered), "v@:@");
    addMethod(view_class, "mouseExited:", @ptrCast(&impMouseExited), "v@:@");
    addMethod(view_class, "scrollWheel:", @ptrCast(&impScrollWheel), "v@:@");
    addMethod(view_class, "keyDown:", @ptrCast(&impKeyDown), "v@:@");
    addMethod(view_class, "keyUp:", @ptrCast(&impKeyUp), "v@:@");
    addMethod(view_class, "flagsChanged:", @ptrCast(&impFlagsChanged), "v@:@");
    // NSTextInputClient (IME marked text / commit).
    addMethod(view_class, "insertText:replacementRange:", @ptrCast(&impInsertText), "v@:@{NSRange=QQ}");
    addMethod(view_class, "setMarkedText:selectedRange:replacementRange:", @ptrCast(&impSetMarkedText), "v@:@{NSRange=QQ}{NSRange=QQ}");
    addMethod(view_class, "unmarkText", @ptrCast(&impUnmarkText), "v@:");
    addMethod(view_class, "hasMarkedText", @ptrCast(&impHasMarkedText), "c@:");
    addMethod(view_class, "markedRange", @ptrCast(&impMarkedRange), "{NSRange=QQ}@:");
    addMethod(view_class, "selectedRange", @ptrCast(&impSelectedRange), "{NSRange=QQ}@:");
    addMethod(view_class, "firstRectForCharacterRange:actualRange:", @ptrCast(&impFirstRectForCharacterRange), "{NSRect={NSPoint=dd}{NSSize=dd}}@:{NSRange=QQ}^{NSRange=QQ}");
    addMethod(view_class, "viewDidChangeBackingProperties", @ptrCast(&impBackingChanged), "v@:");
    addMethod(view_class, "setFrameSize:", @ptrCast(&impSetFrameSize), "v@:{CGSize=dd}");
    addMethod(view_class, "updateTrackingAreas", @ptrCast(&impUpdateTrackingAreas), "v@:");
    objc.objc_registerClassPair(view_class);

    delegate_class = objc.objc_allocateClassPair(ns_object, delegate_class_name, 0) orelse
        return error.DelegateClassAllocationFailed;
    if (objc.class_addIvar(
        delegate_class,
        host_ivar,
        @sizeOf(*anyopaque),
        std.math.log2_int(u16, @alignOf(*anyopaque)),
        "?",
    ) == NO) return error.DelegateIvarFailed;
    addMethod(delegate_class, "windowShouldClose:", @ptrCast(&impWindowShouldClose), "c@:@");
    addMethod(delegate_class, "windowDidBecomeKey:", @ptrCast(&impWindowDidBecomeKey), "v@:@");
    addMethod(delegate_class, "windowDidResignKey:", @ptrCast(&impWindowDidResignKey), "v@:@");
    objc.objc_registerClassPair(delegate_class);

    classes_registered = true;
}

pub fn createMetalView(frame: NSRect, host: *ViewHost) !objc.id {
    try ensureClassesRegistered();
    const alloc = msgClassId(view_class, sel("alloc"));
    if (alloc == null) return error.ViewAllocFailed;
    const init: *const fn (objc.id, objc.SEL, NSRect) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    const view = init(alloc, sel("initWithFrame:"), frame);
    if (view == null) {
        msgRelease(alloc);
        return error.ViewInitFailed;
    }

    msgSetBool(view, sel("setWantsLayer:"), true);

    const layer_class = objc.objc_getClass("CAMetalLayer") orelse return error.MissingCAMetalLayerClass;
    const layer = msgClassId(layer_class, sel("layer"));
    if (layer == null) return error.MetalLayerCreationFailed;
    const retained_layer = msgRetain(layer);
    msgSetId(view, sel("setLayer:"), retained_layer);
    // View retains the layer via setLayer:; we keep an extra retain for the
    // host's metal_layer pointer until window deinit releases it.

    setHost(view, host);
    updateLayerGeometry(view);
    installTrackingArea(view);
    return view;
}

pub fn createWindowDelegate(host: *ViewHost) !objc.id {
    try ensureClassesRegistered();
    const alloc = msgClassId(delegate_class, sel("alloc"));
    if (alloc == null) return error.DelegateAllocFailed;
    const delegate = msgId(alloc, sel("init"));
    if (delegate == null) {
        msgRelease(alloc);
        return error.DelegateInitFailed;
    }
    setHost(delegate, host);
    return delegate;
}

pub fn metalLayerOf(view: objc.id) ?*anyopaque {
    const layer = msgId(view, sel("layer"));
    if (layer == null) return null;
    return @ptrCast(layer);
}

pub fn viewLogicalSize(view: objc.id) Size(Pixels) {
    return logicalSizeOf(view);
}

pub fn viewFramebufferSize(view: objc.id) Size(DevicePixels) {
    return framebufferSizeOf(view);
}

pub fn viewScaleFactor(view: objc.id) f32 {
    return scaleOf(view);
}

pub fn releaseObject(obj: objc.id) void {
    if (obj != null) msgRelease(obj);
}

pub fn retainObject(obj: objc.id) objc.id {
    return msgRetain(obj);
}

fn installTrackingArea(view: objc.id) void {
    // Clear existing areas then add one covering the visible rect.
    const areas = msgId(view, sel("trackingAreas"));
    if (areas != null) {
        const count_fn: *const fn (objc.id, objc.SEL) callconv(.c) c_ulong = @ptrCast(&objc.objc_msgSend);
        const object_at: *const fn (objc.id, objc.SEL, c_ulong) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
        const remove: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
        const count = count_fn(areas, sel("count"));
        var i: c_ulong = count;
        while (i > 0) {
            i -= 1;
            const area = object_at(areas, sel("objectAtIndex:"), i);
            remove(view, sel("removeTrackingArea:"), area);
        }
    }

    const bounds = msgGetRect(view, sel("bounds"));
    const options: c_ulong = NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
        NSTrackingInVisibleRect | NSTrackingEnabledDuringMouseDrag;
    const area_class = objc.objc_getClass("NSTrackingArea") orelse return;
    const alloc = msgClassId(area_class, sel("alloc"));
    const init: *const fn (objc.id, objc.SEL, NSRect, c_ulong, objc.id, objc.id) callconv(.c) objc.id =
        @ptrCast(&objc.objc_msgSend);
    const area = init(alloc, sel("initWithRect:options:owner:userInfo:"), bounds, options, view, null);
    if (area == null) {
        msgRelease(alloc);
        return;
    }
    const add: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    add(view, sel("addTrackingArea:"), area);
    msgRelease(area);
}

// ---------------------------------------------------------------------------
// IMPs
// ---------------------------------------------------------------------------

fn impAcceptsFirstResponder(self: objc.id, _cmd: objc.SEL) callconv(.c) objc.BOOL {
    _ = self;
    _ = _cmd;
    return YES;
}

fn impIsOpaque(self: objc.id, _cmd: objc.SEL) callconv(.c) objc.BOOL {
    _ = self;
    _ = _cmd;
    return YES;
}

fn emitMouseButton(self: objc.id, event: objc.id, down: bool) void {
    const host = hostFrom(self) orelse return;
    const button = keys.mapMouseButton(msgGetLong(event, sel("buttonNumber"))) orelse return;
    const mods = keys.mapModifiers(msgGetULong(event, sel("modifierFlags")));
    const click_count: u32 = @intCast(@max(msgGetLong(event, sel("clickCount")), 1));
    const payload = platform_mod.MouseButtonEvent{
        .button = button,
        .position = mousePosition(self, event),
        .modifiers = mods,
        .click_count = click_count,
    };
    emitHost(host, .{ .input = if (down) .{ .mouse_down = payload } else .{ .mouse_up = payload } });
}

fn impMouseDown(self: objc.id, _cmd: objc.SEL, event: objc.id) callconv(.c) void {
    _ = _cmd;
    emitMouseButton(self, event, true);
}

fn impMouseUp(self: objc.id, _cmd: objc.SEL, event: objc.id) callconv(.c) void {
    _ = _cmd;
    emitMouseButton(self, event, false);
}

fn impRightMouseDown(self: objc.id, _cmd: objc.SEL, event: objc.id) callconv(.c) void {
    _ = _cmd;
    emitMouseButton(self, event, true);
}

fn impRightMouseUp(self: objc.id, _cmd: objc.SEL, event: objc.id) callconv(.c) void {
    _ = _cmd;
    emitMouseButton(self, event, false);
}

fn impOtherMouseDown(self: objc.id, _cmd: objc.SEL, event: objc.id) callconv(.c) void {
    _ = _cmd;
    emitMouseButton(self, event, true);
}

fn impOtherMouseUp(self: objc.id, _cmd: objc.SEL, event: objc.id) callconv(.c) void {
    _ = _cmd;
    emitMouseButton(self, event, false);
}

fn impMouseDragged(self: objc.id, _cmd: objc.SEL, event: objc.id) callconv(.c) void {
    _ = _cmd;
    const host = hostFrom(self) orelse return;
    const mods = keys.mapModifiers(msgGetULong(event, sel("modifierFlags")));
    emitHost(host, .{ .input = .{ .mouse_moved = .{
        .position = mousePosition(self, event),
        .modifiers = mods,
    } } });
}

fn impMouseMoved(self: objc.id, _cmd: objc.SEL, event: objc.id) callconv(.c) void {
    _ = _cmd;
    const host = hostFrom(self) orelse return;
    const mods = keys.mapModifiers(msgGetULong(event, sel("modifierFlags")));
    emitHost(host, .{ .input = .{ .mouse_moved = .{
        .position = mousePosition(self, event),
        .modifiers = mods,
    } } });
}

fn impMouseEntered(self: objc.id, _cmd: objc.SEL, event: objc.id) callconv(.c) void {
    _ = self;
    _ = _cmd;
    _ = event;
}

fn impMouseExited(self: objc.id, _cmd: objc.SEL, event: objc.id) callconv(.c) void {
    _ = _cmd;
    _ = event;
    const host = hostFrom(self) orelse return;
    emitHost(host, .{ .input = .mouse_exited });
}

fn impScrollWheel(self: objc.id, _cmd: objc.SEL, event: objc.id) callconv(.c) void {
    _ = _cmd;
    const host = hostFrom(self) orelse return;
    const mods = keys.mapModifiers(msgGetULong(event, sel("modifierFlags")));
    const precise = msgGetBool(event, sel("hasPreciseScrollingDeltas"));
    const dx = if (precise) msgGetF64(event, sel("scrollingDeltaX")) else msgGetF64(event, sel("deltaX"));
    const dy = if (precise) msgGetF64(event, sel("scrollingDeltaY")) else msgGetF64(event, sel("deltaY"));
    emitHost(host, .{ .input = .{ .scroll = .{
        .position = mousePosition(self, event),
        .delta = .{ .x = @floatCast(dx), .y = @floatCast(dy) },
        .unit = if (precise) .pixels else .lines,
        .modifiers = mods,
    } } });
}

fn utf8Slice(ns_str: objc.id) ?[]const u8 {
    if (ns_str == null) return null;
    const utf8_fn: *const fn (objc.id, objc.SEL) callconv(.c) [*c]const u8 = @ptrCast(&objc.objc_msgSend);
    const utf8 = utf8_fn(ns_str, sel("UTF8String"));
    if (utf8 == null) return null;
    return std.mem.span(utf8);
}

fn utf16OffsetToByteOffset(text: []const u8, utf16_offset: c_ulong) i32 {
    if (utf16_offset == 0) return 0;
    var utf16_seen: c_ulong = 0;
    var byte_i: usize = 0;
    while (byte_i < text.len) {
        const decoded = std.unicode.utf8Decode(text[byte_i..]) catch break;
        const cp_len = std.unicode.utf8CodepointSequenceLength(decoded) catch break;
        const utf16_len: c_ulong = if (decoded > 0xFFFF) 2 else 1;
        byte_i += cp_len;
        utf16_seen += utf16_len;
        if (utf16_seen >= utf16_offset) return @intCast(byte_i);
    }
    return @intCast(text.len);
}

fn shouldSuppressKeyDuringComposition(key: platform_mod.Key) bool {
    return switch (key) {
        .backspace, .delete, .enter, .escape,
        .left, .right, .up, .down, .home, .end,
        => true,
        else => false,
    };
}

fn emitKey(self: objc.id, event: objc.id, down: bool) void {
    const host = hostFrom(self) orelse return;
    const key = keys.mapKey(msgGetUShort(event, sel("keyCode")));
    const mods = keys.mapModifiers(msgGetULong(event, sel("modifierFlags")));
    if (down and host.is_composing(host.ctx) and
        !mods.control and !mods.command and !mods.alt and
        shouldSuppressKeyDuringComposition(key))
    {
        return;
    }
    const is_repeat = down and msgGetBool(event, sel("isARepeat"));
    const payload = platform_mod.KeyEvent{
        .key = key,
        .modifiers = mods,
        .is_repeat = is_repeat,
    };
    emitHost(host, .{ .input = if (down) .{ .key_down = payload } else .{ .key_up = payload } });
    // Committed text arrives via insertText:; emitting characters here duplicates ASCII.
}

fn impInsertText(self: objc.id, _cmd: objc.SEL, string: objc.id, replacement_range: NSRange) callconv(.c) void {
    _ = _cmd;
    _ = replacement_range;
    const host = hostFrom(self) orelse return;
    host.set_composing(host.ctx, false);
    if (utf8Slice(string)) |slice| {
        if (slice.len > 0) {
            emitHost(host, .{ .input = .{ .text_input = .{ .text = slice } } });
        }
    }
    emitHost(host, .{ .input = .composition_end });
}

fn impSetMarkedText(
    self: objc.id,
    _cmd: objc.SEL,
    string: objc.id,
    selected_range: NSRange,
    replacement_range: NSRange,
) callconv(.c) void {
    _ = _cmd;
    _ = replacement_range;
    const host = hostFrom(self) orelse return;
    const slice = utf8Slice(string) orelse "";
    host.set_composing(host.ctx, slice.len > 0);
    emitHost(host, .{ .input = .composition_start });
    const utf16_cursor = selected_range.location + selected_range.length;
    const cursor: i32 = if (slice.len == 0) -1 else utf16OffsetToByteOffset(slice, utf16_cursor);
    emitHost(host, .{ .input = .{ .composition_update = .{
        .text = slice,
        .cursor = cursor,
    } } });
}

fn impUnmarkText(self: objc.id, _cmd: objc.SEL) callconv(.c) void {
    _ = _cmd;
    const host = hostFrom(self) orelse return;
    host.set_composing(host.ctx, false);
    emitHost(host, .{ .input = .composition_end });
}

fn impHasMarkedText(self: objc.id, _cmd: objc.SEL) callconv(.c) objc.BOOL {
    _ = _cmd;
    const host = hostFrom(self) orelse return NO;
    return if (host.is_composing(host.ctx)) YES else NO;
}

fn impMarkedRange(self: objc.id, _cmd: objc.SEL) callconv(.c) NSRange {
    _ = self;
    _ = _cmd;
    return .{ .location = 0, .length = 0 };
}

fn impSelectedRange(self: objc.id, _cmd: objc.SEL) callconv(.c) NSRange {
    _ = self;
    _ = _cmd;
    return .{ .location = 0, .length = 0 };
}

const empty_rect: NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };

fn impFirstRectForCharacterRange(
    self: objc.id,
    _cmd: objc.SEL,
    char_range: NSRange,
    actual_range: ?*NSRange,
) callconv(.c) NSRect {
    _ = _cmd;
    if (actual_range) |out| out.* = char_range;

    const host = hostFrom(self) orelse return empty_rect;
    var caret_height: Pixels = 16;
    const anchor = host.ime_anchor(host.ctx, &caret_height) orelse return empty_rect;

    const bounds = msgGetRect(self, sel("bounds"));
    const height = @max(caret_height, 1);
    const local = NSRect{
        .origin = .{
            .x = anchor.x,
            .y = bounds.size.height - anchor.y - height,
        },
        .size = .{ .width = 1, .height = height },
    };

    const convert: *const fn (objc.id, objc.SEL, NSRect, objc.id) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
    const in_window = convert(self, sel("convertRect:toView:"), local, null);
    const window = msgId(self, sel("window"));
    if (window == null) return local;
    const to_screen: *const fn (objc.id, objc.SEL, NSRect) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
    return to_screen(window, sel("convertRectToScreen:"), in_window);
}

fn impKeyDown(self: objc.id, _cmd: objc.SEL, event: objc.id) callconv(.c) void {
    _ = _cmd;
    emitKey(self, event, true);
    const array_class = objc.objc_getClass("NSArray") orelse return;
    const with_object: *const fn (objc.Class, objc.SEL, objc.id) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    const array = with_object(array_class, sel("arrayWithObject:"), event);
    if (array == null) return;
    const interpret: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    interpret(self, sel("interpretKeyEvents:"), array);
}

fn impKeyUp(self: objc.id, _cmd: objc.SEL, event: objc.id) callconv(.c) void {
    _ = _cmd;
    emitKey(self, event, false);
}

fn impFlagsChanged(self: objc.id, _cmd: objc.SEL, event: objc.id) callconv(.c) void {
    _ = _cmd;
    const host = hostFrom(self) orelse return;
    const mods = keys.mapModifiers(msgGetULong(event, sel("modifierFlags")));
    emitHost(host, .{ .input = .{ .modifiers_changed = mods } });
}

fn impBackingChanged(self: objc.id, _cmd: objc.SEL) callconv(.c) void {
    _ = _cmd;
    const host = hostFrom(self) orelse return;
    // Backing scale may change without a logical size change (move between
    // displays); always refresh layer geometry and emit framebuffer/scale.
    const logical = logicalSizeOf(self);
    updateLayerGeometry(self);
    host.sync_layer(host.ctx);
    emitHost(host, .{ .resized = logical });
    emitHost(host, .{ .framebuffer_resized = framebufferSizeOf(self) });
    emitHost(host, .{ .scale_factor_changed = scaleOf(self) });
}

fn impSetFrameSize(self: objc.id, _cmd: objc.SEL, size: NSSize) callconv(.c) void {
    _ = _cmd;
    const old_logical = logicalSizeOf(self);
    const old_scale = scaleOf(self);

    const our_cls = objc.object_getClass(self);
    var super = objc.objc_super{
        .receiver = self,
        .super_class = objc.class_getSuperclass(our_cls),
    };
    const super_fn: *const fn (*objc.objc_super, objc.SEL, NSSize) callconv(.c) void =
        @ptrCast(&objc.objc_msgSendSuper);
    super_fn(&super, sel("setFrameSize:"), size);

    if (hostFrom(self)) |host| {
        emitResizeIfChanged(self, host, old_logical, old_scale);
    } else {
        updateLayerGeometry(self);
    }
}

fn impUpdateTrackingAreas(self: objc.id, _cmd: objc.SEL) callconv(.c) void {
    _ = _cmd;
    const our_cls = objc.object_getClass(self);
    var super = objc.objc_super{
        .receiver = self,
        .super_class = objc.class_getSuperclass(our_cls),
    };
    const super_fn: *const fn (*objc.objc_super, objc.SEL) callconv(.c) void =
        @ptrCast(&objc.objc_msgSendSuper);
    super_fn(&super, sel("updateTrackingAreas"));
    installTrackingArea(self);
}

fn impWindowShouldClose(self: objc.id, _cmd: objc.SEL, sender: objc.id) callconv(.c) objc.BOOL {
    _ = _cmd;
    _ = sender;
    const host = hostFrom(self) orelse return YES;
    // Emit then refuse AppKit's automatic close; AppKitWindow.deinit closes.
    host.request_close(host.ctx);
    return NO;
}

fn impWindowDidBecomeKey(self: objc.id, _cmd: objc.SEL, notification: objc.id) callconv(.c) void {
    _ = _cmd;
    _ = notification;
    const host = hostFrom(self) orelse return;
    emitHost(host, .{ .focus_changed = true });
}

fn impWindowDidResignKey(self: objc.id, _cmd: objc.SEL, notification: objc.id) callconv(.c) void {
    _ = _cmd;
    _ = notification;
    const host = hostFrom(self) orelse return;
    emitHost(host, .{ .focus_changed = false });
}

// Re-export for run-loop helpers in appkit.zig
pub const event_mask_any = NSEventMaskAny;
