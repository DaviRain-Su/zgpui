//! AppKit accessibility bridge.
//!
//! VoiceOver can today:
//! - Navigate a parent/child tree of controls (role, label, value, frame, enabled).
//! - See non-modal overlays alongside the main frame and modal-isolated trees.
//! - Follow keyboard focus (`accessibilityFocusedUIElement`, `accessibilityFocused`).
//! - Hit-test to the topmost control under the cursor (`accessibilityHitTest:`).
//! - Activate pressable buttons, toggles, radios, tabs, links, menu/list/tree
//!   items, including controls inside overlays.
//!
//! Also exposed today:
//! - Text fields/areas: value, selected text, selected range, character count,
//!   insertion-point line (single-line reports 0).
//! - Sliders: numeric min/max/value plus AXIncrement / AXDecrement.
//!
//! Remaining gaps (future work):
//! - Tab order / rotor customization; subroles and expanded/checked VO polish.
//! - Value changes, selection, and layout notifications beyond focus + layout.
//! - Typing / set-value through AX (VoiceOver dictation / AX UIElement setters).

const std = @import("std");
const objc = @import("objc_c");
const a11y = @import("../a11y.zig");
const element = @import("../element.zig");
const geometry = @import("../geometry.zig");

const log = std.log.scoped(.appkit_a11y);

pub const NSPoint = extern struct { x: f64, y: f64 };
pub const NSSize = extern struct { width: f64, height: f64 };
pub const NSRect = extern struct { origin: NSPoint, size: NSSize };

const YES: objc.BOOL = 1;
const NO: objc.BOOL = 0;

const store_ivar = "zgpuiA11yStore";
const proxy_index_ivar = "zgpuiAxIndex";
const parent_ivar = "zgpuiAxParentView";

const ax_element_class_name = "ZgpuiAxElement";

var ax_element_class: objc.Class = null;
var ax_classes_registered = false;

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

fn msgGetRect(obj: objc.id, s: objc.SEL) NSRect {
    const f: *const fn (objc.id, objc.SEL) callconv(.c) NSRect = @ptrCast(&objc.objc_msgSend);
    return f(obj, s);
}

fn msgRetain(obj: objc.id) objc.id {
    return msgId(obj, sel("retain"));
}

fn msgRelease(obj: objc.id) void {
    msgVoid(obj, sel("release"));
}

fn nsString(utf8: [:0]const u8) objc.id {
    const cls = objc.objc_getClass("NSString").?;
    const f: *const fn (objc.Class, objc.SEL, [*:0]const u8) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    return f(cls, sel("stringWithUTF8String:"), utf8.ptr);
}

fn nsNumberBool(v: bool) objc.id {
    const cls = objc.objc_getClass("NSNumber").?;
    const f: *const fn (objc.Class, objc.SEL, bool) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    return f(cls, sel("numberWithBool:"), v);
}

fn nsNumberDouble(v: f64) objc.id {
    const cls = objc.objc_getClass("NSNumber").?;
    const f: *const fn (objc.Class, objc.SEL, f64) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    return f(cls, sel("numberWithDouble:"), v);
}

const NSRange = extern struct {
    location: usize,
    length: usize,
};

/// AppKit text ranges index NSString UTF-16 code units; editor state keeps
/// UTF-8 byte offsets.
fn byteOffsetToUtf16(text: []const u8, byte_off: usize) usize {
    var i: usize = 0;
    var units: usize = 0;
    const limit = @min(byte_off, text.len);
    while (i < limit) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (i + n > limit or i + n > text.len) break;
        const codepoint = std.unicode.utf8Decode(text[i .. i + n]) catch {
            i += 1;
            units += 1;
            continue;
        };
        i += n;
        units += if (codepoint > 0xffff) 2 else 1;
    }
    return units;
}

fn utf16Length(text: []const u8) usize {
    return byteOffsetToUtf16(text, text.len);
}

fn emptyArray() objc.id {
    const empty = objc.objc_getClass("NSArray") orelse return null;
    return msgClassId(empty, sel("array"));
}

fn nsStringUtf8(obj: objc.id) ?[]const u8 {
    if (obj == null) return null;
    const f: *const fn (objc.id, objc.SEL) callconv(.c) [*:0]const u8 = @ptrCast(&objc.objc_msgSend);
    const ptr = f(obj, sel("UTF8String"));
    return std.mem.sliceTo(ptr, 0);
}

fn addMethod(cls: objc.Class, name: [:0]const u8, imp: objc.IMP, types: [:0]const u8) void {
    if (objc.class_addMethod(cls, sel(name), imp, types.ptr) == NO) {
        log.warn("class_addMethod failed for {s}", .{name});
    }
}

/// Map zgpui roles to NSAccessibilityRole string constants (AX*).
pub fn roleToNsRole(role: a11y.Role) ?[:0]const u8 {
    return switch (role) {
        .none => null,
        .button => "AXButton",
        .checkbox => "AXCheckBox",
        .switch_control => "AXSwitchButton",
        .radio => "AXRadioButton",
        .slider => "AXSlider",
        .tab => "AXRadioButton",
        .tab_list => "AXTabGroup",
        .dialog => "AXGroup",
        .menu => "AXMenu",
        .menu_item => "AXMenuItem",
        .textbox => "AXTextField",
        .textarea => "AXTextArea",
        .search => "AXTextField",
        .link => "AXLink",
        .list => "AXList",
        .list_item => "AXRow",
        .tree => "AXOutline",
        .tree_item => "AXRow",
        .progressbar => "AXProgressIndicator",
        .separator => "AXSeparator",
        .img => "AXImage",
        .heading => "AXHeading",
        .label => "AXStaticText",
        .tooltip => "AXHelpTag",
        .generic => "AXGroup",
    };
}

/// Convert zgpui top-left bounds to AppKit bottom-left view coordinates.
pub fn boundsToAppKitFrame(bounds: geometry.Bounds(geometry.Pixels), view_height: f64) NSRect {
    return .{
        .origin = .{
            .x = @floatCast(bounds.origin.x),
            .y = view_height - @as(f64, @floatCast(bounds.origin.y)) - @as(f64, @floatCast(bounds.size.height)),
        },
        .size = .{
            .width = @floatCast(bounds.size.width),
            .height = @floatCast(bounds.size.height),
        },
    };
}

pub fn roleSupportsPress(role: a11y.Role) bool {
    return switch (role) {
        .button,
        .checkbox,
        .switch_control,
        .radio,
        .tab,
        .link,
        .menu_item,
        .list_item,
        .tree_item,
        => true,
        else => false,
    };
}

pub fn nodeSupportsPress(node: *const StoredNode) bool {
    return node.pressable and !node.disabled and roleSupportsPress(node.role);
}

pub fn nodeSupportsAdjust(node: *const StoredNode) bool {
    return node.adjustable and !node.disabled and a11y.roleSupportsAdjust(node.role);
}

pub fn booleanValue(node: *const StoredNode) ?bool {
    if (node.checked) |checked| return checked;
    return node.selected;
}

pub fn pointInFrame(point: NSPoint, frame: NSRect) bool {
    return point.x >= frame.origin.x and point.x < frame.origin.x + frame.size.width and
        point.y >= frame.origin.y and point.y < frame.origin.y + frame.size.height;
}

/// Topmost node (last in paint order) whose frame contains `point`.
pub fn hitTestIndex(nodes: []const StoredNode, point: NSPoint) ?usize {
    var found: ?usize = null;
    for (nodes, 0..) |*node, i| {
        if (pointInFrame(point, node.frame)) found = i;
    }
    return found;
}

pub fn indexOfId(nodes: []const StoredNode, id: element.ElementId) ?usize {
    for (nodes, 0..) |*node, i| {
        if (node.id == id) return i;
    }
    return null;
}

pub const StoredNode = struct {
    id: element.ElementId,
    role: a11y.Role,
    ns_role: [:0]const u8,
    title: ?[]u8 = null,
    value_text: ?[]u8 = null,
    checked: ?bool = null,
    selected: ?bool = null,
    disabled: bool = false,
    expanded: ?bool = null,
    pressable: bool = false,
    adjustable: bool = false,
    caret: ?usize = null,
    selection_start: ?usize = null,
    selection_end: ?usize = null,
    numeric_value: ?f64 = null,
    min_value: ?f64 = null,
    max_value: ?f64 = null,
    parent_id: ?element.ElementId = null,
    frame: NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } },
    /// Retained AX proxy object, owned by the store until cleared.
    proxy: objc.id = null,
};

/// Per-view snapshot of the latest frame's accessibility nodes.
pub const Store = struct {
    pub const PressBridge = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, id: element.ElementId) void,
    };

    pub const AdjustBridge = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, id: element.ElementId, increment: bool) void,
    };

    allocator: std.mem.Allocator,
    nodes: std.ArrayList(StoredNode),
    view_height: f64 = 0,
    /// Keyboard focus from `InputState.focused`, updated each sync.
    focused_id: ?element.ElementId = null,
    focused_index: ?usize = null,
    press_bridge: ?PressBridge = null,
    adjust_bridge: ?AdjustBridge = null,
    /// Retained NSArray built for `accessibilityChildren`; released on next sync.
    children_array: objc.id = null,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .nodes = .empty,
        };
    }

    pub fn deinit(self: *Store) void {
        self.clear();
        self.nodes.deinit(self.allocator);
    }

    pub fn clear(self: *Store) void {
        for (self.nodes.items) |*node| {
            if (node.title) |title| self.allocator.free(title);
            if (node.value_text) |value| self.allocator.free(value);
            if (node.proxy != null) msgRelease(node.proxy);
        }
        self.nodes.clearRetainingCapacity();
        if (self.children_array != null) {
            msgRelease(self.children_array);
            self.children_array = null;
        }
    }

    /// Copy frame nodes into owned storage (no Objective-C objects).
    pub fn syncFromNodes(
        self: *Store,
        nodes: []const a11y.Node,
        view_height: f64,
        focused_id: ?element.ElementId,
    ) !void {
        self.clear();
        self.view_height = view_height;
        self.focused_id = focused_id;

        for (nodes) |node| {
            const ns_role = roleToNsRole(node.role) orelse continue;

            var stored: StoredNode = .{
                .id = node.id,
                .role = node.role,
                .ns_role = ns_role,
                .disabled = node.disabled,
                .checked = node.checked,
                .selected = node.selected,
                .expanded = node.expanded,
                .pressable = node.pressable,
                .adjustable = node.adjustable,
                .caret = node.caret,
                .selection_start = node.selection_start,
                .selection_end = node.selection_end,
                .numeric_value = node.numeric_value,
                .min_value = node.min_value,
                .max_value = node.max_value,
                .parent_id = node.parent_id,
                .frame = boundsToAppKitFrame(node.bounds, view_height),
            };

            if (a11y.resolveNameIn(nodes, &node)) |label| {
                stored.title = try self.allocator.dupe(u8, label);
            }
            if (node.value_text) |value| {
                stored.value_text = try self.allocator.dupe(u8, value);
            }

            try self.nodes.append(self.allocator, stored);
        }

        self.focused_index = if (focused_id) |fid| indexOfId(self.nodes.items, fid) else null;
    }
};

fn storeFromView(view: objc.id) ?*Store {
    var value: ?*anyopaque = null;
    _ = objc.object_getInstanceVariable(view, store_ivar, &value);
    if (value == null) return null;
    return @ptrCast(@alignCast(value));
}

fn parentViewFromProxy(proxy: objc.id) ?objc.id {
    var value: ?*anyopaque = null;
    _ = objc.object_getInstanceVariable(proxy, parent_ivar, &value);
    if (value == null) return null;
    return @ptrCast(@alignCast(value));
}

fn storeFromProxy(proxy: objc.id) ?*Store {
    const parent = parentViewFromProxy(proxy) orelse return null;
    return storeFromView(parent);
}

fn proxyIndex(proxy: objc.id) usize {
    var value: ?*anyopaque = null;
    _ = objc.object_getInstanceVariable(proxy, proxy_index_ivar, &value);
    if (value == null) return std.math.maxInt(usize);
    return @intFromPtr(value);
}

fn setProxyIndex(proxy: objc.id, index: usize) void {
    _ = objc.object_setInstanceVariable(proxy, proxy_index_ivar, @ptrFromInt(index));
}

fn storedNodeFromProxy(proxy: objc.id) ?*StoredNode {
    const store = storeFromProxy(proxy) orelse return null;
    const index = proxyIndex(proxy);
    if (index >= store.nodes.items.len) return null;
    return &store.nodes.items[index];
}

fn rebuildProxies(view: objc.id, store: *Store) void {
    if (!ax_classes_registered) return;

    for (store.nodes.items, 0..) |*node, i| {
        const alloc = msgClassId(ax_element_class, sel("alloc"));
        if (alloc == null) continue;
        const proxy = msgId(alloc, sel("init"));
        if (proxy == null) {
            msgRelease(alloc);
            continue;
        }
        setProxyIndex(proxy, i);
        setProxyParent(proxy, view);
        node.proxy = msgRetain(proxy);
        msgRelease(proxy);
    }

    const array_class = objc.objc_getClass("NSMutableArray") orelse return;
    const array = msgClassId(array_class, sel("array"));
    if (array == null) return;

    for (store.nodes.items) |*node| {
        // View children = roots only; nested nodes hang off parent proxies.
        if (node.parent_id != null) continue;
        if (node.proxy) |proxy| {
            const add: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
            add(array, sel("addObject:"), proxy);
        }
    }

    store.children_array = msgRetain(array);
}

fn postNotification(element_obj: objc.id, name: [:0]const u8) void {
    const post: *const fn (objc.id, [*c]const u8) callconv(.c) void = @extern(
        *const fn (objc.id, [*c]const u8) callconv(.c) void,
        .{ .name = "NSAccessibilityPostNotification" },
    );
    post(element_obj, name);
}

fn postLayoutChanged(view: objc.id) void {
    postNotification(view, "AXLayoutChanged");
}

fn postFocusedChanged(element_obj: objc.id) void {
    postNotification(element_obj, "AXFocusedUIElementChanged");
}

/// Attach the store ivar on `view` and rebuild AX proxy objects from `nodes`.
pub fn syncAccessibilityTree(
    view: objc.id,
    store: *Store,
    nodes: []const a11y.Node,
    scale: f32,
    focused_id: ?element.ElementId,
) void {
    _ = scale;
    const prev_focused = store.focused_id;
    const bounds = msgGetRect(view, sel("bounds"));
    store.syncFromNodes(nodes, bounds.size.height, focused_id) catch |err| {
        log.warn("syncFromNodes failed: {}", .{err});
        return;
    };

    rebuildProxies(view, store);

    log.debug("a11y sync: {d} nodes (view height {d}, focused {})", .{
        store.nodes.items.len,
        bounds.size.height,
        focused_id != null,
    });

    postLayoutChanged(view);

    if (!idEql(prev_focused, store.focused_id)) {
        if (store.focused_index) |idx| {
            if (store.nodes.items[idx].proxy) |proxy| postFocusedChanged(proxy);
        } else if (prev_focused != null) {
            postFocusedChanged(view);
        }
    }
}

pub fn attachStore(
    view: objc.id,
    store: *Store,
    press_bridge: Store.PressBridge,
    adjust_bridge: Store.AdjustBridge,
) void {
    store.press_bridge = press_bridge;
    store.adjust_bridge = adjust_bridge;
    _ = objc.object_setInstanceVariable(view, store_ivar, store);
}

pub fn registerViewAccessibilityIvar(view_class: objc.Class) void {
    if (objc.class_addIvar(
        view_class,
        store_ivar,
        @sizeOf(*anyopaque),
        std.math.log2_int(u16, @alignOf(*anyopaque)),
        "^",
    ) == NO) {
        log.warn("failed to add {s} ivar", .{store_ivar});
    }
}

fn ensureAxElementClass() void {
    if (ax_classes_registered) return;

    const ns_object = objc.objc_getClass("NSObject") orelse return;
    ax_element_class = objc.objc_allocateClassPair(ns_object, ax_element_class_name, 0) orelse return;

    if (objc.class_addIvar(
        ax_element_class,
        proxy_index_ivar,
        @sizeOf(*anyopaque),
        std.math.log2_int(u16, @alignOf(*anyopaque)),
        "Q",
    ) == NO) return;
    if (objc.class_addIvar(
        ax_element_class,
        parent_ivar,
        @sizeOf(*anyopaque),
        std.math.log2_int(u16, @alignOf(*anyopaque)),
        "@",
    ) == NO) return;

    addMethod(ax_element_class, "isAccessibilityElement", @ptrCast(&impAxIsElement), "c@:");
    addMethod(ax_element_class, "accessibilityRole", @ptrCast(&impAxRole), "@@:");
    addMethod(ax_element_class, "accessibilityLabel", @ptrCast(&impAxLabel), "@@:");
    addMethod(ax_element_class, "accessibilityValue", @ptrCast(&impAxValue), "@@:");
    addMethod(ax_element_class, "accessibilityFrame", @ptrCast(&impAxFrame), "{CGRect={CGPoint=dd}{CGSize=dd}}@:");
    addMethod(ax_element_class, "accessibilityParent", @ptrCast(&impAxParent), "@@:");
    addMethod(ax_element_class, "accessibilityChildren", @ptrCast(&impAxChildren), "@@:");
    addMethod(ax_element_class, "isEnabled", @ptrCast(&impAxEnabled), "c@:");
    addMethod(ax_element_class, "accessibilityFocused", @ptrCast(&impAxFocused), "c@:");
    addMethod(ax_element_class, "accessibilityActionNames", @ptrCast(&impAxActionNames), "@@:");
    addMethod(ax_element_class, "accessibilityPerformAction:", @ptrCast(&impAxPerformAction), "v@:@");
    addMethod(ax_element_class, "accessibilityPerformPress", @ptrCast(&impAxPerformPress), "c@:");
    addMethod(ax_element_class, "accessibilityPerformIncrement", @ptrCast(&impAxPerformIncrement), "c@:");
    addMethod(ax_element_class, "accessibilityPerformDecrement", @ptrCast(&impAxPerformDecrement), "c@:");
    addMethod(ax_element_class, "accessibilitySelectedText", @ptrCast(&impAxSelectedText), "@@:");
    addMethod(ax_element_class, "accessibilitySelectedTextRange", @ptrCast(&impAxSelectedTextRange), "{_NSRange=QQ}@:");
    addMethod(ax_element_class, "accessibilityNumberOfCharacters", @ptrCast(&impAxNumberOfCharacters), "q@:");
    addMethod(ax_element_class, "accessibilityInsertionPointLineNumber", @ptrCast(&impAxInsertionPointLine), "q@:");
    addMethod(ax_element_class, "accessibilityMinValue", @ptrCast(&impAxMinValue), "@@:");
    addMethod(ax_element_class, "accessibilityMaxValue", @ptrCast(&impAxMaxValue), "@@:");

    objc.objc_registerClassPair(ax_element_class);
    ax_classes_registered = true;
}

pub fn registerViewAccessibilityMethods(view_class: objc.Class) void {
    ensureAxElementClass();

    addMethod(view_class, "isAccessibilityElement", @ptrCast(&impViewIsAccessibilityElement), "c@:");
    addMethod(view_class, "accessibilityRole", @ptrCast(&impViewAccessibilityRole), "@@:");
    addMethod(view_class, "accessibilityChildren", @ptrCast(&impViewAccessibilityChildren), "@@:");
    addMethod(view_class, "accessibilityFocusedUIElement", @ptrCast(&impViewAccessibilityFocusedUIElement), "@@:");
    addMethod(view_class, "accessibilityHitTest:", @ptrCast(&impViewAccessibilityHitTest), "@:{CGPoint=dd}");
}

// ---------------------------------------------------------------------------
// View AX IMPs — container exposing root proxies
// ---------------------------------------------------------------------------

fn impViewIsAccessibilityElement(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.BOOL {
    _ = _self;
    _ = _cmd;
    return NO;
}

fn impViewAccessibilityRole(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _self;
    _ = _cmd;
    return nsString("AXGroup");
}

fn impViewAccessibilityChildren(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const store = storeFromView(_self) orelse return emptyArray();
    if (store.children_array != null) return store.children_array;
    return emptyArray();
}

fn impViewAccessibilityFocusedUIElement(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const store = storeFromView(_self) orelse return null;
    if (store.focused_index) |idx| return store.nodes.items[idx].proxy;
    return null;
}

fn impViewAccessibilityHitTest(_self: objc.id, _cmd: objc.SEL, point: NSPoint) callconv(.c) objc.id {
    _ = _cmd;
    const store = storeFromView(_self) orelse return null;
    const convert: *const fn (objc.id, objc.SEL, NSPoint, objc.id) callconv(.c) NSPoint =
        @ptrCast(&objc.objc_msgSend);
    const local = convert(_self, sel("convertPoint:fromView:"), point, null);
    if (hitTestIndex(store.nodes.items, local)) |idx| return store.nodes.items[idx].proxy;
    return null;
}

// ---------------------------------------------------------------------------
// Node proxy AX IMPs
// ---------------------------------------------------------------------------

fn impAxIsElement(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.BOOL {
    _ = _self;
    _ = _cmd;
    return YES;
}

fn impAxRole(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return nsString("AXGroup");
    return nsString(node.ns_role);
}

fn impAxLabel(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return null;
    if (node.title) |title| {
        const z = std.heap.c_allocator.dupeZ(u8, title) catch return null;
        defer std.heap.c_allocator.free(z);
        return nsString(z);
    }
    return null;
}

fn impAxFrame(_self: objc.id, _cmd: objc.SEL) callconv(.c) NSRect {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 0, .height = 0 },
    };
    const parent = parentViewFromProxy(_self) orelse return node.frame;

    const convert: *const fn (objc.id, objc.SEL, NSRect, objc.id) callconv(.c) NSRect =
        @ptrCast(&objc.objc_msgSend);
    const in_window = convert(parent, sel("convertRect:toView:"), node.frame, null);
    const window = msgId(parent, sel("window"));
    if (window == null) return in_window;
    return convert(window, sel("convertRect:toView:"), in_window, null);
}

fn impAxParent(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return parentViewFromProxy(_self) orelse null;
    const store = storeFromProxy(_self) orelse return parentViewFromProxy(_self) orelse null;
    if (node.parent_id) |pid| {
        if (indexOfId(store.nodes.items, pid)) |idx| {
            return store.nodes.items[idx].proxy;
        }
    }
    return parentViewFromProxy(_self) orelse null;
}

fn impAxChildren(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return emptyArray();
    const store = storeFromProxy(_self) orelse return emptyArray();

    const array_class = objc.objc_getClass("NSMutableArray") orelse return emptyArray();
    const array = msgClassId(array_class, sel("array"));
    if (array == null) return emptyArray();
    const add: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    for (store.nodes.items) |*child| {
        if (child.parent_id) |pid| {
            if (pid == node.id) {
                if (child.proxy) |proxy| add(array, sel("addObject:"), proxy);
            }
        }
    }
    return array;
}

fn impAxEnabled(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.BOOL {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return YES;
    return if (node.disabled) NO else YES;
}

fn impAxFocused(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.BOOL {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return NO;
    const store = storeFromProxy(_self) orelse return NO;
    if (store.focused_id) |fid| return if (node.id == fid) YES else NO;
    return NO;
}

fn impAxActionNames(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return emptyArray();

    const array_class = objc.objc_getClass("NSMutableArray") orelse return emptyArray();
    const array = msgClassId(array_class, sel("array"));
    if (array == null) return emptyArray();
    const add: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);

    if (nodeSupportsPress(node)) {
        add(array, sel("addObject:"), nsString("AXPress"));
    }
    if (nodeSupportsAdjust(node)) {
        add(array, sel("addObject:"), nsString("AXIncrement"));
        add(array, sel("addObject:"), nsString("AXDecrement"));
    }
    return array;
}

fn performAxPress(_self: objc.id) bool {
    const node = storedNodeFromProxy(_self) orelse return false;
    if (!nodeSupportsPress(node)) return false;
    const store = storeFromProxy(_self) orelse return false;
    if (store.press_bridge) |bridge| {
        bridge.func(bridge.ctx, node.id);
        return true;
    }
    return false;
}

fn performAxAdjust(_self: objc.id, increment: bool) bool {
    const node = storedNodeFromProxy(_self) orelse return false;
    if (!nodeSupportsAdjust(node)) return false;
    const store = storeFromProxy(_self) orelse return false;
    if (store.adjust_bridge) |bridge| {
        bridge.func(bridge.ctx, node.id, increment);
        return true;
    }
    return false;
}

fn impAxPerformAction(_self: objc.id, _cmd: objc.SEL, action: objc.id) callconv(.c) void {
    _ = _cmd;
    const name = nsStringUtf8(action) orelse return;
    if (std.mem.eql(u8, name, "AXPress")) {
        _ = performAxPress(_self);
    } else if (std.mem.eql(u8, name, "AXIncrement")) {
        _ = performAxAdjust(_self, true);
    } else if (std.mem.eql(u8, name, "AXDecrement")) {
        _ = performAxAdjust(_self, false);
    }
}

fn impAxPerformPress(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.BOOL {
    _ = _cmd;
    return if (performAxPress(_self)) YES else NO;
}

fn impAxPerformIncrement(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.BOOL {
    _ = _cmd;
    return if (performAxAdjust(_self, true)) YES else NO;
}

fn impAxPerformDecrement(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.BOOL {
    _ = _cmd;
    return if (performAxAdjust(_self, false)) YES else NO;
}

fn impAxSelectedText(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return null;
    if (!a11y.roleIsText(node.role)) return null;
    const value = node.value_text orelse return nsString("");
    const start = node.selection_start orelse return nsString("");
    const end = node.selection_end orelse return nsString("");
    if (end <= start or end > value.len or start > value.len) return nsString("");
    const slice = value[start..end];
    const z = std.heap.c_allocator.dupeZ(u8, slice) catch return null;
    defer std.heap.c_allocator.free(z);
    return nsString(z);
}

fn impAxSelectedTextRange(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return null;
    if (!a11y.roleIsText(node.role)) return null;
    const value = node.value_text orelse return nsValueRange(.{ .location = 0, .length = 0 });
    const start_b = node.selection_start orelse node.caret orelse 0;
    const end_b = node.selection_end orelse start_b;
    const start_cp = byteOffsetToCodepoint(value, start_b);
    const end_cp = byteOffsetToCodepoint(value, end_b);
    return nsValueRange(.{
        .location = start_cp,
        .length = if (end_cp >= start_cp) end_cp - start_cp else 0,
    });
}

fn impAxNumberOfCharacters(_self: objc.id, _cmd: objc.SEL) callconv(.c) usize {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return 0;
    if (!a11y.roleIsText(node.role)) return 0;
    const value = node.value_text orelse return 0;
    return codepointCount(value);
}

fn impAxInsertionPointLine(_self: objc.id, _cmd: objc.SEL) callconv(.c) i64 {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return 0;
    if (!a11y.roleIsText(node.role)) return 0;
    // Single-line text fields report line 0; multi-line uses caret byte scan.
    if (node.role != .textarea) return 0;
    const value = node.value_text orelse return 0;
    const caret = node.caret orelse return 0;
    var line: i64 = 0;
    var i: usize = 0;
    while (i < caret and i < value.len) : (i += 1) {
        if (value[i] == '\n') line += 1;
    }
    return line;
}

fn impAxMinValue(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return null;
    if (node.min_value) |v| return nsNumberDouble(v);
    return null;
}

fn impAxMaxValue(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return null;
    if (node.max_value) |v| return nsNumberDouble(v);
    return null;
}

fn impAxValue(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return null;
    if (node.numeric_value) |v| return nsNumberDouble(v);
    if (node.value_text) |value| {
        const z = std.heap.c_allocator.dupeZ(u8, value) catch return null;
        defer std.heap.c_allocator.free(z);
        return nsString(z);
    }
    if (booleanValue(node)) |value| return nsNumberBool(value);
    return null;
}

fn setProxyParent(proxy: objc.id, view: objc.id) void {
    _ = objc.object_setInstanceVariable(proxy, parent_ivar, view);
}

fn idEql(a: ?element.ElementId, b: ?element.ElementId) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

test "roleToNsRole maps common controls" {
    try std.testing.expectEqualStrings("AXButton", roleToNsRole(.button).?);
    try std.testing.expectEqualStrings("AXCheckBox", roleToNsRole(.checkbox).?);
    try std.testing.expectEqualStrings("AXSwitchButton", roleToNsRole(.switch_control).?);
    try std.testing.expectEqualStrings("AXRadioButton", roleToNsRole(.radio).?);
    try std.testing.expectEqualStrings("AXSlider", roleToNsRole(.slider).?);
    try std.testing.expectEqualStrings("AXTextField", roleToNsRole(.textbox).?);
    try std.testing.expectEqualStrings("AXTextArea", roleToNsRole(.textarea).?);
    try std.testing.expectEqualStrings("AXStaticText", roleToNsRole(.label).?);
    try std.testing.expect(roleToNsRole(.none) == null);
}

test "boundsToAppKitFrame flips Y" {
    const frame = boundsToAppKitFrame(.{
        .origin = .{ .x = 10, .y = 20 },
        .size = .{ .width = 100, .height = 30 },
    }, 600);
    try std.testing.expectApproxEqAbs(@as(f64, 10), frame.origin.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 550), frame.origin.y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 100), frame.size.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 30), frame.size.height, 0.001);
}

test "Store syncFromNodes copies labeled nodes" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const id = element.elementId("save");
    const nodes = [_]a11y.Node{
        .{ .id = id, .role = .button, .name = .{ .label = "Save" }, .bounds = .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 80, .height = 32 },
        } },
        .{ .id = element.elementId("skip"), .role = .none },
    };

    try store.syncFromNodes(&nodes, 480, id);
    try std.testing.expectEqual(@as(usize, 1), store.nodes.items.len);
    try std.testing.expectEqual(.button, store.nodes.items[0].role);
    try std.testing.expectEqualStrings("Save", store.nodes.items[0].title.?);
    try std.testing.expectEqual(@as(?usize, 0), store.focused_index);
    try std.testing.expectEqual(id, store.focused_id.?);
}

test "Store syncFromNodes resolves inverse labels" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const field_id = element.elementId("notes");
    const nodes = [_]a11y.Node{
        .{ .id = field_id, .role = .textarea },
        .{ .id = element.elementId("notes-label"), .role = .label, .name = .{ .label = "Notes" }, .label_for = field_id },
    };

    try store.syncFromNodes(&nodes, 480, null);
    try std.testing.expectEqualStrings("Notes", store.nodes.items[0].title.?);
}

test "hitTestIndex picks topmost node" {
    const nodes = [_]StoredNode{
        .{ .id = element.elementId("back"), .role = .generic, .ns_role = "AXGroup", .frame = .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 200, .height = 200 },
        } },
        .{ .id = element.elementId("front"), .role = .button, .ns_role = "AXButton", .frame = .{
            .origin = .{ .x = 50, .y = 50 },
            .size = .{ .width = 80, .height = 40 },
        } },
    };

    const inside_front = hitTestIndex(&nodes, .{ .x = 60, .y = 60 }).?;
    try std.testing.expectEqual(@as(usize, 1), inside_front);

    const inside_back_only = hitTestIndex(&nodes, .{ .x = 10, .y = 10 }).?;
    try std.testing.expectEqual(@as(usize, 0), inside_back_only);

    try std.testing.expect(hitTestIndex(&nodes, .{ .x = 300, .y = 300 }) == null);
}

test "roleSupportsPress covers actionable roles" {
    try std.testing.expect(roleSupportsPress(.button));
    try std.testing.expect(roleSupportsPress(.checkbox));
    try std.testing.expect(roleSupportsPress(.switch_control));
    try std.testing.expect(roleSupportsPress(.radio));
    try std.testing.expect(roleSupportsPress(.tab));
    try std.testing.expect(roleSupportsPress(.link));
    try std.testing.expect(roleSupportsPress(.menu_item));
    try std.testing.expect(roleSupportsPress(.list_item));
    try std.testing.expect(roleSupportsPress(.tree_item));
    try std.testing.expect(!roleSupportsPress(.label));
}

test "nodeSupportsPress requires an enabled explicit press action" {
    var node = StoredNode{
        .id = element.elementId("action"),
        .role = .button,
        .ns_role = "AXButton",
        .pressable = true,
    };
    try std.testing.expect(nodeSupportsPress(&node));

    node.disabled = true;
    try std.testing.expect(!nodeSupportsPress(&node));
    node.disabled = false;
    node.pressable = false;
    try std.testing.expect(!nodeSupportsPress(&node));
}

test "nodeSupportsAdjust requires an enabled adjustable slider" {
    var node = StoredNode{
        .id = element.elementId("volume"),
        .role = .slider,
        .ns_role = "AXSlider",
        .adjustable = true,
    };
    try std.testing.expect(nodeSupportsAdjust(&node));

    node.disabled = true;
    try std.testing.expect(!nodeSupportsAdjust(&node));
    node.disabled = false;
    node.adjustable = false;
    try std.testing.expect(!nodeSupportsAdjust(&node));
    node.adjustable = true;
    node.role = .progressbar;
    try std.testing.expect(!nodeSupportsAdjust(&node));
}

test "booleanValue falls back from checked to selected" {
    var node = StoredNode{
        .id = element.elementId("state"),
        .role = .tab,
        .ns_role = "AXRadioButton",
        .selected = true,
    };
    try std.testing.expect(booleanValue(&node).?);
    node.checked = false;
    try std.testing.expect(!booleanValue(&node).?);
}
