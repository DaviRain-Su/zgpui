//! Headless accessibility semantics: roles, names, and states collected
//! each frame for tests and future platform accessibility trees.

const std = @import("std");
const geometry = @import("geometry.zig");
const element = @import("element.zig");

const Pixels = geometry.Pixels;
const Bounds = geometry.Bounds;

pub const Role = enum {
    none,
    button,
    checkbox,
    switch_control,
    radio,
    slider,
    tab,
    tab_list,
    dialog,
    menu,
    menu_item,
    textbox,
    textarea,
    search,
    link,
    list,
    list_item,
    tree,
    tree_item,
    progressbar,
    separator,
    img,
    heading,
    label,
    tooltip,
    generic,
};

pub const NameSource = union(enum) {
    none,
    label: []const u8,
    labelled_by: element.ElementId,
};

pub const Node = struct {
    id: element.ElementId,
    role: Role,
    name: NameSource = .none,
    /// Inverse label relationship. A nameless node can resolve its name from
    /// the first node in this frame whose `label_for` targets its id.
    label_for: ?element.ElementId = null,
    value_text: ?[]const u8 = null,
    checked: ?bool = null,
    selected: ?bool = null,
    disabled: bool = false,
    expanded: ?bool = null,
    /// Whether this node has a concrete press handler in the current frame.
    pressable: bool = false,
    /// Whether this node has concrete increment/decrement handling this frame.
    adjustable: bool = false,
    /// Whether AX can replace the value (enabled text roles with an editor).
    editable: bool = false,
    /// UTF-8 caret offset for textbox / textarea / search.
    caret: ?usize = null,
    /// UTF-8 selection range `[selection_start, selection_end)` when set.
    selection_start: ?usize = null,
    selection_end: ?usize = null,
    /// Numeric value for sliders / progress / meters.
    numeric_value: ?f64 = null,
    min_value: ?f64 = null,
    max_value: ?f64 = null,
    /// Parent accessibility node id when nested; null = root of the tree.
    parent_id: ?element.ElementId = null,
    bounds: Bounds(Pixels) = .{},
};

/// Selected substring from `value_text` when a selection range is present.
pub fn selectedText(node: *const Node) ?[]const u8 {
    const value = node.value_text orelse return null;
    const start = node.selection_start orelse return null;
    const end = node.selection_end orelse return null;
    if (end <= start or end > value.len or start > value.len) return null;
    if (start == end) return null;
    return value[start..end];
}

/// True when the role exposes editable text semantics.
pub fn roleIsText(role: Role) bool {
    return switch (role) {
        .textbox, .textarea, .search => true,
        else => false,
    };
}

/// True when the role supports AXIncrement / AXDecrement.
pub fn roleSupportsAdjust(role: Role) bool {
    return role == .slider;
}

/// Resolved accessible name when `name` is `.label`; null for `.none` /
/// unresolved `.labelled_by`. Prefer `resolveNameIn` when a node list is available.
pub fn resolveName(node: *const Node) ?[]const u8 {
    return switch (node.name) {
        .none, .labelled_by => null,
        .label => |text| text,
    };
}

/// Resolve a name inside one frame. Explicit labels win; `labelled_by` chains
/// and inverse `label_for` relationships are followed recursively. The node
/// count bounds traversal, so missing targets and cycles resolve to null.
pub fn resolveNameIn(nodes: []const Node, node: *const Node) ?[]const u8 {
    return resolveNameInDepth(nodes, node, nodes.len);
}

fn resolveNameInDepth(nodes: []const Node, node: *const Node, remaining: usize) ?[]const u8 {
    return switch (node.name) {
        .label => |text| text,
        .labelled_by => |id| blk: {
            if (remaining == 0) break :blk null;
            for (nodes) |*other| {
                if (other.id == id) {
                    break :blk resolveNameInDepth(nodes, other, remaining - 1);
                }
            }
            break :blk null;
        },
        .none => blk: {
            if (remaining == 0) break :blk null;
            for (nodes) |*other| {
                if (other.label_for == node.id) {
                    if (resolveNameInDepth(nodes, other, remaining - 1)) |name| {
                        break :blk name;
                    }
                }
            }
            break :blk null;
        },
    };
}

/// Same as `resolveNameIn` over a frame's a11y list.
pub fn resolveNameInFrame(frame: *const element.FrameState, node: *const Node) ?[]const u8 {
    return resolveNameIn(frame.a11y.items, node);
}

/// Append focusable element ids that also appear in the a11y tree, in tab order.
pub fn collectFocusOrder(
    frame: *const element.FrameState,
    out: *std.ArrayList(element.ElementId),
    allocator: std.mem.Allocator,
) !void {
    for (frame.focusables.items) |focusable| {
        if (findById(frame, focusable.id) != null) {
            try out.append(allocator, focusable.id);
        }
    }
}

pub fn findById(frame: *const element.FrameState, id: element.ElementId) ?*const Node {
    for (frame.a11y.items) |*node| {
        if (node.id == id) return node;
    }
    return null;
}

/// First node with the given role (document order).
pub fn findByRole(frame: *const element.FrameState, role: Role) ?*const Node {
    for (frame.a11y.items) |*node| {
        if (node.role == role) return node;
    }
    return null;
}

/// Append pointers to every node with `role` (document order).
pub fn collectByRole(
    frame: *const element.FrameState,
    role: Role,
    out: *std.ArrayList(*const Node),
    allocator: std.mem.Allocator,
) !void {
    for (frame.a11y.items) |*node| {
        if (node.role == role) try out.append(allocator, node);
    }
}

/// Append child nodes whose `parent_id` equals `parent`.
pub fn collectChildren(
    nodes: []const Node,
    parent: element.ElementId,
    out: *std.ArrayList(*const Node),
    allocator: std.mem.Allocator,
) !void {
    for (nodes) |*node| {
        if (node.parent_id) |pid| {
            if (pid == parent) try out.append(allocator, node);
        }
    }
}

/// Root nodes (`parent_id == null`) in document order.
pub fn collectRoots(
    nodes: []const Node,
    out: *std.ArrayList(*const Node),
    allocator: std.mem.Allocator,
) !void {
    for (nodes) |*node| {
        if (node.parent_id == null) try out.append(allocator, node);
    }
}

test "selectedText returns UTF-8 slice within selection" {
    const node = Node{
        .id = element.elementId("field"),
        .role = .textbox,
        .value_text = "hello",
        .selection_start = 1,
        .selection_end = 4,
    };
    try std.testing.expectEqualStrings("ell", selectedText(&node).?);

    var empty = node;
    empty.selection_end = 1;
    try std.testing.expect(selectedText(&empty) == null);

    var unicode = node;
    unicode.value_text = "aé😀b";
    unicode.selection_start = 1;
    unicode.selection_end = 7;
    try std.testing.expectEqualStrings("é😀", selectedText(&unicode).?);

    unicode.selection_end = 99;
    try std.testing.expect(selectedText(&unicode) == null);
}

test "text and adjustable role helpers are narrow" {
    try std.testing.expect(roleIsText(.textbox));
    try std.testing.expect(roleIsText(.textarea));
    try std.testing.expect(roleIsText(.search));
    try std.testing.expect(!roleIsText(.label));
    try std.testing.expect(roleSupportsAdjust(.slider));
    try std.testing.expect(!roleSupportsAdjust(.progressbar));
}

test "findById and findByRole" {
    var frame = element.FrameState.init(std.testing.allocator);
    defer frame.deinit();

    const id_a = element.elementId("a");
    const id_b = element.elementId("b");
    try frame.registerA11y(.{ .id = id_a, .role = .button, .name = .{ .label = "Save" } });
    try frame.registerA11y(.{ .id = id_b, .role = .checkbox, .checked = true });

    const node_a = findById(&frame, id_a).?;
    try std.testing.expectEqual(.button, node_a.role);
    try std.testing.expectEqualStrings("Save", resolveName(node_a).?);

    const by_role = findByRole(&frame, .checkbox).?;
    try std.testing.expectEqual(id_b, by_role.id);
    try std.testing.expect(by_role.checked.?);
}

test "parent_id hierarchy collectRoots and collectChildren" {
    const id_dialog = element.elementId("dlg");
    const id_ok = element.elementId("ok");
    const nodes = [_]Node{
        .{ .id = id_dialog, .role = .dialog },
        .{ .id = id_ok, .role = .button, .parent_id = id_dialog },
    };

    var roots: std.ArrayList(*const Node) = .empty;
    defer roots.deinit(std.testing.allocator);
    try collectRoots(&nodes, &roots, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), roots.items.len);
    try std.testing.expectEqual(id_dialog, roots.items[0].id);

    var kids: std.ArrayList(*const Node) = .empty;
    defer kids.deinit(std.testing.allocator);
    try collectChildren(&nodes, id_dialog, &kids, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), kids.items.len);
    try std.testing.expectEqual(id_ok, kids.items[0].id);
}

test "resolveNameIn follows chained and inverse label relationships" {
    const id_label = element.elementId("email-label");
    const id_alias = element.elementId("email-alias");
    const id_field = element.elementId("email-field");
    const id_notes_label = element.elementId("notes-label");
    const id_notes = element.elementId("notes");
    const nodes = [_]Node{
        .{ .id = id_label, .role = .label, .name = .{ .label = "Email" } },
        .{ .id = id_alias, .role = .label, .name = .{ .labelled_by = id_label } },
        .{ .id = id_field, .role = .textbox, .name = .{ .labelled_by = id_alias } },
        .{ .id = id_notes_label, .role = .label, .name = .{ .label = "Notes" }, .label_for = id_notes },
        .{ .id = id_notes, .role = .textarea },
    };
    try std.testing.expectEqualStrings("Email", resolveNameIn(&nodes, &nodes[2]).?);
    try std.testing.expectEqualStrings("Notes", resolveNameIn(&nodes, &nodes[4]).?);
    try std.testing.expect(resolveName(&nodes[2]) == null);
}

test "resolveNameIn rejects missing and cyclic references" {
    const id_missing = element.elementId("missing");
    const id_self = element.elementId("self");
    const id_a = element.elementId("cycle-a");
    const id_b = element.elementId("cycle-b");
    const nodes = [_]Node{
        .{ .id = element.elementId("orphan"), .role = .textbox, .name = .{ .labelled_by = id_missing } },
        .{ .id = id_self, .role = .textbox, .name = .{ .labelled_by = id_self } },
        .{ .id = id_a, .role = .label, .name = .{ .labelled_by = id_b } },
        .{ .id = id_b, .role = .label, .name = .{ .labelled_by = id_a } },
    };

    for (&nodes) |*node| try std.testing.expect(resolveNameIn(&nodes, node) == null);
}

test "resolveNameIn prefers an explicit name over inverse labels" {
    const id_field = element.elementId("field");
    const nodes = [_]Node{
        .{ .id = id_field, .role = .textbox, .name = .{ .label = "Explicit" } },
        .{ .id = element.elementId("field-label"), .role = .label, .name = .{ .label = "Inverse" }, .label_for = id_field },
    };

    try std.testing.expectEqualStrings("Explicit", resolveNameIn(&nodes, &nodes[0]).?);
}
