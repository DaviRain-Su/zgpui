//! Headless tree view (compound parts): flat `Node` list with parent indices,
//! `tree` container (keyboard navigation among visible nodes), and `treeItem`
//! rows with chevron expand + row select.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const value_mod = @import("../value.zig");

const Div = div_mod.Div;
const App = app_mod.App;

pub const Node = struct {
    id: []const u8,
    parent: ?usize = null,
    disabled: bool = false,
};

/// Bounded expanded-node set (max 32). Copyable for controlled `Value(TreeState)`.
pub const ExpandedSet = struct {
    ids: [32]u64 = [_]u64{0} ** 32,
    count: u8 = 0,

    pub fn contains(self: ExpandedSet, id: u64) bool {
        for (self.ids[0..self.count]) |entry| {
            if (entry == id) return true;
        }
        return false;
    }

    pub fn insert(self: *ExpandedSet, id: u64) bool {
        if (self.contains(id)) return true;
        if (self.count >= 32) return false;
        self.ids[self.count] = id;
        self.count += 1;
        return true;
    }

    pub fn remove(self: *ExpandedSet, id: u64) void {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.ids[i] == id) {
                self.ids[i] = self.ids[self.count - 1];
                self.count -= 1;
                return;
            }
        }
    }

    pub fn toggle(self: *ExpandedSet, id: u64) void {
        if (self.contains(id)) self.remove(id) else _ = self.insert(id);
    }
};

pub const TreeState = struct {
    selected_id: ?u64 = null,
    expanded: ExpandedSet = .{},

    pub fn isExpanded(self: *const TreeState, node_id: u64) bool {
        return self.expanded.contains(node_id);
    }

    pub fn setExpanded(self: *TreeState, node_id: u64, open: bool) void {
        if (open) _ = self.expanded.insert(node_id) else self.expanded.remove(node_id);
    }

    pub fn toggleExpanded(self: *TreeState, node_id: u64) void {
        self.expanded.toggle(node_id);
    }
};

pub const StateValue = value_mod.Value(TreeState);

/// Bitmask expand state for small fixed trees (max 32 nodes by index).
pub const ExpandedMaskValue = value_mod.MaskValue(u32);

pub const ChangeEvent = enum {
    select,
    expand,
    collapse,
};

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, event: ChangeEvent, node_id: u64) void,
};

pub const StyleState = struct {
    depth: usize = 0,
    expanded: bool = false,
    selected: bool = false,
    hovered: bool = false,
    focused: bool = false,
    focus_visible: bool = false,
    has_children: bool = false,
    disabled: bool = false,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;

pub fn nodeHash(id: []const u8) u64 {
    return element.elementId(id);
}

pub fn hasChildren(nodes: []const Node, index: usize) bool {
    for (nodes) |node| {
        if (node.parent == index) return true;
    }
    return false;
}

pub fn depth(nodes: []const Node, index: usize) usize {
    var d: usize = 0;
    var current = index;
    while (nodes[current].parent) |parent| {
        d += 1;
        current = parent;
    }
    return d;
}

pub fn isSelected(state: *const TreeState, node_id: u64) bool {
    return state.selected_id == node_id;
}

pub fn isExpanded(state: *const TreeState, node_id: u64) bool {
    return state.isExpanded(node_id);
}

pub fn parentIndex(nodes: []const Node, index: usize) ?usize {
    return nodes[index].parent;
}

pub fn firstChildIndex(nodes: []const Node, index: usize) ?usize {
    for (nodes, 0..) |node, i| {
        if (node.parent == index) return i;
    }
    return null;
}

fn appendVisibleSubtree(
    nodes: []const Node,
    state: *const TreeState,
    index: usize,
    out: []usize,
) usize {
    out[0] = index;
    var count: usize = 1;
    if (!state.isExpanded(nodeHash(nodes[index].id))) return count;
    for (nodes, 0..) |_, i| {
        if (nodes[i].parent == index) {
            count += appendVisibleSubtree(nodes, state, i, out[count..]);
        }
    }
    return count;
}

/// Returns the number of visible node indices written to `out` (pre-order).
pub fn collectVisible(nodes: []const Node, state: *const TreeState, out: []usize) usize {
    var count: usize = 0;
    for (nodes, 0..) |_, i| {
        if (nodes[i].parent == null) {
            count += appendVisibleSubtree(nodes, state, i, out[count..]);
        }
    }
    return count;
}

pub fn isNodeVisible(nodes: []const Node, state: *const TreeState, index: usize) bool {
    var current = index;
    while (nodes[current].parent) |parent| {
        if (!state.isExpanded(nodeHash(nodes[parent].id))) return false;
        current = parent;
    }
    return true;
}

pub fn indentStyle(depth_level: usize, indent_px: f32) style_mod.Style {
    var s = style_mod.Style{};
    s.padding = .{
        .top = .zero,
        .right = .zero,
        .bottom = .zero,
        .left = .{ .px = @as(f32, @floatFromInt(depth_level)) * indent_px },
    };
    return s;
}

fn selectNode(
    app: *App,
    value: StateValue,
    node_id: u64,
    on_change: ?ChangeHandler,
) void {
    const current = value.get(app);
    if (current.selected_id == node_id) return;
    if (value == .controlled) {
        if (on_change) |handler| handler.func(handler.ctx, .select, node_id);
        return;
    }
    var next = current;
    next.selected_id = node_id;
    value.set(app, next);
    if (on_change) |handler| handler.func(handler.ctx, .select, node_id);
}

fn setExpandedNode(
    app: *App,
    value: StateValue,
    node_id: u64,
    open: bool,
    on_change: ?ChangeHandler,
) void {
    const current = value.get(app);
    if (current.isExpanded(node_id) == open) return;
    if (value == .controlled) {
        if (on_change) |handler| {
            handler.func(handler.ctx, if (open) .expand else .collapse, node_id);
        }
        return;
    }
    var next = current;
    next.setExpanded(node_id, open);
    value.set(app, next);
    if (on_change) |handler| {
        handler.func(handler.ctx, if (open) .expand else .collapse, node_id);
    }
}

fn toggleExpandedNode(
    app: *App,
    value: StateValue,
    node_id: u64,
    on_change: ?ChangeHandler,
) void {
    const current = value.get(app);
    setExpandedNode(app, value, node_id, !current.isExpanded(node_id), on_change);
}

// ---------------------------------------------------------------------------
// Tree container (keyboard navigation)
// ---------------------------------------------------------------------------

pub const TreeProps = struct {
    id: []const u8,
    nodes: []const Node,
    state: StateValue,
    on_change: ?ChangeHandler = null,
};

const TreeNav = struct {
    app: *App,
    nodes: []const Node,
    state: StateValue,
    on_change: ?ChangeHandler,
    visible: [64]usize = undefined,

    fn visibleCount(self: *TreeNav) usize {
        var state = self.state.get(self.app);
        return collectVisible(self.nodes, &state, &self.visible);
    }

    fn nodeIndexFromSelected(self: *TreeNav) ?usize {
        const selected = self.state.get(self.app).selected_id orelse return null;
        for (self.nodes, 0..) |node, i| {
            if (nodeHash(node.id) == selected) return i;
        }
        return null;
    }

    fn visibleIndexOf(self: *TreeNav, node_index: usize) ?usize {
        const count = self.visibleCount();
        for (self.visible[0..count], 0..) |idx, vi| {
            if (idx == node_index) return vi;
        }
        return null;
    }

    fn selectNodeIndex(self: *TreeNav, node_index: usize) void {
        selectNode(self.app, self.state, nodeHash(self.nodes[node_index].id), self.on_change);
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *TreeNav = @ptrCast(@alignCast(ctx.?));
        const count = self.visibleCount();
        if (count == 0) return false;

        const current_index = self.nodeIndexFromSelected() orelse self.visible[0];

        switch (event.key) {
            .down => {
                const current_vi = self.visibleIndexOf(current_index) orelse 0;
                const next_vi = @min(current_vi + 1, count - 1);
                self.selectNodeIndex(self.visible[next_vi]);
                return true;
            },
            .up => {
                const current_vi = self.visibleIndexOf(current_index) orelse 0;
                const next_vi = if (current_vi > 0) current_vi - 1 else 0;
                self.selectNodeIndex(self.visible[next_vi]);
                return true;
            },
            .left => {
                const id = nodeHash(self.nodes[current_index].id);
                const state = self.state.get(self.app);
                if (hasChildren(self.nodes, current_index) and state.isExpanded(id)) {
                    setExpandedNode(self.app, self.state, id, false, self.on_change);
                } else if (parentIndex(self.nodes, current_index)) |parent| {
                    self.selectNodeIndex(parent);
                }
                return true;
            },
            .right => {
                const id = nodeHash(self.nodes[current_index].id);
                const state = self.state.get(self.app);
                if (hasChildren(self.nodes, current_index)) {
                    if (!state.isExpanded(id)) {
                        setExpandedNode(self.app, self.state, id, true, self.on_change);
                    } else if (firstChildIndex(self.nodes, current_index)) |child| {
                        self.selectNodeIndex(child);
                    }
                }
                return true;
            },
            .enter, .space => {
                const id = nodeHash(self.nodes[current_index].id);
                selectNode(self.app, self.state, id, self.on_change);
                if (hasChildren(self.nodes, current_index)) {
                    toggleExpandedNode(self.app, self.state, id, self.on_change);
                }
                return true;
            },
            else => return false,
        }
    }
};

/// Focusable tree container. Add visible `treeItem` rows as children.
pub fn tree(arena: std.mem.Allocator, app: *App, props: TreeProps) *Div {
    const focus_id: element.FocusId = element.elementId(props.id);

    const nav = arena.create(TreeNav) catch @panic("frame arena OOM");
    nav.* = .{
        .app = app,
        .nodes = props.nodes,
        .state = props.state,
        .on_change = props.on_change,
    };

    return div_mod.div(arena)
        .withId(props.id)
        .flexCol()
        .wFull()
        .role(.tree)
        .focusable(focus_id, .{ .ctx = nav, .func = TreeNav.onKey });
}

// ---------------------------------------------------------------------------
// Tree item row
// ---------------------------------------------------------------------------

pub const TreeItemProps = struct {
    id: []const u8,
    chevron_id: ?[]const u8 = null,
    node_index: usize,
    nodes: []const Node,
    state: StateValue,
    tree_id: []const u8,
    indent_px: f32 = 16,
    disabled: bool = false,
    on_change: ?ChangeHandler = null,
    style_fn: ?StyleFn = null,
};

const ItemAction = struct {
    app: *App,
    state: StateValue,
    node_id: u64,
    on_change: ?ChangeHandler,

    fn select(self: *ItemAction) void {
        selectNode(self.app, self.state, self.node_id, self.on_change);
    }

    fn toggleExpand(self: *ItemAction) void {
        toggleExpandedNode(self.app, self.state, self.node_id, self.on_change);
    }
};

const RowSelect = struct {
    action: *ItemAction,
    has_children: bool,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *RowSelect = @ptrCast(@alignCast(ctx.?));
        self.action.select();
        if (self.has_children) self.action.toggleExpand();
    }
};

const ChevronToggle = struct {
    action: *ItemAction,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *ChevronToggle = @ptrCast(@alignCast(ctx.?));
        self.action.toggleExpand();
    }
};

/// Interactive tree row with chevron (expand) and selectable body.
pub fn treeItem(
    arena: std.mem.Allocator,
    app: *App,
    input: *const element.InputState,
    props: TreeItemProps,
) *Div {
    const node = props.nodes[props.node_index];
    const node_id = nodeHash(node.id);
    const state_snapshot = props.state.get(app);
    const disabled = props.disabled or node.disabled;
    const children = hasChildren(props.nodes, props.node_index);
    const expanded = state_snapshot.isExpanded(node_id);
    const selected = state_snapshot.selected_id == node_id;

    const row_id = element.elementId(props.id);
    const chevron_name = props.chevron_id orelse blk: {
        break :blk std.fmt.allocPrint(arena, "{s}-chevron", .{props.id}) catch @panic("frame arena OOM");
    };
    const chevron_element_id = element.elementId(chevron_name);

    const tree_focus_id = element.elementId(props.tree_id);
    const style_state = StyleState{
        .depth = depth(props.nodes, props.node_index),
        .expanded = expanded,
        .selected = selected,
        .hovered = input.isHovered(row_id) or input.isHovered(chevron_element_id),
        .focused = input.isFocused(tree_focus_id),
        .focus_visible = input.focus_visible and input.isFocused(tree_focus_id),
        .has_children = children,
        .disabled = disabled,
    };

    var row = div_mod.div(arena)
        .withId(props.id)
        .flexRow()
        .itemsCenter()
        .wFull()
        .withStyle(indentStyle(style_state.depth, props.indent_px))
        .role(.tree_item)
        .a11ySelected(selected)
        .a11yExpanded(if (children) expanded else null)
        .interactive();
    if (disabled) {
        row = row.a11yDisabled(true);
    }

    if (props.style_fn) |style_fn| {
        row = row.withStyle(style_fn(style_state));
    }

    var chevron = div_mod.div(arena)
        .withId(chevron_name)
        .sizePx(20, 28);
    if (children and !disabled) {
        const action = arena.create(ItemAction) catch @panic("frame arena OOM");
        action.* = .{
            .app = app,
            .state = props.state,
            .node_id = node_id,
            .on_change = props.on_change,
        };
        const toggle = arena.create(ChevronToggle) catch @panic("frame arena OOM");
        toggle.* = .{ .action = action };
        chevron = chevron.interactive().onClick(toggle, ChevronToggle.onClick);
    }

    row = row.childDiv(chevron);

    if (!disabled) {
        const action = arena.create(ItemAction) catch @panic("frame arena OOM");
        action.* = .{
            .app = app,
            .state = props.state,
            .node_id = node_id,
            .on_change = props.on_change,
        };
        const select_ctx = arena.create(RowSelect) catch @panic("frame arena OOM");
        select_ctx.* = .{ .action = action, .has_children = children };
        row = row.onClick(select_ctx, RowSelect.onClick);
    }

    return row;
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const demo_nodes = [_]Node{
    .{ .id = "root-a", .parent = null },
    .{ .id = "child-a1", .parent = 0 },
    .{ .id = "child-a2", .parent = 0 },
    .{ .id = "grand-a1", .parent = 1 },
    .{ .id = "root-b", .parent = null },
    .{ .id = "child-b1", .parent = 4 },
};

const TreeFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(StateValue.Store) = undefined,
    controlled_state: ?TreeState = null,
    change_log: std.ArrayList(struct { event: ChangeEvent, node_id: u64 }) = .empty,

    fn deinit(self: *TreeFixture) void {
        self.change_log.deinit(std.testing.allocator);
    }

    fn onChange(ctx: ?*anyopaque, event: ChangeEvent, node_id: u64) void {
        const self: *TreeFixture = @ptrCast(@alignCast(ctx.?));
        self.change_log.append(std.testing.allocator, .{ .event = event, .node_id = node_id }) catch unreachable;
    }

    fn currentValue(self: *TreeFixture) StateValue {
        return if (self.controlled_state) |s|
            .{ .controlled = s }
        else
            .{ .uncontrolled = self.state };
    }

    fn itemStyle(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.height = .{ .px = 28 };
        s.background = if (state.selected) color.Rgba.fromHex(0xffffff) else color.Rgba.fromHex(0x444444);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *TreeFixture = @ptrCast(@alignCast(ctx.?));
        const app = &harness.app;
        const value = self.currentValue();
        var state_copy = value.get(app);

        var visible: [64]usize = undefined;
        const count = collectVisible(&demo_nodes, &state_copy, &visible);

        var root = tree(arena, app, .{
            .id = "tree",
            .nodes = &demo_nodes,
            .state = value,
            .on_change = .{ .ctx = self, .func = onChange },
        });

        for (visible[0..count]) |node_index| {
            root = root.childDiv(treeItem(arena, app, &harness.input, .{
                .id = demo_nodes[node_index].id,
                .node_index = node_index,
                .nodes = &demo_nodes,
                .state = value,
                .tree_id = "tree",
                .on_change = .{ .ctx = self, .func = onChange },
                .style_fn = itemStyle,
            }));
        }

        return div_mod.div(arena)
            .sizePx(240, 400)
            .childDiv(root)
            .any();
    }
};

test "clicking row selects node" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 240, .height = 400 });
    defer harness.deinit();

    var fixture = TreeFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(StateValue.Store, .{ .value = .{} });
    try harness.setRoot(&fixture, TreeFixture.render);

    try harness.clickOn("root-b");
    const state = &harness.app.read(StateValue.Store, fixture.state).value;
    try std.testing.expectEqual(nodeHash("root-b"), state.selected_id.?);
}

test "clicking chevron expands without showing collapsed children" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 240, .height = 400 });
    defer harness.deinit();

    var fixture = TreeFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(StateValue.Store, .{ .value = .{} });
    try harness.setRoot(&fixture, TreeFixture.render);

    try std.testing.expect(harness.hitboxBounds(element.elementId("child-a1")) == null);

    try harness.clickOn("root-a-chevron");
    try std.testing.expect(harness.app.read(StateValue.Store, fixture.state).value.isExpanded(nodeHash("root-a")));
    try std.testing.expect(harness.hitboxBounds(element.elementId("child-a1")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("child-a2")) != null);
}

test "clicking row selects and toggles expand" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 240, .height = 400 });
    defer harness.deinit();

    var fixture = TreeFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(StateValue.Store, .{ .value = .{} });
    try harness.setRoot(&fixture, TreeFixture.render);

    try harness.clickOn("root-a");
    const state = &harness.app.read(StateValue.Store, fixture.state).value;
    try std.testing.expectEqual(nodeHash("root-a"), state.selected_id.?);
    try std.testing.expect(state.isExpanded(nodeHash("root-a")));
    try std.testing.expect(harness.hitboxBounds(element.elementId("child-a1")) != null);
}

test "keyboard down moves selection among visible nodes" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 240, .height = 400 });
    defer harness.deinit();

    var fixture = TreeFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(StateValue.Store, .{ .value = .{ .selected_id = nodeHash("root-a") } });
    {
        const store = harness.app.read(StateValue.Store, fixture.state);
        store.value.setExpanded(nodeHash("root-a"), true);
        harness.app.notify(fixture.state.id);
    }
    try harness.setRoot(&fixture, TreeFixture.render);

    try harness.focusById(element.elementId("tree"));
    try harness.keyDown(.down);
    try std.testing.expectEqual(nodeHash("child-a1"), harness.app.read(StateValue.Store, fixture.state).value.selected_id.?);

    try harness.keyDown(.down);
    try std.testing.expectEqual(nodeHash("child-a2"), harness.app.read(StateValue.Store, fixture.state).value.selected_id.?);
}

test "keyboard right expands; left collapses or moves to parent" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 240, .height = 400 });
    defer harness.deinit();

    var fixture = TreeFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(StateValue.Store, .{ .value = .{ .selected_id = nodeHash("root-a") } });
    try harness.setRoot(&fixture, TreeFixture.render);

    try harness.focusById(element.elementId("tree"));
    try harness.keyDown(.right);
    try std.testing.expect(harness.app.read(StateValue.Store, fixture.state).value.isExpanded(nodeHash("root-a")));

    try harness.keyDown(.down);
    try std.testing.expectEqual(nodeHash("child-a1"), harness.app.read(StateValue.Store, fixture.state).value.selected_id.?);

    try harness.keyDown(.left);
    try std.testing.expect(harness.app.read(StateValue.Store, fixture.state).value.isExpanded(nodeHash("root-a")));
    try std.testing.expectEqual(nodeHash("root-a"), harness.app.read(StateValue.Store, fixture.state).value.selected_id.?);

    try harness.keyDown(.left);
    try std.testing.expect(!harness.app.read(StateValue.Store, fixture.state).value.isExpanded(nodeHash("root-a")));
    try std.testing.expectEqual(nodeHash("root-a"), harness.app.read(StateValue.Store, fixture.state).value.selected_id.?);
}

test "controlled tree reports intent without updating itself" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 240, .height = 400 });
    defer harness.deinit();

    var fixture = TreeFixture{ .harness = &harness, .controlled_state = .{} };
    defer fixture.deinit();
    fixture.state = try harness.app.new(StateValue.Store, .{ .value = .{} });
    try harness.setRoot(&fixture, TreeFixture.render);

    try harness.clickOn("root-a");
    try harness.renderFrame();

    try std.testing.expect(fixture.controlled_state.?.selected_id == null);
    try std.testing.expect(fixture.change_log.items.len >= 1);
    try std.testing.expectEqual(.select, fixture.change_log.items[0].event);
    try std.testing.expectEqual(nodeHash("root-a"), fixture.change_log.items[0].node_id);
}

test "collectVisible respects expansion" {
    var state: TreeState = .{};

    var visible: [64]usize = undefined;
    const collapsed = collectVisible(&demo_nodes, &state, &visible);
    try std.testing.expectEqual(@as(usize, 2), collapsed);
    try std.testing.expectEqual(@as(usize, 0), visible[0]);
    try std.testing.expectEqual(@as(usize, 4), visible[1]);

    state.setExpanded(nodeHash("root-a"), true);
    const expanded = collectVisible(&demo_nodes, &state, &visible);
    try std.testing.expectEqual(@as(usize, 4), expanded);
}

test "depth helper" {
    try std.testing.expectEqual(@as(usize, 0), depth(&demo_nodes, 0));
    try std.testing.expectEqual(@as(usize, 1), depth(&demo_nodes, 1));
    try std.testing.expectEqual(@as(usize, 2), depth(&demo_nodes, 3));
}
