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
//!   insertion-point line (single-line reports 0), plus setAccessibilityValue:,
//!   setAccessibilitySelectedText:, and setAccessibilitySelectedTextRange:.
//! - Sliders: numeric min/max/value plus AXIncrement / AXDecrement.
//! - Selected/expanded state plus switch/search/dialog/tab/outline subroles.
//! - Busy / required / invalid validation state (`AXInvalid` + status changed).
//! - Modal dialog surfaces via `isAccessibilityModal`.
//! - Menu / popover triggers expose expanded state; AXShowMenu maps to press.
//! - Placeholder and value-description strings for text fields and sliders.
//! - Orientation for sliders / tab lists (`accessibilityOrientation`).
//! - Link destinations via `accessibilityURL`.
//! - Stable element ids via `accessibilityIdentifier`.
//! - Value / selected-text / selected-child / row-expanded / focus / layout
//!   notifications when the snapshot changes between syncs.
//! - Declarative polite/assertive live-region announcements.
//! - Semantic custom rotors for headings, links, images, lists, and text input.
//! - Author-defined custom rotor groups (`rotor_group`) and sibling/tab
//!   `nav_order` overrides for accessibility children and keyboard focus.

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
var rotor_item_id_key: u8 = 0;
const max_author_rotor_groups: usize = 32;
/// NSAccessibilityCustomRotorTypeCustom
const appkit_rotor_type_custom: isize = 0;

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

fn msgIdArg(obj: objc.id, s: objc.SEL, arg: objc.id) objc.id {
    const f: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    return f(obj, s, arg);
}

fn msgGetInteger(obj: objc.id, s: objc.SEL) isize {
    const f: *const fn (objc.id, objc.SEL) callconv(.c) isize = @ptrCast(&objc.objc_msgSend);
    return f(obj, s);
}

fn msgGetU64(obj: objc.id, s: objc.SEL) u64 {
    const f: *const fn (objc.id, objc.SEL) callconv(.c) u64 = @ptrCast(&objc.objc_msgSend);
    return f(obj, s);
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

fn nsNumberInteger(v: isize) objc.id {
    const cls = objc.objc_getClass("NSNumber").?;
    const f: *const fn (objc.Class, objc.SEL, isize) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    return f(cls, sel("numberWithInteger:"), v);
}

fn nsNumberU64(v: u64) objc.id {
    const cls = objc.objc_getClass("NSNumber").?;
    const f: *const fn (objc.Class, objc.SEL, u64) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    return f(cls, sel("numberWithUnsignedLongLong:"), v);
}

fn nsUrl(utf8: [:0]const u8) objc.id {
    const cls = objc.objc_getClass("NSURL").?;
    const f: *const fn (objc.Class, objc.SEL, objc.id) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    return f(cls, sel("URLWithString:"), nsString(utf8));
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

fn utf16OffsetToByte(text: []const u8, utf16_off: usize) ?usize {
    if (utf16_off == 0) return 0;

    var i: usize = 0;
    var units: usize = 0;
    while (i < text.len) {
        const candidate_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        var byte_width: usize = 1;
        var utf16_width: usize = 1;
        if (i + candidate_len <= text.len) {
            if (std.unicode.utf8Decode(text[i .. i + candidate_len])) |codepoint| {
                byte_width = candidate_len;
                utf16_width = if (codepoint > 0xffff) 2 else 1;
            } else |_| {}
        }

        const next_units = std.math.add(usize, units, utf16_width) catch return null;
        if (utf16_off < next_units) return null;
        i += byte_width;
        units = next_units;
        if (utf16_off == units) return i;
    }
    return null;
}

const ByteRange = struct { start: usize, end: usize };

fn utf16RangeToByte(text: []const u8, range: NSRange) ?ByteRange {
    const end_utf16 = std.math.add(usize, range.location, range.length) catch return null;
    const start = utf16OffsetToByte(text, range.location) orelse return null;
    const end = utf16OffsetToByte(text, end_utf16) orelse return null;
    return .{ .start = start, .end = end };
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
        .switch_control => "AXButton",
        .radio => "AXRadioButton",
        .radio_group => "AXRadioGroup",
        .slider => "AXSlider",
        .tab => "AXRadioButton",
        .tab_list => "AXTabGroup",
        .dialog => "AXGroup",
        .menu => "AXMenu",
        .menu_bar => "AXMenuBar",
        .menu_item => "AXMenuItem",
        .textbox => "AXTextField",
        .textarea => "AXTextArea",
        .search => "AXTextField",
        .link => "AXLink",
        .list => "AXList",
        .list_item => "AXRow",
        .table => "AXTable",
        .cell => "AXCell",
        .group => "AXGroup",
        .pop_up_button => "AXPopUpButton",
        .combobox => "AXComboBox",
        .tree => "AXOutline",
        .tree_item => "AXRow",
        .progressbar => "AXProgressIndicator",
        .separator => "AXSeparator",
        .scrollbar => "AXScrollBar",
        .toolbar => "AXToolbar",
        .splitter => "AXSplitter",
        .sheet => "AXSheet",
        .alert => "AXGroup",
        .status => "AXGroup",
        .img => "AXImage",
        .heading => "AXHeading",
        .label => "AXStaticText",
        .tooltip => "AXHelpTag",
        .generic => "AXGroup",
    };
}

/// AppKit semantic variants layered on top of the primary role.
pub fn roleToNsSubrole(role: a11y.Role) ?[:0]const u8 {
    return switch (role) {
        .switch_control => "AXSwitch",
        .search => "AXSearchField",
        .dialog => "AXDialog",
        .tab => "AXTabButton",
        .tree_item => "AXOutlineRow",
        else => null,
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
        .pop_up_button,
        .combobox,
        => true,
        else => false,
    };
}

pub fn nodeSupportsPress(node: *const StoredNode) bool {
    return node.pressable and !node.disabled and roleSupportsPress(node.role);
}

/// Triggers that expose `expanded` can open/close via AXShowMenu (maps to press).
pub fn nodeSupportsShowMenu(node: *const StoredNode) bool {
    return node.expanded != null and nodeSupportsPress(node);
}

pub fn nodeSupportsAdjust(node: *const StoredNode) bool {
    return node.adjustable and !node.disabled and a11y.roleSupportsAdjust(node.role);
}

pub fn nodeSupportsSetValue(node: *const StoredNode) bool {
    return node.editable and !node.disabled and a11y.roleIsText(node.role);
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
    busy: bool = false,
    required: bool = false,
    invalid: bool = false,
    modal: bool = false,
    live: ?a11y.LivePriority = null,
    rotor_group: ?[]u8 = null,
    nav_order: ?i32 = null,
    pressable: bool = false,
    adjustable: bool = false,
    editable: bool = false,
    caret: ?usize = null,
    selection_start: ?usize = null,
    selection_end: ?usize = null,
    numeric_value: ?f64 = null,
    min_value: ?f64 = null,
    max_value: ?f64 = null,
    heading_level: ?u8 = null,
    description: ?[]u8 = null,
    placeholder: ?[]u8 = null,
    value_description: ?[]u8 = null,
    orientation: ?a11y.Orientation = null,
    url: ?[]u8 = null,
    identifier: ?[]u8 = null,
    parent_id: ?element.ElementId = null,
    frame: NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } },
    /// Retained AX proxy object, owned by the store until cleared.
    proxy: objc.id = null,
};

const RotorType = enum {
    heading,
    link,
    image,
    list,
    text_field,
};

const RotorDirection = enum {
    previous,
    next,
};

const semantic_rotor_types = [_]RotorType{
    .heading,
    .link,
    .image,
    .list,
    .text_field,
};

fn appKitRotorType(rotor_type: RotorType) isize {
    // NSAccessibilityCustomRotorType values from AppKit.
    return switch (rotor_type) {
        .heading => 4,
        .image => 11,
        .link => 14,
        .list => 15,
        .text_field => 18,
    };
}

fn rotorTypeFromAppKit(value: isize) ?RotorType {
    for (semantic_rotor_types) |rotor_type| {
        if (appKitRotorType(rotor_type) == value) return rotor_type;
    }
    return null;
}

fn rotorMatchesRole(rotor_type: RotorType, role: a11y.Role) bool {
    return switch (rotor_type) {
        .heading => role == .heading,
        .link => role == .link,
        .image => role == .img,
        .list => role == .list,
        .text_field => a11y.roleIsText(role),
    };
}

fn rotorCandidateText(node: *const StoredNode) ?[]const u8 {
    if (node.title) |title| {
        if (title.len > 0) return title;
    }
    if (node.value_text) |value| {
        if (value.len > 0) return value;
    }
    return null;
}

fn rotorCandidateMatches(node: *const StoredNode, rotor_type: RotorType, filter: []const u8) bool {
    if (!rotorMatchesRole(rotor_type, node.role)) return false;
    if (filter.len == 0) return true;
    const text = rotorCandidateText(node) orelse return false;
    return std.ascii.indexOfIgnoreCase(text, filter) != null;
}

fn authorRotorCandidateMatches(node: *const StoredNode, group: []const u8, filter: []const u8) bool {
    const label = node.rotor_group orelse return false;
    if (!std.mem.eql(u8, label, group)) return false;
    if (filter.len == 0) return true;
    const text = rotorCandidateText(node) orelse return false;
    return std.ascii.indexOfIgnoreCase(text, filter) != null;
}

fn findRotorCandidate(
    nodes: []const StoredNode,
    rotor_type: RotorType,
    current_index: ?usize,
    direction: RotorDirection,
    filter: []const u8,
) ?usize {
    switch (direction) {
        .next => {
            var i: usize = if (current_index) |index|
                if (index < nodes.len) index + 1 else 0
            else
                0;
            while (i < nodes.len) : (i += 1) {
                if (rotorCandidateMatches(&nodes[i], rotor_type, filter)) return i;
            }
        },
        .previous => {
            var i: usize = if (current_index) |index|
                @min(index, nodes.len)
            else
                nodes.len;
            while (i > 0) {
                i -= 1;
                if (rotorCandidateMatches(&nodes[i], rotor_type, filter)) return i;
            }
        },
    }
    return null;
}

fn findAuthorRotorCandidate(
    nodes: []const StoredNode,
    group: []const u8,
    current_index: ?usize,
    direction: RotorDirection,
    filter: []const u8,
) ?usize {
    switch (direction) {
        .next => {
            var i: usize = if (current_index) |index|
                if (index < nodes.len) index + 1 else 0
            else
                0;
            while (i < nodes.len) : (i += 1) {
                if (authorRotorCandidateMatches(&nodes[i], group, filter)) return i;
            }
        },
        .previous => {
            var i: usize = if (current_index) |index|
                @min(index, nodes.len)
            else
                nodes.len;
            while (i > 0) {
                i -= 1;
                if (authorRotorCandidateMatches(&nodes[i], group, filter)) return i;
            }
        },
    }
    return null;
}

fn collectAvailableRotorTypes(
    nodes: []const StoredNode,
    out: *[semantic_rotor_types.len]RotorType,
) usize {
    var count: usize = 0;
    for (semantic_rotor_types) |rotor_type| {
        for (nodes) |*node| {
            if (rotorMatchesRole(rotor_type, node.role)) {
                out[count] = rotor_type;
                count += 1;
                break;
            }
        }
    }
    return count;
}

fn collectAuthorRotorGroups(
    nodes: []const StoredNode,
    out: *[max_author_rotor_groups][]const u8,
) usize {
    var count: usize = 0;
    for (nodes) |*node| {
        const group = node.rotor_group orelse continue;
        if (group.len == 0) continue;
        var exists = false;
        for (out[0..count]) |existing| {
            if (std.mem.eql(u8, existing, group)) {
                exists = true;
                break;
            }
        }
        if (exists) continue;
        if (count >= max_author_rotor_groups) break;
        out[count] = group;
        count += 1;
    }
    return count;
}

fn storedNavLessThan(nodes: []const StoredNode, a: usize, b: usize) bool {
    const ak = a11y.navOrderKey(nodes[a].nav_order, a);
    const bk = a11y.navOrderKey(nodes[b].nav_order, b);
    return ak[0] < bk[0] or (ak[0] == bk[0] and ak[1] < bk[1]);
}

fn appendProxiesInNavOrder(
    store: *Store,
    parent: ?element.ElementId,
    array: objc.id,
) void {
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(store.allocator);
    for (store.nodes.items, 0..) |*node, i| {
        const matches = if (parent) |pid|
            node.parent_id == pid
        else
            node.parent_id == null;
        if (!matches or node.proxy == null) continue;
        indices.append(store.allocator, i) catch continue;
    }
    std.mem.sort(usize, indices.items, store.nodes.items, struct {
        fn less(ctx: []const StoredNode, a: usize, b: usize) bool {
            return storedNavLessThan(ctx, a, b);
        }
    }.less);
    const add: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    for (indices.items) |i| {
        if (store.nodes.items[i].proxy) |proxy| add(array, sel("addObject:"), proxy);
    }
}

fn indexOfProxy(nodes: []const StoredNode, proxy: objc.id) ?usize {
    if (proxy == null) return null;
    for (nodes, 0..) |*node, index| {
        if (node.proxy == proxy) return index;
    }
    return null;
}

fn rotorCurrentIndex(nodes: []const StoredNode, current_item: objc.id) ?usize {
    if (current_item == null) return null;
    const current_target = msgId(current_item, sel("targetElement"));
    if (indexOfProxy(nodes, current_target)) |index| return index;

    const id_object = objc.objc_getAssociatedObject(current_item, &rotor_item_id_key);
    if (id_object == null) return null;
    return indexOfId(nodes, msgGetU64(id_object, sel("unsignedLongLongValue")));
}

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

    pub const TextEditBridge = struct {
        ctx: *anyopaque,
        set_value: *const fn (ctx: *anyopaque, id: element.ElementId, text: []const u8) void,
        replace_selected_text: *const fn (ctx: *anyopaque, id: element.ElementId, text: []const u8) void,
        set_selected_range: *const fn (ctx: *anyopaque, id: element.ElementId, start: usize, end: usize) void,
    };

    allocator: std.mem.Allocator,
    nodes: std.ArrayList(StoredNode),
    view_height: f64 = 0,
    /// Keyboard focus from `InputState.focused`, updated each sync.
    focused_id: ?element.ElementId = null,
    focused_index: ?usize = null,
    press_bridge: ?PressBridge = null,
    adjust_bridge: ?AdjustBridge = null,
    text_edit_bridge: ?TextEditBridge = null,
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
            freeStoredOwnedStrings(self.allocator, node);
            releaseStoredProxy(node);
        }
        self.nodes.clearRetainingCapacity();
        if (self.children_array != null) {
            msgRelease(self.children_array);
            self.children_array = null;
        }
    }

    /// Copy frame nodes into owned storage. Matching `ElementId`s keep their
    /// AX proxy pointers so VoiceOver can retain focus across value-only frames.
    /// Returns whether identity / parent / role / order / nav_order changed.
    pub fn syncFromNodes(
        self: *Store,
        nodes: []const a11y.Node,
        view_height: f64,
        focused_id: ?element.ElementId,
    ) !SyncOutcome {
        const previous_sig = structureSignature(self.nodes.items);

        var next_nodes: std.ArrayList(StoredNode) = .empty;
        errdefer {
            for (next_nodes.items) |*node| {
                freeStoredOwnedStrings(self.allocator, node);
                // Proxies stolen from `self.nodes` must return on failure.
                if (node.proxy != null) {
                    if (indexOfId(self.nodes.items, node.id)) |idx| {
                        self.nodes.items[idx].proxy = node.proxy;
                        node.proxy = null;
                    } else {
                        releaseStoredProxy(node);
                    }
                }
            }
            next_nodes.deinit(self.allocator);
        }

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
                .busy = node.busy,
                .required = node.required,
                .invalid = node.invalid,
                .modal = node.modal,
                .live = node.live,
                .nav_order = node.nav_order,
                .pressable = node.pressable,
                .adjustable = node.adjustable,
                .editable = node.editable,
                .caret = node.caret,
                .selection_start = node.selection_start,
                .selection_end = node.selection_end,
                .numeric_value = node.numeric_value,
                .min_value = node.min_value,
                .max_value = node.max_value,
                .heading_level = if (node.heading_level) |level|
                    a11y.clampHeadingLevel(level)
                else
                    null,
                .orientation = node.orientation,
                .parent_id = node.parent_id,
                .frame = boundsToAppKitFrame(node.bounds, view_height),
            };

            if (a11y.resolveNameIn(nodes, &node)) |label| {
                stored.title = try self.allocator.dupe(u8, label);
            }
            if (node.value_text) |value| {
                stored.value_text = try self.allocator.dupe(u8, value);
            }
            if (node.rotor_group) |group| {
                if (group.len > 0) {
                    stored.rotor_group = try self.allocator.dupe(u8, group);
                }
            }
            if (node.description) |help| {
                if (help.len > 0) {
                    stored.description = try self.allocator.dupe(u8, help);
                }
            }
            if (node.placeholder) |placeholder| {
                if (placeholder.len > 0) {
                    stored.placeholder = try self.allocator.dupe(u8, placeholder);
                }
            }
            if (node.value_description) |value_description| {
                if (value_description.len > 0) {
                    stored.value_description = try self.allocator.dupe(u8, value_description);
                }
            }
            if (node.url) |url| {
                if (url.len > 0) {
                    stored.url = try self.allocator.dupe(u8, url);
                }
            }
            if (node.identifier) |identifier| {
                if (identifier.len > 0) {
                    stored.identifier = try self.allocator.dupe(u8, identifier);
                }
            }

            if (indexOfId(self.nodes.items, node.id)) |idx| {
                stored.proxy = self.nodes.items[idx].proxy;
                self.nodes.items[idx].proxy = null;
            }

            try next_nodes.append(self.allocator, stored);
        }

        for (self.nodes.items) |*old| {
            freeStoredOwnedStrings(self.allocator, old);
            releaseStoredProxy(old);
        }
        self.nodes.clearRetainingCapacity();
        try self.nodes.appendSlice(self.allocator, next_nodes.items);
        next_nodes.deinit(self.allocator);

        self.view_height = view_height;
        self.focused_id = focused_id;
        self.focused_index = if (focused_id) |fid| indexOfId(self.nodes.items, fid) else null;

        const structure_changed = previous_sig != structureSignature(self.nodes.items);
        return .{ .structure_changed = structure_changed };
    }
};

/// Result of diffing the previous AX store against a new frame snapshot.
pub const SyncOutcome = struct {
    structure_changed: bool,
};

fn freeStoredOwnedStrings(allocator: std.mem.Allocator, node: *StoredNode) void {
    if (node.title) |title| {
        allocator.free(title);
        node.title = null;
    }
    if (node.value_text) |value| {
        allocator.free(value);
        node.value_text = null;
    }
    if (node.rotor_group) |group| {
        allocator.free(group);
        node.rotor_group = null;
    }
    if (node.description) |help| {
        allocator.free(help);
        node.description = null;
    }
    if (node.placeholder) |placeholder| {
        allocator.free(placeholder);
        node.placeholder = null;
    }
    if (node.value_description) |value_description| {
        allocator.free(value_description);
        node.value_description = null;
    }
    if (node.url) |url| {
        allocator.free(url);
        node.url = null;
    }
    if (node.identifier) |identifier| {
        allocator.free(identifier);
        node.identifier = null;
    }
}

fn releaseStoredProxy(node: *StoredNode) void {
    if (node.proxy != null) {
        msgRelease(node.proxy);
        node.proxy = null;
    }
}

/// Identity tree fingerprint: id order, role, parent, and nav_order.
fn structureSignature(nodes: []const StoredNode) u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (nodes) |node| {
        hasher.update(std.mem.asBytes(&node.id));
        const role_tag: u8 = @intFromEnum(node.role);
        hasher.update(std.mem.asBytes(&role_tag));
        const parent_bits: u64 = if (node.parent_id) |pid| pid else std.math.maxInt(u64);
        hasher.update(std.mem.asBytes(&parent_bits));
        const nav_bits: i64 = if (node.nav_order) |order| order else std.math.minInt(i64);
        hasher.update(std.mem.asBytes(&nav_bits));
    }
    hasher.update(std.mem.asBytes(&nodes.len));
    return hasher.final();
}

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

    if (store.children_array != null) {
        msgRelease(store.children_array);
        store.children_array = null;
    }

    for (store.nodes.items, 0..) |*node, i| {
        if (node.proxy != null) {
            setProxyIndex(node.proxy, i);
            setProxyParent(node.proxy, view);
            continue;
        }

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

    appendProxiesInNavOrder(store, null, array);

    store.children_array = msgRetain(array);
}

fn notificationName(name: [:0]const u8) objc.id {
    return nsString(name);
}

fn announcementUserInfo(text: []const u8, priority: a11y.LivePriority) objc.id {
    const dictionary_class = objc.objc_getClass("NSMutableDictionary") orelse return null;
    const user_info = msgClassId(dictionary_class, sel("dictionary"));
    if (user_info == null) return null;

    const message_z = std.heap.c_allocator.dupeZ(u8, text) catch return null;
    defer std.heap.c_allocator.free(message_z);
    const message = nsString(message_z);
    if (message == null) return null;

    const set: *const fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) void =
        @ptrCast(&objc.objc_msgSend);
    set(user_info, sel("setObject:forKey:"), message, nsString("AXAnnouncementKey"));
    set(
        user_info,
        sel("setObject:forKey:"),
        nsNumberInteger(livePriorityValue(priority)),
        nsString("AXPriorityKey"),
    );

    return user_info;
}

fn postAnnouncement(text: []const u8, priority: a11y.LivePriority) void {
    const app_class = objc.objc_getClass("NSApplication") orelse return;
    const application = msgClassId(app_class, sel("sharedApplication"));
    if (application == null) return;

    const user_info = announcementUserInfo(text, priority);
    if (user_info == null) return;

    const post: *const fn (objc.id, objc.id, objc.id) callconv(.c) void = @extern(
        *const fn (objc.id, objc.id, objc.id) callconv(.c) void,
        .{ .name = "NSAccessibilityPostNotificationWithUserInfo" },
    );
    post(application, notificationName("AXAnnouncementRequested"), user_info);
}

fn postNotification(element_obj: objc.id, name: [:0]const u8) void {
    const post: *const fn (objc.id, objc.id) callconv(.c) void = @extern(
        *const fn (objc.id, objc.id) callconv(.c) void,
        .{ .name = "NSAccessibilityPostNotification" },
    );
    post(element_obj, notificationName(name));
}

fn postLayoutChanged(view: objc.id) void {
    postNotification(view, "AXLayoutChanged");
}

fn postFocusedChanged(element_obj: objc.id) void {
    postNotification(element_obj, "AXFocusedUIElementChanged");
}

fn postValueChanged(element_obj: objc.id) void {
    postNotification(element_obj, "AXValueChanged");
}

fn postSelectedTextChanged(element_obj: objc.id) void {
    postNotification(element_obj, "AXSelectedTextChanged");
}

const PrevNodeSnap = struct {
    id: element.ElementId,
    value_hash: u64,
    numeric_value: ?f64,
    boolean_value: ?bool,
    caret: ?usize,
    selection_start: ?usize,
    selection_end: ?usize,
    selected: ?bool,
    expanded: ?bool,
    invalid: bool = false,
    was_text: bool,
    announcement_hash: u64 = 0,
    live: ?a11y.LivePriority = null,
};

const SnapshotChanges = struct {
    value: bool,
    text_selection: bool,
    selected: bool,
    expanded: bool,
    invalid: bool,
};

fn hashOptionalText(text: ?[]const u8) u64 {
    return if (text) |slice| std.hash.Wyhash.hash(0, slice) else 0;
}

fn announcementText(node: *const StoredNode) ?[]const u8 {
    if (node.value_text) |value| {
        if (value.len > 0) return value;
    }
    if (node.title) |title| {
        if (title.len > 0) return title;
    }
    return null;
}

fn livePriorityValue(priority: a11y.LivePriority) isize {
    return switch (priority) {
        .polite => 10,
        .assertive => 90,
    };
}

fn shouldAnnounce(node: *const StoredNode, before: ?*const PrevNodeSnap) bool {
    const live = node.live orelse return false;
    const text = announcementText(node) orelse return false;
    const previous = before orelse return true;
    return !std.meta.eql(previous.live, live) or
        previous.announcement_hash != hashOptionalText(text);
}

fn capturePrevSnaps(store: *const Store, out: *std.ArrayList(PrevNodeSnap)) !void {
    out.clearRetainingCapacity();
    try out.ensureTotalCapacity(store.allocator, store.nodes.items.len);
    for (store.nodes.items) |*node| {
        out.appendAssumeCapacity(.{
            .id = node.id,
            .value_hash = hashOptionalText(node.value_text),
            .numeric_value = node.numeric_value,
            .boolean_value = booleanValue(node),
            .caret = node.caret,
            .selection_start = node.selection_start,
            .selection_end = node.selection_end,
            .selected = node.selected,
            .expanded = node.expanded,
            .invalid = node.invalid,
            .was_text = a11y.roleIsText(node.role),
            .announcement_hash = hashOptionalText(announcementText(node)),
            .live = node.live,
        });
    }
}

fn findPrevSnap(snaps: []const PrevNodeSnap, id: element.ElementId) ?*const PrevNodeSnap {
    for (snaps) |*snap| {
        if (snap.id == id) return snap;
    }
    return null;
}

fn snapshotChanges(node: *const StoredNode, before: *const PrevNodeSnap) SnapshotChanges {
    const value_hash = hashOptionalText(node.value_text);
    return .{
        .value = value_hash != before.value_hash or
            !std.meta.eql(node.numeric_value, before.numeric_value) or
            !std.meta.eql(booleanValue(node), before.boolean_value),
        .text_selection = a11y.roleIsText(node.role) and before.was_text and
            (!std.meta.eql(node.caret, before.caret) or
                !std.meta.eql(node.selection_start, before.selection_start) or
                !std.meta.eql(node.selection_end, before.selection_end)),
        .selected = !std.meta.eql(node.selected, before.selected),
        .expanded = !std.meta.eql(node.expanded, before.expanded),
        .invalid = node.invalid != before.invalid,
    };
}

fn selectionChangedNotification(parent_role: a11y.Role) [:0]const u8 {
    return if (parent_role == .tree) "AXSelectedRowsChanged" else "AXSelectedChildrenChanged";
}

fn expandedChangedNotification(role: a11y.Role, expanded: bool) ?[:0]const u8 {
    return switch (role) {
        .tree, .tree_item => if (expanded) "AXRowExpanded" else "AXRowCollapsed",
        else => null,
    };
}

fn postStateNotifications(store: *const Store, prev: []const PrevNodeSnap) void {
    for (store.nodes.items) |*node| {
        const proxy = node.proxy orelse continue;
        const before = findPrevSnap(prev, node.id);
        if (shouldAnnounce(node, before)) {
            postAnnouncement(announcementText(node).?, node.live.?);
        }

        const previous = before orelse continue;
        const changes = snapshotChanges(node, previous);
        if (changes.value) postValueChanged(proxy);
        if (changes.text_selection) postSelectedTextChanged(proxy);

        if (changes.selected) {
            var target = proxy;
            var parent_role = node.role;
            if (node.parent_id) |parent_id| {
                if (indexOfId(store.nodes.items, parent_id)) |parent_index| {
                    const parent = &store.nodes.items[parent_index];
                    if (parent.proxy) |parent_proxy| target = parent_proxy;
                    parent_role = parent.role;
                }
            }
            postNotification(target, selectionChangedNotification(parent_role));
        }

        if (changes.expanded) {
            if (expandedChangedNotification(node.role, node.expanded orelse false)) |name| {
                postNotification(proxy, name);
            }
        }

        if (changes.invalid) {
            postNotification(proxy, "AXInvalidStatusChanged");
        }
    }
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
    var prev_snaps: std.ArrayList(PrevNodeSnap) = .empty;
    defer prev_snaps.deinit(store.allocator);
    capturePrevSnaps(store, &prev_snaps) catch {
        log.warn("a11y prev snapshot OOM", .{});
    };

    const bounds = msgGetRect(view, sel("bounds"));
    const outcome = store.syncFromNodes(nodes, bounds.size.height, focused_id) catch |err| {
        log.warn("syncFromNodes failed: {}", .{err});
        return;
    };

    rebuildProxies(view, store);

    log.debug("a11y sync: {d} nodes (view height {d}, focused {}, structure_changed {})", .{
        store.nodes.items.len,
        bounds.size.height,
        focused_id != null,
        outcome.structure_changed,
    });

    // Value-only frames keep AX proxies; avoid AXLayoutChanged so VoiceOver
    // does not treat a text edit as a full tree rebuild.
    if (outcome.structure_changed) {
        postLayoutChanged(view);
    }
    postStateNotifications(store, prev_snaps.items);

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
    text_edit_bridge: Store.TextEditBridge,
) void {
    store.press_bridge = press_bridge;
    store.adjust_bridge = adjust_bridge;
    store.text_edit_bridge = text_edit_bridge;
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

    // Prefer NSAccessibilityElement so super can synthesize attribute names from
    // the modern protocol; we append AXInvalid for validation state.
    const ns_object = objc.objc_getClass("NSAccessibilityElement") orelse
        objc.objc_getClass("NSObject") orelse return;
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
    addMethod(ax_element_class, "accessibilitySubrole", @ptrCast(&impAxSubrole), "@@:");
    addMethod(ax_element_class, "accessibilityLabel", @ptrCast(&impAxLabel), "@@:");
    addMethod(ax_element_class, "accessibilityHelp", @ptrCast(&impAxHelp), "@@:");
    addMethod(ax_element_class, "accessibilityPlaceholderValue", @ptrCast(&impAxPlaceholderValue), "@@:");
    addMethod(ax_element_class, "accessibilityValueDescription", @ptrCast(&impAxValueDescription), "@@:");
    addMethod(ax_element_class, "accessibilityOrientation", @ptrCast(&impAxOrientation), "q@:");
    addMethod(ax_element_class, "accessibilityURL", @ptrCast(&impAxURL), "@@:");
    addMethod(ax_element_class, "accessibilityIdentifier", @ptrCast(&impAxIdentifier), "@@:");
    addMethod(ax_element_class, "accessibilityValue", @ptrCast(&impAxValue), "@@:");
    addMethod(ax_element_class, "accessibilityLevel", @ptrCast(&impAxLevel), "@@:");
    addMethod(ax_element_class, "setAccessibilityValue:", @ptrCast(&impAxSetValue), "v@:@");
    addMethod(ax_element_class, "accessibilitySelectedText", @ptrCast(&impAxSelectedText), "@@:");
    addMethod(ax_element_class, "setAccessibilitySelectedText:", @ptrCast(&impAxSetSelectedText), "v@:@");
    addMethod(ax_element_class, "accessibilitySelectedTextRange", @ptrCast(&impAxSelectedTextRange), "{_NSRange=QQ}@:");
    addMethod(ax_element_class, "setAccessibilitySelectedTextRange:", @ptrCast(&impAxSetSelectedTextRange), "v@:{_NSRange=QQ}");
    addMethod(ax_element_class, "accessibilityFrame", @ptrCast(&impAxFrame), "{CGRect={CGPoint=dd}{CGSize=dd}}@:");
    addMethod(ax_element_class, "accessibilityParent", @ptrCast(&impAxParent), "@@:");
    addMethod(ax_element_class, "accessibilityChildren", @ptrCast(&impAxChildren), "@@:");
    addMethod(ax_element_class, "isAccessibilityEnabled", @ptrCast(&impAxEnabled), "c@:");
    addMethod(ax_element_class, "isAccessibilityFocused", @ptrCast(&impAxFocused), "c@:");
    addMethod(ax_element_class, "isAccessibilitySelected", @ptrCast(&impAxSelected), "c@:");
    addMethod(ax_element_class, "isAccessibilityExpanded", @ptrCast(&impAxExpanded), "c@:");
    addMethod(ax_element_class, "isAccessibilityBusy", @ptrCast(&impAxBusy), "c@:");
    addMethod(ax_element_class, "isAccessibilityRequired", @ptrCast(&impAxRequired), "c@:");
    addMethod(ax_element_class, "isAccessibilityModal", @ptrCast(&impAxModal), "c@:");
    addMethod(ax_element_class, "accessibilityAttributeNames", @ptrCast(&impAxAttributeNames), "@@:");
    addMethod(ax_element_class, "accessibilityAttributeValue:", @ptrCast(&impAxAttributeValue), "@@:@");
    addMethod(ax_element_class, "accessibilityActionNames", @ptrCast(&impAxActionNames), "@@:");
    addMethod(ax_element_class, "accessibilityPerformAction:", @ptrCast(&impAxPerformAction), "v@:@");
    addMethod(ax_element_class, "accessibilityPerformPress", @ptrCast(&impAxPerformPress), "c@:");
    addMethod(ax_element_class, "accessibilityPerformShowMenu", @ptrCast(&impAxPerformShowMenu), "c@:");
    addMethod(ax_element_class, "accessibilityPerformIncrement", @ptrCast(&impAxPerformIncrement), "c@:");
    addMethod(ax_element_class, "accessibilityPerformDecrement", @ptrCast(&impAxPerformDecrement), "c@:");
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
    addMethod(view_class, "accessibilityCustomRotors", @ptrCast(&impViewAccessibilityCustomRotors), "@@:");
    addMethod(view_class, "rotor:resultForSearchParameters:", @ptrCast(&impViewRotorResult), "@@:@@");
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

fn customRotorsForStore(store: *const Store, delegate: objc.id) objc.id {
    const array_class = objc.objc_getClass("NSMutableArray") orelse return emptyArray();
    const array = msgClassId(array_class, sel("array"));
    if (array == null) return emptyArray();

    const rotor_class = objc.objc_getClass("NSAccessibilityCustomRotor") orelse return array;
    var available: [semantic_rotor_types.len]RotorType = undefined;
    const count = collectAvailableRotorTypes(store.nodes.items, &available);
    const add: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    const init_typed: *const fn (objc.id, objc.SEL, isize, objc.id) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    const init_labeled: *const fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);

    for (available[0..count]) |rotor_type| {
        const alloc = msgClassId(rotor_class, sel("alloc"));
        if (alloc == null) continue;
        const rotor = init_typed(
            alloc,
            sel("initWithRotorType:itemSearchDelegate:"),
            appKitRotorType(rotor_type),
            delegate,
        );
        if (rotor == null) {
            msgRelease(alloc);
            continue;
        }
        add(array, sel("addObject:"), rotor);
        msgRelease(rotor);
    }

    var groups: [max_author_rotor_groups][]const u8 = undefined;
    const group_count = collectAuthorRotorGroups(store.nodes.items, &groups);
    for (groups[0..group_count]) |group| {
        const alloc = msgClassId(rotor_class, sel("alloc"));
        if (alloc == null) continue;
        const label_z = std.heap.c_allocator.dupeZ(u8, group) catch {
            msgRelease(alloc);
            continue;
        };
        defer std.heap.c_allocator.free(label_z);
        const label = nsString(label_z);
        if (label == null) {
            msgRelease(alloc);
            continue;
        }
        const rotor = init_labeled(
            alloc,
            sel("initWithLabel:itemSearchDelegate:"),
            label,
            delegate,
        );
        if (rotor == null) {
            msgRelease(alloc);
            continue;
        }
        add(array, sel("addObject:"), rotor);
        msgRelease(rotor);
    }
    return array;
}

fn impViewAccessibilityCustomRotors(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const store = storeFromView(_self) orelse return emptyArray();
    return customRotorsForStore(store, _self);
}

fn impViewRotorResult(
    _self: objc.id,
    _cmd: objc.SEL,
    rotor: objc.id,
    parameters: objc.id,
) callconv(.c) objc.id {
    _ = _cmd;
    const store = storeFromView(_self) orelse return null;
    const direction: RotorDirection = switch (msgGetInteger(parameters, sel("searchDirection"))) {
        0 => .previous,
        1 => .next,
        else => return null,
    };

    const current_item = msgId(parameters, sel("currentItem"));
    const current_index = rotorCurrentIndex(store.nodes.items, current_item);
    const filter = nsStringUtf8(msgId(parameters, sel("filterString"))) orelse "";

    const type_value = msgGetInteger(rotor, sel("type"));
    const index = if (rotorTypeFromAppKit(type_value)) |rotor_type|
        findRotorCandidate(
            store.nodes.items,
            rotor_type,
            current_index,
            direction,
            filter,
        )
    else if (type_value == appkit_rotor_type_custom) blk: {
        const label = nsStringUtf8(msgId(rotor, sel("label"))) orelse break :blk null;
        break :blk findAuthorRotorCandidate(
            store.nodes.items,
            label,
            current_index,
            direction,
            filter,
        );
    } else null;
    const found = index orelse return null;
    const target = store.nodes.items[found].proxy orelse return null;

    const result_class = objc.objc_getClass("NSAccessibilityCustomRotorItemResult") orelse return null;
    const alloc = msgClassId(result_class, sel("alloc"));
    if (alloc == null) return null;
    const init: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    const result = init(alloc, sel("initWithTargetElement:"), target);
    if (result == null) {
        msgRelease(alloc);
        return null;
    }
    objc.objc_setAssociatedObject(
        result,
        &rotor_item_id_key,
        nsNumberU64(store.nodes.items[found].id),
        @intCast(objc.OBJC_ASSOCIATION_RETAIN_NONATOMIC),
    );
    return msgId(result, sel("autorelease"));
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

fn impAxSubrole(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return null;
    const subrole = roleToNsSubrole(node.role) orelse return null;
    return nsString(subrole);
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

fn impAxHelp(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return null;
    if (node.description) |help| {
        const z = std.heap.c_allocator.dupeZ(u8, help) catch return null;
        defer std.heap.c_allocator.free(z);
        return nsString(z);
    }
    return null;
}

fn impAxPlaceholderValue(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return null;
    if (node.placeholder) |placeholder| {
        const z = std.heap.c_allocator.dupeZ(u8, placeholder) catch return null;
        defer std.heap.c_allocator.free(z);
        return nsString(z);
    }
    return null;
}

fn impAxValueDescription(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return null;
    if (node.value_description) |value_description| {
        const z = std.heap.c_allocator.dupeZ(u8, value_description) catch return null;
        defer std.heap.c_allocator.free(z);
        return nsString(z);
    }
    return null;
}

/// NSAccessibilityOrientation: Unknown=0, Vertical=1, Horizontal=2.
fn orientationToNs(orientation: ?a11y.Orientation) isize {
    return switch (orientation orelse return 0) {
        .vertical => 1,
        .horizontal => 2,
    };
}

fn impAxOrientation(_self: objc.id, _cmd: objc.SEL) callconv(.c) isize {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return 0;
    return orientationToNs(node.orientation);
}

fn impAxURL(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return null;
    if (node.url) |url| {
        const z = std.heap.c_allocator.dupeZ(u8, url) catch return null;
        defer std.heap.c_allocator.free(z);
        return nsUrl(z);
    }
    return null;
}

fn impAxIdentifier(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return null;
    if (node.identifier) |identifier| {
        const z = std.heap.c_allocator.dupeZ(u8, identifier) catch return null;
        defer std.heap.c_allocator.free(z);
        return nsString(z);
    }
    return null;
}

fn impAxLevel(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return null;
    if (node.role != .heading) return null;
    const level = node.heading_level orelse return null;
    return nsNumberInteger(@intCast(level));
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
    appendProxiesInNavOrder(store, node.id, array);
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

fn impAxSelected(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.BOOL {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return NO;
    return if (node.selected orelse false) YES else NO;
}

fn impAxExpanded(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.BOOL {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return NO;
    return if (node.expanded orelse false) YES else NO;
}

fn impAxBusy(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.BOOL {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return NO;
    return if (node.busy) YES else NO;
}

fn impAxRequired(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.BOOL {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return NO;
    return if (node.required) YES else NO;
}

fn impAxModal(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.BOOL {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return NO;
    return if (node.modal) YES else NO;
}

fn axAttributeEquals(attribute: objc.id, name: []const u8) bool {
    const utf8 = nsStringUtf8(attribute) orelse return false;
    return std.mem.eql(u8, utf8, name);
}

fn impAxAttributeNames(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.id {
    const our_cls = objc.object_getClass(_self);
    var super = objc.objc_super{
        .receiver = _self,
        .super_class = objc.class_getSuperclass(our_cls),
    };
    const super_fn: *const fn (*objc.objc_super, objc.SEL) callconv(.c) objc.id =
        @ptrCast(&objc.objc_msgSendSuper);
    const base = super_fn(&super, _cmd);

    const array_class = objc.objc_getClass("NSMutableArray") orelse return base;
    const mutable = if (base != null)
        msgId(base, sel("mutableCopy"))
    else
        msgClassId(array_class, sel("array"));
    if (mutable == null) return base;

    const add: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    const contains: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) objc.BOOL = @ptrCast(&objc.objc_msgSend);
    const invalid_attr = nsString("AXInvalid");
    if (contains(mutable, sel("containsObject:"), invalid_attr) == NO) {
        add(mutable, sel("addObject:"), invalid_attr);
    }
    return msgId(mutable, sel("autorelease"));
}

fn impAxAttributeValue(_self: objc.id, _cmd: objc.SEL, attribute: objc.id) callconv(.c) objc.id {
    if (axAttributeEquals(attribute, "AXInvalid")) {
        const node = storedNodeFromProxy(_self) orelse return nsString("false");
        return nsString(if (node.invalid) "true" else "false");
    }

    const our_cls = objc.object_getClass(_self);
    var super = objc.objc_super{
        .receiver = _self,
        .super_class = objc.class_getSuperclass(our_cls),
    };
    const super_fn: *const fn (*objc.objc_super, objc.SEL, objc.id) callconv(.c) objc.id =
        @ptrCast(&objc.objc_msgSendSuper);
    return super_fn(&super, _cmd, attribute);
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
    if (nodeSupportsShowMenu(node)) {
        add(array, sel("addObject:"), nsString("AXShowMenu"));
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

fn performAxShowMenu(_self: objc.id) bool {
    const node = storedNodeFromProxy(_self) orelse return false;
    if (!nodeSupportsShowMenu(node)) return false;
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

fn performAxSetValue(_self: objc.id, value: objc.id) bool {
    const node = storedNodeFromProxy(_self) orelse return false;
    if (!nodeSupportsSetValue(node)) return false;
    const store = storeFromProxy(_self) orelse return false;
    const bridge = store.text_edit_bridge orelse return false;
    const text = nsStringUtf8(value) orelse "";
    bridge.set_value(bridge.ctx, node.id, text);
    return true;
}

fn performAxReplaceSelectedText(_self: objc.id, value: objc.id) bool {
    const node = storedNodeFromProxy(_self) orelse return false;
    if (!nodeSupportsSetValue(node)) return false;
    const store = storeFromProxy(_self) orelse return false;
    const bridge = store.text_edit_bridge orelse return false;
    const text = nsStringUtf8(value) orelse "";
    bridge.replace_selected_text(bridge.ctx, node.id, text);
    return true;
}

fn performAxSetSelectedRange(_self: objc.id, range: NSRange) bool {
    const node = storedNodeFromProxy(_self) orelse return false;
    if (!nodeSupportsSetValue(node)) return false;
    const store = storeFromProxy(_self) orelse return false;
    const bridge = store.text_edit_bridge orelse return false;
    const value = node.value_text orelse "";
    const byte_range = utf16RangeToByte(value, range) orelse return false;
    bridge.set_selected_range(bridge.ctx, node.id, byte_range.start, byte_range.end);
    return true;
}

fn impAxSetValue(_self: objc.id, _cmd: objc.SEL, value: objc.id) callconv(.c) void {
    _ = _cmd;
    _ = performAxSetValue(_self, value);
}

fn impAxSetSelectedText(_self: objc.id, _cmd: objc.SEL, value: objc.id) callconv(.c) void {
    _ = _cmd;
    _ = performAxReplaceSelectedText(_self, value);
}

fn impAxSetSelectedTextRange(_self: objc.id, _cmd: objc.SEL, range: NSRange) callconv(.c) void {
    _ = _cmd;
    _ = performAxSetSelectedRange(_self, range);
}

fn impAxPerformAction(_self: objc.id, _cmd: objc.SEL, action: objc.id) callconv(.c) void {
    _ = _cmd;
    const name = nsStringUtf8(action) orelse return;
    if (std.mem.eql(u8, name, "AXPress")) {
        _ = performAxPress(_self);
    } else if (std.mem.eql(u8, name, "AXShowMenu")) {
        _ = performAxShowMenu(_self);
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

fn impAxPerformShowMenu(_self: objc.id, _cmd: objc.SEL) callconv(.c) objc.BOOL {
    _ = _cmd;
    return if (performAxShowMenu(_self)) YES else NO;
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

fn impAxSelectedTextRange(_self: objc.id, _cmd: objc.SEL) callconv(.c) NSRange {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return .{ .location = 0, .length = 0 };
    if (!a11y.roleIsText(node.role)) return .{ .location = 0, .length = 0 };
    const value = node.value_text orelse return .{ .location = 0, .length = 0 };
    const start_b = node.selection_start orelse node.caret orelse 0;
    const end_b = node.selection_end orelse start_b;
    const start_utf16 = byteOffsetToUtf16(value, start_b);
    const end_utf16 = byteOffsetToUtf16(value, end_b);
    return .{
        .location = start_utf16,
        .length = if (end_utf16 >= start_utf16) end_utf16 - start_utf16 else 0,
    };
}

fn impAxNumberOfCharacters(_self: objc.id, _cmd: objc.SEL) callconv(.c) isize {
    _ = _cmd;
    const node = storedNodeFromProxy(_self) orelse return 0;
    if (!a11y.roleIsText(node.role)) return 0;
    const value = node.value_text orelse return 0;
    return @intCast(utf16Length(value));
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
    try std.testing.expectEqualStrings("AXButton", roleToNsRole(.switch_control).?);
    try std.testing.expectEqualStrings("AXRadioButton", roleToNsRole(.radio).?);
    try std.testing.expectEqualStrings("AXRadioGroup", roleToNsRole(.radio_group).?);
    try std.testing.expectEqualStrings("AXSlider", roleToNsRole(.slider).?);
    try std.testing.expectEqualStrings("AXScrollBar", roleToNsRole(.scrollbar).?);
    try std.testing.expectEqualStrings("AXTextField", roleToNsRole(.textbox).?);
    try std.testing.expectEqualStrings("AXTextArea", roleToNsRole(.textarea).?);
    try std.testing.expectEqualStrings("AXList", roleToNsRole(.list).?);
    try std.testing.expectEqualStrings("AXTable", roleToNsRole(.table).?);
    try std.testing.expectEqualStrings("AXCell", roleToNsRole(.cell).?);
    try std.testing.expectEqualStrings("AXGroup", roleToNsRole(.group).?);
    try std.testing.expectEqualStrings("AXMenuBar", roleToNsRole(.menu_bar).?);
    try std.testing.expectEqualStrings("AXToolbar", roleToNsRole(.toolbar).?);
    try std.testing.expectEqualStrings("AXSplitter", roleToNsRole(.splitter).?);
    try std.testing.expectEqualStrings("AXSheet", roleToNsRole(.sheet).?);
    try std.testing.expectEqualStrings("AXGroup", roleToNsRole(.alert).?);
    try std.testing.expectEqualStrings("AXGroup", roleToNsRole(.status).?);
    try std.testing.expectEqualStrings("AXOutline", roleToNsRole(.tree).?);
    try std.testing.expectEqualStrings("AXPopUpButton", roleToNsRole(.pop_up_button).?);
    try std.testing.expectEqualStrings("AXComboBox", roleToNsRole(.combobox).?);
    try std.testing.expect(roleToNsRole(.none) == null);
}

test "roleToNsRole covers every Role variant" {
    inline for (@typeInfo(a11y.Role).@"enum".fields) |field| {
        const role: a11y.Role = @enumFromInt(field.value);
        if (role == .none) {
            try std.testing.expect(roleToNsRole(role) == null);
        } else {
            try std.testing.expect(roleToNsRole(role) != null);
        }
    }
}

test "roleToNsSubrole maps semantic variants" {
    try std.testing.expectEqualStrings("AXSwitch", roleToNsSubrole(.switch_control).?);
    try std.testing.expectEqualStrings("AXSearchField", roleToNsSubrole(.search).?);
    try std.testing.expectEqualStrings("AXDialog", roleToNsSubrole(.dialog).?);
    try std.testing.expectEqualStrings("AXTabButton", roleToNsSubrole(.tab).?);
    try std.testing.expectEqualStrings("AXOutlineRow", roleToNsSubrole(.tree_item).?);
    try std.testing.expect(roleToNsSubrole(.button) == null);
}

test "snapshotChanges tracks boolean selected and expanded state" {
    const before = PrevNodeSnap{
        .id = element.elementId("stateful"),
        .value_hash = hashOptionalText(null),
        .numeric_value = null,
        .boolean_value = false,
        .caret = null,
        .selection_start = null,
        .selection_end = null,
        .selected = false,
        .expanded = false,
        .was_text = false,
    };
    var node = StoredNode{
        .id = before.id,
        .role = .checkbox,
        .ns_role = "AXCheckBox",
        .checked = true,
        .selected = false,
        .expanded = false,
    };

    var changes = snapshotChanges(&node, &before);
    try std.testing.expect(changes.value);
    try std.testing.expect(!changes.selected);
    try std.testing.expect(!changes.expanded);

    node.role = .tree_item;
    node.checked = null;
    node.selected = true;
    changes = snapshotChanges(&node, &before);
    try std.testing.expect(changes.value);
    try std.testing.expect(changes.selected);
    try std.testing.expect(!changes.expanded);

    node.selected = false;
    node.expanded = true;
    changes = snapshotChanges(&node, &before);
    try std.testing.expect(!changes.value);
    try std.testing.expect(!changes.selected);
    try std.testing.expect(changes.expanded);
}

test "state notification names match AppKit semantics" {
    try std.testing.expectEqualStrings("AXSelectedRowsChanged", selectionChangedNotification(.tree));
    try std.testing.expectEqualStrings("AXSelectedChildrenChanged", selectionChangedNotification(.tab_list));
    try std.testing.expectEqualStrings("AXRowExpanded", expandedChangedNotification(.tree_item, true).?);
    try std.testing.expectEqualStrings("AXRowCollapsed", expandedChangedNotification(.tree_item, false).?);
    try std.testing.expect(expandedChangedNotification(.menu_item, true) == null);
    try std.testing.expect(expandedChangedNotification(.button, false) == null);
}

test "notification names bridge to NSString objects" {
    const object = notificationName("AXValueChanged");
    try std.testing.expectEqualStrings("AXValueChanged", nsStringUtf8(object).?);
}

test "live priorities map to AppKit announcement levels" {
    try std.testing.expectEqual(@as(isize, 10), livePriorityValue(.polite));
    try std.testing.expectEqual(@as(isize, 90), livePriorityValue(.assertive));
}

test "live announcement user info contains AppKit text and priority objects" {
    const user_info = announcementUserInfo("Saved", .assertive);
    try std.testing.expect(user_info != null);

    const announcement = msgIdArg(user_info, sel("objectForKey:"), nsString("AXAnnouncementKey"));
    try std.testing.expectEqualStrings("Saved", nsStringUtf8(announcement).?);

    const priority = msgIdArg(user_info, sel("objectForKey:"), nsString("AXPriorityKey"));
    try std.testing.expectEqual(@as(isize, 90), msgGetInteger(priority, sel("integerValue")));
}

test "live announcements fire on insertion text or priority changes only" {
    var saved = [_]u8{ 'S', 'a', 'v', 'e', 'd' };
    var node = StoredNode{
        .id = element.elementId("toast"),
        .role = .tooltip,
        .ns_role = "AXHelpTag",
        .title = saved[0..],
        .live = .polite,
    };
    try std.testing.expect(shouldAnnounce(&node, null));

    var before = PrevNodeSnap{
        .id = node.id,
        .value_hash = hashOptionalText(null),
        .numeric_value = null,
        .boolean_value = null,
        .caret = null,
        .selection_start = null,
        .selection_end = null,
        .selected = null,
        .expanded = null,
        .was_text = false,
        .announcement_hash = hashOptionalText(saved[0..]),
        .live = .polite,
    };
    try std.testing.expect(!shouldAnnounce(&node, &before));

    saved[0] = 's';
    try std.testing.expect(shouldAnnounce(&node, &before));
    saved[0] = 'S';
    node.live = .assertive;
    try std.testing.expect(shouldAnnounce(&node, &before));

    before.live = null;
    node.live = null;
    try std.testing.expect(!shouldAnnounce(&node, &before));
    node.live = .polite;
    node.title = null;
    try std.testing.expect(!shouldAnnounce(&node, &before));
}

test "semantic rotor types map AppKit categories to roles" {
    try std.testing.expectEqual(@as(isize, 4), appKitRotorType(.heading));
    try std.testing.expectEqual(@as(isize, 11), appKitRotorType(.image));
    try std.testing.expectEqual(@as(isize, 14), appKitRotorType(.link));
    try std.testing.expectEqual(@as(isize, 15), appKitRotorType(.list));
    try std.testing.expectEqual(@as(isize, 18), appKitRotorType(.text_field));

    try std.testing.expect(rotorMatchesRole(.heading, .heading));
    try std.testing.expect(rotorMatchesRole(.link, .link));
    try std.testing.expect(rotorMatchesRole(.image, .img));
    try std.testing.expect(rotorMatchesRole(.list, .list));
    try std.testing.expect(rotorMatchesRole(.text_field, .textbox));
    try std.testing.expect(rotorMatchesRole(.text_field, .textarea));
    try std.testing.expect(rotorMatchesRole(.text_field, .search));
    try std.testing.expect(!rotorMatchesRole(.heading, .generic));
}

test "semantic rotor availability is deduplicated in stable category order" {
    const nodes = [_]StoredNode{
        .{ .id = element.elementId("docs"), .role = .link, .ns_role = "AXLink" },
        .{ .id = element.elementId("title"), .role = .heading, .ns_role = "AXHeading" },
        .{ .id = element.elementId("more-docs"), .role = .link, .ns_role = "AXLink" },
        .{ .id = element.elementId("query"), .role = .search, .ns_role = "AXTextField" },
    };
    var available: [semantic_rotor_types.len]RotorType = undefined;
    const count = collectAvailableRotorTypes(&nodes, &available);

    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(RotorType.heading, available[0]);
    try std.testing.expectEqual(RotorType.link, available[1]);
    try std.testing.expectEqual(RotorType.text_field, available[2]);
}

test "AppKit semantic rotor objects delegate ordered searches to the view" {
    const ns_object = objc.objc_getClass("NSObject") orelse return error.SkipZigTest;
    const test_class = objc.objc_allocateClassPair(ns_object, "ZgpuiRotorTestView", 0) orelse
        return error.SkipZigTest;
    registerViewAccessibilityIvar(test_class);
    registerViewAccessibilityMethods(test_class);
    objc.objc_registerClassPair(test_class);

    try std.testing.expect(objc.class_respondsToSelector(test_class, sel("accessibilityCustomRotors")) != NO);
    try std.testing.expect(objc.class_respondsToSelector(test_class, sel("rotor:resultForSearchParameters:")) != NO);

    const alloc = msgClassId(test_class, sel("alloc"));
    try std.testing.expect(alloc != null);
    const view = msgId(alloc, sel("init"));
    try std.testing.expect(view != null);
    defer msgRelease(view);

    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const nodes = [_]a11y.Node{
        .{ .id = element.elementId("intro"), .role = .heading, .name = .{ .label = "Intro" } },
        .{ .id = element.elementId("docs"), .role = .link, .name = .{ .label = "Docs" } },
        .{ .id = element.elementId("details"), .role = .heading, .name = .{ .label = "Details" } },
    };
    _ = try store.syncFromNodes(&nodes, 480, null);
    _ = objc.object_setInstanceVariable(view, store_ivar, &store);
    rebuildProxies(view, &store);

    const count: *const fn (objc.id, objc.SEL) callconv(.c) usize = @ptrCast(&objc.objc_msgSend);
    const object_at: *const fn (objc.id, objc.SEL, usize) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    const set_integer: *const fn (objc.id, objc.SEL, isize) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    const set_id: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    const search: *const fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);

    const rotors = msgId(view, sel("accessibilityCustomRotors"));
    try std.testing.expectEqual(@as(usize, 2), count(rotors, sel("count")));
    const heading_rotor = object_at(rotors, sel("objectAtIndex:"), 0);
    const link_rotor = object_at(rotors, sel("objectAtIndex:"), 1);
    try std.testing.expectEqual(appKitRotorType(.heading), msgGetInteger(heading_rotor, sel("type")));
    try std.testing.expectEqual(appKitRotorType(.link), msgGetInteger(link_rotor, sel("type")));
    try std.testing.expectEqual(view, msgId(heading_rotor, sel("itemSearchDelegate")));

    const parameters_class = objc.objc_getClass("NSAccessibilityCustomRotorSearchParameters") orelse
        return error.SkipZigTest;
    const parameters_alloc = msgClassId(parameters_class, sel("alloc"));
    try std.testing.expect(parameters_alloc != null);
    const parameters = msgId(parameters_alloc, sel("init"));
    try std.testing.expect(parameters != null);
    defer msgRelease(parameters);
    set_integer(parameters, sel("setSearchDirection:"), 1);
    set_id(parameters, sel("setFilterString:"), nsString(""));

    const first = search(view, sel("rotor:resultForSearchParameters:"), heading_rotor, parameters);
    try std.testing.expect(first != null);
    try std.testing.expectEqual(store.nodes.items[0].proxy, msgId(first, sel("targetElement")));

    set_id(parameters, sel("setCurrentItem:"), first);
    _ = try store.syncFromNodes(&nodes, 480, null);
    rebuildProxies(view, &store);
    const second = search(view, sel("rotor:resultForSearchParameters:"), heading_rotor, parameters);
    try std.testing.expect(second != null);
    try std.testing.expectEqual(store.nodes.items[2].proxy, msgId(second, sel("targetElement")));

    set_id(parameters, sel("setCurrentItem:"), second);
    try std.testing.expect(search(view, sel("rotor:resultForSearchParameters:"), heading_rotor, parameters) == null);
}

test "semantic rotor search follows direction filters and boundaries" {
    const nodes = [_]StoredNode{
        .{ .id = element.elementId("intro"), .role = .heading, .ns_role = "AXHeading", .title = @constCast("Intro") },
        .{ .id = element.elementId("docs"), .role = .link, .ns_role = "AXLink", .title = @constCast("Docs") },
        .{ .id = element.elementId("details"), .role = .heading, .ns_role = "AXHeading", .title = @constCast("Details") },
        .{ .id = element.elementId("appendix"), .role = .heading, .ns_role = "AXHeading", .value_text = @constCast("Appendix") },
    };

    try std.testing.expectEqual(@as(?usize, 0), findRotorCandidate(&nodes, .heading, null, .next, ""));
    try std.testing.expectEqual(@as(?usize, 3), findRotorCandidate(&nodes, .heading, null, .previous, ""));
    try std.testing.expectEqual(@as(?usize, 2), findRotorCandidate(&nodes, .heading, 0, .next, ""));
    try std.testing.expectEqual(@as(?usize, 0), findRotorCandidate(&nodes, .heading, 2, .previous, ""));
    try std.testing.expectEqual(@as(?usize, null), findRotorCandidate(&nodes, .heading, 0, .previous, ""));
    try std.testing.expectEqual(@as(?usize, null), findRotorCandidate(&nodes, .heading, 3, .next, ""));
    try std.testing.expectEqual(@as(?usize, 2), findRotorCandidate(&nodes, .heading, null, .next, "TAIL"));
    try std.testing.expectEqual(@as(?usize, 3), findRotorCandidate(&nodes, .heading, null, .next, "pend"));
    try std.testing.expectEqual(@as(?usize, null), findRotorCandidate(&nodes, .heading, null, .next, "missing"));
}

test "author rotor groups are collected in first-seen order" {
    const nodes = [_]StoredNode{
        .{ .id = element.elementId("err1"), .role = .generic, .ns_role = "AXGroup", .rotor_group = @constCast("Errors") },
        .{ .id = element.elementId("act"), .role = .button, .ns_role = "AXButton", .rotor_group = @constCast("Actions") },
        .{ .id = element.elementId("err2"), .role = .generic, .ns_role = "AXGroup", .rotor_group = @constCast("Errors") },
        .{ .id = element.elementId("plain"), .role = .button, .ns_role = "AXButton" },
    };
    var groups: [max_author_rotor_groups][]const u8 = undefined;
    const count = collectAuthorRotorGroups(&nodes, &groups);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("Errors", groups[0]);
    try std.testing.expectEqualStrings("Actions", groups[1]);
}

test "author rotor search matches group labels and filters" {
    const nodes = [_]StoredNode{
        .{ .id = element.elementId("err1"), .role = .generic, .ns_role = "AXGroup", .title = @constCast("Missing name"), .rotor_group = @constCast("Errors") },
        .{ .id = element.elementId("act"), .role = .button, .ns_role = "AXButton", .title = @constCast("Save"), .rotor_group = @constCast("Actions") },
        .{ .id = element.elementId("err2"), .role = .generic, .ns_role = "AXGroup", .title = @constCast("Invalid email"), .rotor_group = @constCast("Errors") },
    };

    try std.testing.expectEqual(@as(?usize, 0), findAuthorRotorCandidate(&nodes, "Errors", null, .next, ""));
    try std.testing.expectEqual(@as(?usize, 2), findAuthorRotorCandidate(&nodes, "Errors", 0, .next, ""));
    try std.testing.expectEqual(@as(?usize, 2), findAuthorRotorCandidate(&nodes, "Errors", null, .next, "email"));
    try std.testing.expectEqual(@as(?usize, null), findAuthorRotorCandidate(&nodes, "Errors", null, .next, "Save"));
    try std.testing.expectEqual(@as(?usize, 1), findAuthorRotorCandidate(&nodes, "Actions", null, .previous, ""));
}

test "AppKit author rotor objects search by custom label" {
    const ns_object = objc.objc_getClass("NSObject") orelse return error.SkipZigTest;
    const test_class = objc.objc_allocateClassPair(ns_object, "ZgpuiAuthorRotorTestView", 0) orelse
        return error.SkipZigTest;
    registerViewAccessibilityIvar(test_class);
    registerViewAccessibilityMethods(test_class);
    objc.objc_registerClassPair(test_class);

    const alloc = msgClassId(test_class, sel("alloc"));
    try std.testing.expect(alloc != null);
    const view = msgId(alloc, sel("init"));
    try std.testing.expect(view != null);
    defer msgRelease(view);

    var store = Store.init(std.testing.allocator);
    defer store.deinit();
    const nodes = [_]a11y.Node{
        .{ .id = element.elementId("err1"), .role = .generic, .name = .{ .label = "Missing name" }, .rotor_group = "Errors" },
        .{ .id = element.elementId("save"), .role = .button, .name = .{ .label = "Save" } },
        .{ .id = element.elementId("err2"), .role = .generic, .name = .{ .label = "Invalid email" }, .rotor_group = "Errors" },
    };
    _ = try store.syncFromNodes(&nodes, 480, null);
    _ = objc.object_setInstanceVariable(view, store_ivar, &store);
    rebuildProxies(view, &store);

    const count: *const fn (objc.id, objc.SEL) callconv(.c) usize = @ptrCast(&objc.objc_msgSend);
    const object_at: *const fn (objc.id, objc.SEL, usize) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);
    const set_integer: *const fn (objc.id, objc.SEL, isize) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    const set_id: *const fn (objc.id, objc.SEL, objc.id) callconv(.c) void = @ptrCast(&objc.objc_msgSend);
    const search: *const fn (objc.id, objc.SEL, objc.id, objc.id) callconv(.c) objc.id = @ptrCast(&objc.objc_msgSend);

    const rotors = msgId(view, sel("accessibilityCustomRotors"));
    try std.testing.expectEqual(@as(usize, 1), count(rotors, sel("count")));

    const errors_rotor = object_at(rotors, sel("objectAtIndex:"), 0);
    try std.testing.expectEqual(appkit_rotor_type_custom, msgGetInteger(errors_rotor, sel("type")));
    try std.testing.expectEqualStrings("Errors", nsStringUtf8(msgId(errors_rotor, sel("label"))).?);

    const parameters_class = objc.objc_getClass("NSAccessibilityCustomRotorSearchParameters") orelse
        return error.SkipZigTest;
    const parameters_alloc = msgClassId(parameters_class, sel("alloc"));
    try std.testing.expect(parameters_alloc != null);
    const parameters = msgId(parameters_alloc, sel("init"));
    try std.testing.expect(parameters != null);
    defer msgRelease(parameters);
    set_integer(parameters, sel("setSearchDirection:"), 1);
    set_id(parameters, sel("setFilterString:"), nsString(""));

    const first = search(view, sel("rotor:resultForSearchParameters:"), errors_rotor, parameters);
    try std.testing.expect(first != null);
    try std.testing.expectEqual(store.nodes.items[0].proxy, msgId(first, sel("targetElement")));

    set_id(parameters, sel("setCurrentItem:"), first);
    const second = search(view, sel("rotor:resultForSearchParameters:"), errors_rotor, parameters);
    try std.testing.expect(second != null);
    try std.testing.expectEqual(store.nodes.items[2].proxy, msgId(second, sel("targetElement")));
}

test "AX proxy class registers modern protocol state getters" {
    ensureAxElementClass();
    try std.testing.expect(objc.class_respondsToSelector(ax_element_class, sel("isAccessibilityEnabled")) != NO);
    try std.testing.expect(objc.class_respondsToSelector(ax_element_class, sel("isAccessibilityFocused")) != NO);
    try std.testing.expect(objc.class_respondsToSelector(ax_element_class, sel("isAccessibilitySelected")) != NO);
    try std.testing.expect(objc.class_respondsToSelector(ax_element_class, sel("isAccessibilityExpanded")) != NO);
    try std.testing.expect(objc.class_respondsToSelector(ax_element_class, sel("isAccessibilityBusy")) != NO);
    try std.testing.expect(objc.class_respondsToSelector(ax_element_class, sel("isAccessibilityRequired")) != NO);
    try std.testing.expect(objc.class_respondsToSelector(ax_element_class, sel("isAccessibilityModal")) != NO);
    try std.testing.expect(objc.class_respondsToSelector(ax_element_class, sel("accessibilityAttributeNames")) != NO);
    try std.testing.expect(objc.class_respondsToSelector(ax_element_class, sel("accessibilityAttributeValue:")) != NO);
    try std.testing.expect(objc.class_respondsToSelector(ax_element_class, sel("accessibilitySubrole")) != NO);
    try std.testing.expect(objc.class_respondsToSelector(ax_element_class, sel("accessibilityHelp")) != NO);
    try std.testing.expect(objc.class_respondsToSelector(ax_element_class, sel("accessibilityPlaceholderValue")) != NO);
    try std.testing.expect(objc.class_respondsToSelector(ax_element_class, sel("accessibilityValueDescription")) != NO);
    try std.testing.expect(objc.class_respondsToSelector(ax_element_class, sel("accessibilityOrientation")) != NO);
    try std.testing.expect(objc.class_respondsToSelector(ax_element_class, sel("accessibilityURL")) != NO);
    try std.testing.expect(objc.class_respondsToSelector(ax_element_class, sel("accessibilityIdentifier")) != NO);
    try std.testing.expect(objc.class_respondsToSelector(ax_element_class, sel("accessibilityLevel")) != NO);
    try std.testing.expect(objc.class_respondsToSelector(ax_element_class, sel("accessibilityPerformShowMenu")) != NO);
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

    _ = try store.syncFromNodes(&nodes, 480, id);
    try std.testing.expectEqual(@as(usize, 1), store.nodes.items.len);
    try std.testing.expectEqual(.button, store.nodes.items[0].role);
    try std.testing.expectEqualStrings("Save", store.nodes.items[0].title.?);
    try std.testing.expectEqual(@as(?usize, 0), store.focused_index);
    try std.testing.expectEqual(id, store.focused_id.?);
}

test "Store syncFromNodes copies heading level and description" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const nodes = [_]a11y.Node{.{
        .id = element.elementId("h2"),
        .role = .heading,
        .name = .{ .label = "Details" },
        .heading_level = 2,
        .description = "Section help",
        .bounds = .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 120, .height = 28 },
        },
    }};

    _ = try store.syncFromNodes(&nodes, 480, null);
    try std.testing.expectEqual(@as(usize, 1), store.nodes.items.len);
    try std.testing.expectEqual(@as(u8, 2), store.nodes.items[0].heading_level.?);
    try std.testing.expectEqualStrings("Section help", store.nodes.items[0].description.?);
}

test "Store syncFromNodes copies busy and required" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const nodes = [_]a11y.Node{.{
        .id = element.elementId("email"),
        .role = .textbox,
        .name = .{ .label = "Email" },
        .busy = true,
        .required = true,
        .bounds = .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 160, .height = 28 },
        },
    }};

    _ = try store.syncFromNodes(&nodes, 480, null);
    try std.testing.expectEqual(@as(usize, 1), store.nodes.items.len);
    try std.testing.expect(store.nodes.items[0].busy);
    try std.testing.expect(store.nodes.items[0].required);
}

test "Store syncFromNodes copies invalid" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const nodes = [_]a11y.Node{.{
        .id = element.elementId("email"),
        .role = .textbox,
        .name = .{ .label = "Email" },
        .invalid = true,
        .description = "Required",
        .bounds = .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 160, .height = 28 },
        },
    }};

    _ = try store.syncFromNodes(&nodes, 480, null);
    try std.testing.expect(store.nodes.items[0].invalid);
    try std.testing.expectEqualStrings("Required", store.nodes.items[0].description.?);
}

test "Store syncFromNodes copies placeholder and value description" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const nodes = [_]a11y.Node{.{
        .id = element.elementId("volume"),
        .role = .slider,
        .name = .{ .label = "Volume" },
        .placeholder = "0–100",
        .value_description = "50 percent",
        .bounds = .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 160, .height = 28 },
        },
    }};

    _ = try store.syncFromNodes(&nodes, 480, null);
    try std.testing.expectEqualStrings("0–100", store.nodes.items[0].placeholder.?);
    try std.testing.expectEqualStrings("50 percent", store.nodes.items[0].value_description.?);
}

test "Store syncFromNodes copies orientation" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const nodes = [_]a11y.Node{.{
        .id = element.elementId("tabs"),
        .role = .tab_list,
        .orientation = .horizontal,
        .bounds = .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 240, .height = 32 },
        },
    }};

    _ = try store.syncFromNodes(&nodes, 480, null);
    try std.testing.expectEqual(a11y.Orientation.horizontal, store.nodes.items[0].orientation.?);
    try std.testing.expectEqual(@as(isize, 2), orientationToNs(store.nodes.items[0].orientation));
    try std.testing.expectEqual(@as(isize, 1), orientationToNs(.vertical));
    try std.testing.expectEqual(@as(isize, 0), orientationToNs(null));
}

test "Store syncFromNodes copies url" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const nodes = [_]a11y.Node{.{
        .id = element.elementId("docs"),
        .role = .link,
        .name = .{ .label = "Docs" },
        .url = "https://example.com/docs",
        .bounds = .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 80, .height = 20 },
        },
    }};

    _ = try store.syncFromNodes(&nodes, 480, null);
    try std.testing.expectEqualStrings("https://example.com/docs", store.nodes.items[0].url.?);
}

test "Store syncFromNodes copies identifier" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const nodes = [_]a11y.Node{.{
        .id = element.elementId("save"),
        .role = .button,
        .name = .{ .label = "Save" },
        .identifier = "save",
        .bounds = .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 64, .height = 28 },
        },
    }};

    _ = try store.syncFromNodes(&nodes, 480, null);
    try std.testing.expectEqualStrings("save", store.nodes.items[0].identifier.?);
}

test "Store syncFromNodes copies modal" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const nodes = [_]a11y.Node{.{
        .id = element.elementId("confirm"),
        .role = .dialog,
        .name = .{ .label = "Confirm" },
        .modal = true,
        .bounds = .{
            .origin = .{ .x = 40, .y = 40 },
            .size = .{ .width = 240, .height = 120 },
        },
    }};

    _ = try store.syncFromNodes(&nodes, 480, null);
    try std.testing.expect(store.nodes.items[0].modal);
}

test "Store syncFromNodes diffs structure and keeps proxies on value-only updates" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const field_id = element.elementId("email");
    const first = [_]a11y.Node{.{
        .id = field_id,
        .role = .textbox,
        .name = .{ .label = "Email" },
        .value_text = "a",
        .bounds = .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 160, .height = 28 },
        },
    }};
    const first_outcome = try store.syncFromNodes(&first, 480, null);
    try std.testing.expect(first_outcome.structure_changed);
    store.nodes.items[0].proxy = @ptrFromInt(0x10);

    const value_only = [_]a11y.Node{.{
        .id = field_id,
        .role = .textbox,
        .name = .{ .label = "Email" },
        .value_text = "ab",
        .bounds = .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = 160, .height = 28 },
        },
    }};
    const value_outcome = try store.syncFromNodes(&value_only, 480, null);
    try std.testing.expect(!value_outcome.structure_changed);
    try std.testing.expectEqualStrings("ab", store.nodes.items[0].value_text.?);
    try std.testing.expectEqual(@as(objc.id, @ptrFromInt(0x10)), store.nodes.items[0].proxy);

    const with_child = [_]a11y.Node{
        .{
            .id = field_id,
            .role = .textbox,
            .name = .{ .label = "Email" },
            .value_text = "ab",
        },
        .{
            .id = element.elementId("hint"),
            .role = .label,
            .name = .{ .label = "Required" },
            .parent_id = field_id,
        },
    };
    const child_outcome = try store.syncFromNodes(&with_child, 480, null);
    try std.testing.expect(child_outcome.structure_changed);
    try std.testing.expectEqual(@as(usize, 2), store.nodes.items.len);
    try std.testing.expectEqual(@as(objc.id, @ptrFromInt(0x10)), store.nodes.items[0].proxy);
    // Fake proxy must not be released by deinit.
    store.nodes.items[0].proxy = null;
}

test "Store syncFromNodes owns live announcement state" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    var value = [_]u8{ 'S', 'a', 'v', 'e', 'd' };
    const nodes = [_]a11y.Node{.{
        .id = element.elementId("toast"),
        .role = .tooltip,
        .name = .{ .label = "Fallback" },
        .value_text = value[0..],
        .live = .assertive,
    }};

    _ = try store.syncFromNodes(&nodes, 480, null);
    try std.testing.expectEqual(@as(usize, 1), store.nodes.items.len);
    try std.testing.expectEqual(a11y.LivePriority.assertive, store.nodes.items[0].live.?);
    try std.testing.expectEqualStrings("Saved", announcementText(&store.nodes.items[0]).?);

    value[0] = 'X';
    try std.testing.expectEqualStrings("Saved", announcementText(&store.nodes.items[0]).?);
}

test "Store syncFromNodes resolves inverse labels" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const field_id = element.elementId("notes");
    const nodes = [_]a11y.Node{
        .{ .id = field_id, .role = .textarea },
        .{ .id = element.elementId("notes-label"), .role = .label, .name = .{ .label = "Notes" }, .label_for = field_id },
    };

    _ = try store.syncFromNodes(&nodes, 480, null);
    try std.testing.expectEqualStrings("Notes", store.nodes.items[0].title.?);
}

test "byteOffsetToUtf16 counts BMP and surrogate pairs" {
    try std.testing.expectEqual(@as(usize, 0), byteOffsetToUtf16("hi", 0));
    try std.testing.expectEqual(@as(usize, 2), utf16Length("hi"));
    // U+1F600 😀 is one codepoint / two UTF-16 units / four UTF-8 bytes.
    const emoji = "a😀b";
    try std.testing.expectEqual(@as(usize, 1), byteOffsetToUtf16(emoji, 1));
    try std.testing.expectEqual(@as(usize, 3), byteOffsetToUtf16(emoji, 5));
    try std.testing.expectEqual(@as(usize, 4), utf16Length(emoji));
}

test "utf16OffsetToByte round-trips BMP and emoji spans" {
    const emoji = "a😀b";
    try std.testing.expectEqual(@as(?usize, 0), utf16OffsetToByte(emoji, 0));
    try std.testing.expectEqual(@as(?usize, 1), utf16OffsetToByte(emoji, 1));
    try std.testing.expectEqual(@as(?usize, 5), utf16OffsetToByte(emoji, 3));
    try std.testing.expectEqual(@as(?usize, 6), utf16OffsetToByte(emoji, 4));
    try std.testing.expectEqual(@as(?usize, null), utf16OffsetToByte(emoji, 2));
    try std.testing.expectEqual(@as(?usize, null), utf16OffsetToByte(emoji, 5));
}

test "utf16RangeToByte rejects overflow and non-boundary ranges" {
    const emoji = "a😀b";
    const valid = utf16RangeToByte(emoji, .{ .location = 1, .length = 2 }).?;
    try std.testing.expectEqual(@as(usize, 1), valid.start);
    try std.testing.expectEqual(@as(usize, 5), valid.end);
    try std.testing.expect(utf16RangeToByte(emoji, .{ .location = 2, .length = 0 }) == null);
    try std.testing.expect(utf16RangeToByte(emoji, .{ .location = 4, .length = 1 }) == null);
    try std.testing.expect(utf16RangeToByte(emoji, .{
        .location = std.math.maxInt(usize),
        .length = 1,
    }) == null);
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

test "nodeSupportsSetValue requires an enabled editable text role" {
    var node = StoredNode{
        .id = element.elementId("name"),
        .role = .textbox,
        .ns_role = "AXTextField",
        .editable = true,
    };
    try std.testing.expect(nodeSupportsSetValue(&node));

    node.disabled = true;
    try std.testing.expect(!nodeSupportsSetValue(&node));
    node.disabled = false;
    node.editable = false;
    try std.testing.expect(!nodeSupportsSetValue(&node));
    node.editable = true;
    node.role = .label;
    try std.testing.expect(!nodeSupportsSetValue(&node));
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
