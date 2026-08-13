//! Headless tabs component (compound parts), following base-gpui's tabs
//! design: `list` container (owns keyboard navigation), `tab` triggers, and
//! panel visibility helpers. Selection lives in a `TabsState` app entity.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const value_mod = @import("../value.zig");

const Div = div_mod.Div;
const App = app_mod.App;

pub const TabsState = struct {
    selected: usize = 0,
};

pub const Value = value_mod.FieldValue(TabsState, "selected");

pub const TabStyleState = struct {
    selected: bool = false,
    hovered: bool = false,
    focused_list: bool = false,
    focus_visible: bool = false,
    disabled: bool = false,
};

pub const TabStyleFn = *const fn (state: TabStyleState) style_mod.Style;

fn select(app: *App, value: Value, index: usize) void {
    const current = selectedIndex(app, value);
    if (current == index) return;
    value.set(app, index);
}

pub fn selectedIndex(app: *App, value: Value) usize {
    return value.get(app);
}

pub fn isSelected(app: *App, value: Value, index: usize) bool {
    return selectedIndex(app, value) == index;
}

// ---------------------------------------------------------------------------
// List (owns arrow-key navigation, roving selection)
// ---------------------------------------------------------------------------

pub const ListProps = struct {
    id: []const u8,
    value: Value,
    tab_count: usize,
};

const ListNav = struct {
    app: *App,
    value: Value,
    tab_count: usize,

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *ListNav = @ptrCast(@alignCast(ctx.?));
        if (self.tab_count == 0) return false;
        const current = selectedIndex(self.app, self.value);
        const next: usize = switch (event.key) {
            .right, .down => (current + 1) % self.tab_count,
            .left, .up => (current + self.tab_count - 1) % self.tab_count,
            .home => 0,
            .end => self.tab_count - 1,
            else => return false,
        };
        select(self.app, self.value, next);
        return true;
    }
};

/// The tab list container: a focusable row that handles arrow/home/end
/// navigation. Add `tab(...)` divs as children.
pub fn list(arena: std.mem.Allocator, app: *App, props: ListProps) *Div {
    const focus_id: element.FocusId = element.elementId(props.id);

    const nav = arena.create(ListNav) catch @panic("frame arena OOM");
    nav.* = .{ .app = app, .value = props.value, .tab_count = props.tab_count };

    return div_mod.div(arena)
        .withId(props.id)
        .flexRow()
        .role(.tab_list)
        .focusable(focus_id, .{ .ctx = nav, .func = ListNav.onKey });
}

// ---------------------------------------------------------------------------
// Tab trigger
// ---------------------------------------------------------------------------

pub const TabProps = struct {
    id: []const u8,
    value: Value,
    index: usize,
    list_id: []const u8,
    disabled: bool = false,
    style_fn: ?TabStyleFn = null,
};

const TabActivate = struct {
    app: *App,
    value: Value,
    index: usize,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *TabActivate = @ptrCast(@alignCast(ctx.?));
        select(self.app, self.value, self.index);
    }
};

pub fn tab(arena: std.mem.Allocator, app: *App, input: *const element.InputState, props: TabProps) *Div {
    const id = element.elementId(props.id);

    const list_focus_id = element.elementId(props.list_id);
    const state = TabStyleState{
        .selected = isSelected(app, props.value, props.index),
        .hovered = input.isHovered(id),
        .focused_list = input.isFocused(list_focus_id),
        .focus_visible = input.focus_visible and input.isFocused(list_focus_id),
        .disabled = props.disabled,
    };

    var d = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.tab)
        .a11ySelected(state.selected);
    if (props.disabled) {
        d = d.a11yDisabled(true);
    }
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    }

    if (!props.disabled) {
        const activate = arena.create(TabActivate) catch @panic("frame arena OOM");
        activate.* = .{ .app = app, .value = props.value, .index = props.index };
        d = d.onClick(activate, TabActivate.onClick);
    }

    return d;
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const a11y_mod = @import("../a11y.zig");
const color = @import("../color.zig");

const TabsFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(TabsState) = undefined,
    controlled_index: ?usize = null,

    const tab_names = [_][]const u8{ "tab-a", "tab-b", "tab-c" };

    fn tabStyle(state: TabStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 60 };
        s.height = .{ .px = 30 };
        s.background = if (state.selected) color.Rgba.fromHex(0xffffff) else color.Rgba.fromHex(0x444444);
        return s;
    }

    fn currentValue(self: *TabsFixture) Value {
        return if (self.controlled_index) |index|
            .{ .controlled = index }
        else
            .{ .uncontrolled = self.state };
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *TabsFixture = @ptrCast(@alignCast(ctx.?));
        const app = &harness.app;
        const value = self.currentValue();

        var tab_list = list(arena, app, .{
            .id = "tabs-list",
            .value = value,
            .tab_count = tab_names.len,
        });
        for (tab_names, 0..) |name, i| {
            tab_list = tab_list.childDiv(tab(arena, app, &harness.input, .{
                .id = name,
                .value = value,
                .index = i,
                .list_id = "tabs-list",
                .style_fn = tabStyle,
            }));
        }

        // A "panel" per tab; only the selected one is rendered.
        const selected = selectedIndex(app, value);
        const panel = div_mod.div(arena)
            .withId(if (selected == 0) "panel-a" else if (selected == 1) "panel-b" else "panel-c")
            .interactive()
            .wFull()
            .hPx(100)
            .bg(color.Rgba.fromHex(0x222222));

        const root = div_mod.div(arena)
            .flexCol()
            .sizePx(300, 200)
            .childDiv(tab_list)
            .childDiv(panel);
        return root.any();
    }
};

test "clicking a tab selects it and switches panels" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TabsFixture{ .harness = &harness };
    fixture.state = try harness.app.new(TabsState, .{});
    try harness.setRoot(&fixture, TabsFixture.render);

    // Initially tab 0 selected, panel-a present.
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(&harness.app, fixture.currentValue()));
    try std.testing.expect(harness.hitboxBounds(element.elementId("panel-a")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("panel-b")) == null);

    try harness.clickOn("tab-b");
    try std.testing.expectEqual(@as(usize, 1), selectedIndex(&harness.app, fixture.currentValue()));
    try std.testing.expect(harness.hitboxBounds(element.elementId("panel-b")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("panel-a")) == null);
}

test "arrow keys navigate tabs when list focused, wrapping at edges" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TabsFixture{ .harness = &harness };
    fixture.state = try harness.app.new(TabsState, .{});
    try harness.setRoot(&fixture, TabsFixture.render);

    try harness.focusById(element.elementId("tabs-list"));

    try harness.keyDown(.right);
    try std.testing.expectEqual(@as(usize, 1), selectedIndex(&harness.app, fixture.currentValue()));
    try harness.keyDown(.right);
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(&harness.app, fixture.currentValue()));
    try harness.keyDown(.right); // wraps
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(&harness.app, fixture.currentValue()));
    try harness.keyDown(.left); // wraps backward
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(&harness.app, fixture.currentValue()));
    try harness.keyDown(.home);
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(&harness.app, fixture.currentValue()));
    try harness.keyDown(.end);
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(&harness.app, fixture.currentValue()));
}

test "tab list focus_visible tracks keyboard focus" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TabsFixture{ .harness = &harness };
    fixture.state = try harness.app.new(TabsState, .{});
    try harness.setRoot(&fixture, TabsFixture.render);

    const list_focus_id = element.elementId("tabs-list");

    try harness.focusById(list_focus_id);
    try std.testing.expect(harness.input.isFocused(list_focus_id));
    try std.testing.expect(harness.input.focus_visible);
}

test "selected tab gets selected style state" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TabsFixture{ .harness = &harness };
    fixture.state = try harness.app.new(TabsState, .{});
    try harness.setRoot(&fixture, TabsFixture.render);

    // Quads: 3 tabs + 1 panel. First tab selected (white), others dark.
    const quads = harness.scene.quads.items;
    try std.testing.expectEqual(@as(usize, 4), quads.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), quads[0].background.r, 0.001);
    try std.testing.expect(quads[1].background.r < 0.5);

    try harness.clickOn("tab-b");
    const quads_after = harness.scene.quads.items;
    try std.testing.expect(quads_after[0].background.r < 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), quads_after[1].background.r, 0.001);
}

test "tabs expose tab_list role and selected tab state" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TabsFixture{ .harness = &harness };
    fixture.state = try harness.app.new(TabsState, .{});
    try harness.setRoot(&fixture, TabsFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.tab_list, harness.a11yRole("tabs-list").?);
    try std.testing.expectEqual(a11y_mod.Role.tab, harness.a11yRole("tab-a").?);
    try std.testing.expect(harness.a11ySelected("tab-a").?);
    try std.testing.expect(!harness.a11ySelected("tab-b").?);

    try harness.clickOn("tab-b");
    try std.testing.expect(!harness.a11ySelected("tab-a").?);
    try std.testing.expect(harness.a11ySelected("tab-b").?);
}

test "controlled tabs report intent without updating themselves" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = TabsFixture{ .harness = &harness, .controlled_index = 0 };
    fixture.state = try harness.app.new(TabsState, .{});
    try harness.setRoot(&fixture, TabsFixture.render);

    try harness.clickOn("tab-b");
    try harness.renderFrame();

    try std.testing.expectEqual(@as(usize, 0), fixture.controlled_index.?);
    try std.testing.expect(harness.hitboxBounds(element.elementId("panel-a")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("panel-b")) == null);
}
