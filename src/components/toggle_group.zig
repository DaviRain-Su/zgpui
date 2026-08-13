//! Headless toggle group (compound parts): single- or multi-select toggle
//! buttons with arrow-key navigation when the list is focused.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const value_mod = @import("../value.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const a11y_mod = @import("../a11y.zig");

pub const Mode = enum {
    single,
    multi,
};

pub const ToggleGroupState = struct {
    /// Bit i set means toggle i is pressed.
    selected_mask: u32 = 0,
};

pub const Value = value_mod.FieldValue(ToggleGroupState, "selected_mask");

pub const ToggleStyleState = struct {
    pressed: bool = false,
    hovered: bool = false,
    focused_list: bool = false,
    focus_visible: bool = false,
    disabled: bool = false,
};

pub const ToggleStyleFn = *const fn (state: ToggleStyleState) style_mod.Style;

pub fn selectedMask(app: *App, value: Value) u32 {
    return value.get(app);
}

pub fn isPressed(app: *App, value: Value, index: usize) bool {
    if (index >= 32) return false;
    const mask = selectedMask(app, value);
    return (mask & (@as(u32, 1) << @intCast(index))) != 0;
}

fn focusIndex(app: *App, value: Value, toggle_count: usize) usize {
    const mask = selectedMask(app, value);
    var i: usize = 0;
    while (i < toggle_count and i < 32) : (i += 1) {
        if ((mask & (@as(u32, 1) << @intCast(i))) != 0) return i;
    }
    return 0;
}

fn setMask(app: *App, value: Value, mask: u32) void {
    const current = selectedMask(app, value);
    if (current == mask) return;
    value.set(app, mask);
}

fn toggleAt(app: *App, value: Value, mode: Mode, index: usize) void {
    if (index >= 32) return;
    const bit = @as(u32, 1) << @intCast(index);
    var mask = selectedMask(app, value);
    switch (mode) {
        .single => {
            if (mask & bit != 0) {
                mask = 0;
            } else {
                mask = bit;
            }
        },
        .multi => {
            mask ^= bit;
        },
    }
    setMask(app, value, mask);
}

fn moveFocus(app: *App, value: Value, mode: Mode, toggle_count: usize, delta: i32) void {
    if (toggle_count == 0) return;
    const current = focusIndex(app, value, toggle_count);
    const next: usize = switch (delta) {
        -1 => (current + toggle_count - 1) % toggle_count,
        else => (current + 1) % toggle_count,
    };
    if (mode == .single) {
        setMask(app, value, @as(u32, 1) << @intCast(next));
    } else {
        toggleAt(app, value, .multi, next);
    }
}

// ---------------------------------------------------------------------------
// List (owns arrow-key navigation)
// ---------------------------------------------------------------------------

pub const ListProps = struct {
    id: []const u8,
    value: Value,
    mode: Mode = .single,
    toggle_count: usize,
};

const ListNav = struct {
    app: *App,
    value: Value,
    mode: Mode,
    toggle_count: usize,

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *ListNav = @ptrCast(@alignCast(ctx.?));
        if (self.toggle_count == 0) return false;
        switch (event.key) {
            .right, .down => moveFocus(self.app, self.value, self.mode, self.toggle_count, 1),
            .left, .up => moveFocus(self.app, self.value, self.mode, self.toggle_count, -1),
            .home => {
                if (self.mode == .single) {
                    setMask(self.app, self.value, 1);
                } else {
                    toggleAt(self.app, self.value, .multi, 0);
                }
            },
            .end => {
                const last = self.toggle_count - 1;
                if (self.mode == .single) {
                    setMask(self.app, self.value, @as(u32, 1) << @intCast(last));
                } else {
                    toggleAt(self.app, self.value, .multi, last);
                }
            },
            else => return false,
        }
        return true;
    }
};

/// Focusable container for toggle buttons; handles arrow/home/end navigation.
pub fn list(arena: std.mem.Allocator, app: *App, props: ListProps) *Div {
    const focus_id: element.FocusId = element.elementId(props.id);

    const nav = arena.create(ListNav) catch @panic("frame arena OOM");
    nav.* = .{
        .app = app,
        .value = props.value,
        .mode = props.mode,
        .toggle_count = props.toggle_count,
    };

    return div_mod.div(arena)
        .withId(props.id)
        .flexRow()
        .role(.list)
        .a11yOrientation(.horizontal)
        .focusable(focus_id, .{ .ctx = nav, .func = ListNav.onKey });
}

// ---------------------------------------------------------------------------
// Toggle button
// ---------------------------------------------------------------------------

pub const ToggleProps = struct {
    id: []const u8,
    value: Value,
    index: usize,
    list_id: []const u8,
    mode: Mode = .single,
    disabled: bool = false,
    style_fn: ?ToggleStyleFn = null,
};

const ToggleActivate = struct {
    app: *App,
    value: Value,
    index: usize,
    mode: Mode,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *ToggleActivate = @ptrCast(@alignCast(ctx.?));
        toggleAt(self.app, self.value, self.mode, self.index);
    }
};

pub fn toggle(arena: std.mem.Allocator, app: *App, input: *const element.InputState, props: ToggleProps) *Div {
    const id = element.elementId(props.id);

    const list_focus_id = element.elementId(props.list_id);
    const state = ToggleStyleState{
        .pressed = isPressed(app, props.value, props.index),
        .hovered = input.isHovered(id),
        .focused_list = input.isFocused(list_focus_id),
        .focus_visible = input.focus_visible and input.isFocused(list_focus_id),
        .disabled = props.disabled,
    };

    var d = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.button)
        .a11yChecked(state.pressed);
    if (props.disabled) d = d.a11yDisabled(true);
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    }

    if (!props.disabled) {
        const activate = arena.create(ToggleActivate) catch @panic("frame arena OOM");
        activate.* = .{
            .app = app,
            .value = props.value,
            .index = props.index,
            .mode = props.mode,
        };
        d = d.onClick(activate, ToggleActivate.onClick);
    }

    return d;
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const ToggleFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(ToggleGroupState) = undefined,
    controlled_mask: ?u32 = null,
    mode: Mode = .single,

    const toggle_names = [_][]const u8{ "tog-a", "tog-b", "tog-c" };

    fn toggleStyle(state: ToggleStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 50 };
        s.height = .{ .px = 30 };
        s.background = if (state.pressed) color.Rgba.fromHex(0xffffff) else color.Rgba.fromHex(0x444444);
        return s;
    }

    fn currentValue(self: *ToggleFixture) Value {
        return if (self.controlled_mask) |mask|
            .{ .controlled = mask }
        else
            .{ .uncontrolled = self.state };
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *ToggleFixture = @ptrCast(@alignCast(ctx.?));
        const app = &harness.app;
        const value = self.currentValue();

        var group = list(arena, app, .{
            .id = "toggle-list",
            .value = value,
            .mode = self.mode,
            .toggle_count = toggle_names.len,
        });
        for (toggle_names, 0..) |name, i| {
            group = group.childDiv(toggle(arena, app, &harness.input, .{
                .id = name,
                .value = value,
                .index = i,
                .list_id = "toggle-list",
                .mode = self.mode,
                .style_fn = toggleStyle,
            }));
        }

        return div_mod.div(arena)
            .sizePx(250, 80)
            .childDiv(group)
            .any();
    }
};

test "toggle group exposes list orientation and pressed buttons" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 250, .height = 80 });
    defer harness.deinit();

    var fixture = ToggleFixture{ .harness = &harness, .mode = .single };
    fixture.state = try harness.app.new(ToggleGroupState, .{ .selected_mask = 1 << 1 });
    try harness.setRoot(&fixture, ToggleFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.list, harness.a11yRole("toggle-list").?);
    try std.testing.expectEqual(a11y_mod.Orientation.horizontal, harness.a11yNode("toggle-list").?.orientation.?);
    try std.testing.expectEqual(a11y_mod.Role.button, harness.a11yRole("tog-a").?);
    try std.testing.expect(!harness.a11yChecked("tog-a").?);
    try std.testing.expect(harness.a11yChecked("tog-b").?);
}

test "single-select toggle group selects exclusively on click" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 250, .height = 80 });
    defer harness.deinit();

    var fixture = ToggleFixture{ .harness = &harness, .mode = .single };
    fixture.state = try harness.app.new(ToggleGroupState, .{});
    try harness.setRoot(&fixture, ToggleFixture.render);

    try harness.clickOn("tog-b");
    try std.testing.expect(isPressed(&harness.app, fixture.currentValue(), 1));
    try std.testing.expect(!isPressed(&harness.app, fixture.currentValue(), 0));

    try harness.clickOn("tog-c");
    try std.testing.expect(isPressed(&harness.app, fixture.currentValue(), 2));
    try std.testing.expect(!isPressed(&harness.app, fixture.currentValue(), 1));
}

test "single-select clicking active toggle deselects" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 250, .height = 80 });
    defer harness.deinit();

    var fixture = ToggleFixture{ .harness = &harness, .mode = .single };
    fixture.state = try harness.app.new(ToggleGroupState, .{ .selected_mask = 1 << 1 });
    try harness.setRoot(&fixture, ToggleFixture.render);

    try harness.clickOn("tog-b");
    try std.testing.expectEqual(@as(u32, 0), selectedMask(&harness.app, fixture.currentValue()));
}

test "multi-select toggle group allows multiple pressed" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 250, .height = 80 });
    defer harness.deinit();

    var fixture = ToggleFixture{ .harness = &harness, .mode = .multi };
    fixture.state = try harness.app.new(ToggleGroupState, .{});
    try harness.setRoot(&fixture, ToggleFixture.render);

    try harness.clickOn("tog-a");
    try harness.clickOn("tog-c");
    try std.testing.expect(isPressed(&harness.app, fixture.currentValue(), 0));
    try std.testing.expect(!isPressed(&harness.app, fixture.currentValue(), 1));
    try std.testing.expect(isPressed(&harness.app, fixture.currentValue(), 2));
}

test "arrow keys navigate toggles when list focused" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 250, .height = 80 });
    defer harness.deinit();

    var fixture = ToggleFixture{ .harness = &harness, .mode = .single };
    fixture.state = try harness.app.new(ToggleGroupState, .{ .selected_mask = 1 });
    try harness.setRoot(&fixture, ToggleFixture.render);

    try harness.focusById(element.elementId("toggle-list"));
    try harness.keyDown(.right);
    try std.testing.expect(isPressed(&harness.app, fixture.currentValue(), 1));
}

test "controlled toggle group reports intent without updating itself" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 250, .height = 80 });
    defer harness.deinit();

    var fixture = ToggleFixture{ .harness = &harness, .mode = .single, .controlled_mask = 1 };
    fixture.state = try harness.app.new(ToggleGroupState, .{});
    try harness.setRoot(&fixture, ToggleFixture.render);

    try harness.clickOn("tog-b");
    try harness.renderFrame();

    try std.testing.expectEqual(@as(u32, 1), fixture.controlled_mask.?);
    try std.testing.expect(isPressed(&harness.app, fixture.currentValue(), 0));
    try std.testing.expect(!isPressed(&harness.app, fixture.currentValue(), 1));
}
