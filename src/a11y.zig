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
    value_text: ?[]const u8 = null,
    checked: ?bool = null,
    selected: ?bool = null,
    disabled: bool = false,
    expanded: ?bool = null,
    bounds: Bounds(Pixels) = .{},
};

/// Resolved accessible name when `name` is `.label`; null otherwise.
pub fn resolveName(node: *const Node) ?[]const u8 {
    return switch (node.name) {
        .none, .labelled_by => null,
        .label => |text| text,
    };
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
