//! Headless radio group (compound parts): mutually exclusive options with
//! arrow-key navigation when the list is focused, click-to-select, and
//! controlled or uncontrolled selection state.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const value_mod = @import("../value.zig");

const Div = div_mod.Div;
const App = app_mod.App;

pub const RadioGroupState = struct {
    selected: usize = 0,
};

pub const Value = value_mod.FieldValue(RadioGroupState, "selected");

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, index: usize) void,
};

pub const RadioStyleState = struct {
    selected: bool = false,
    hovered: bool = false,
    focused_list: bool = false,
    focus_visible: bool = false,
    disabled: bool = false,
};

pub const RadioStyleFn = *const fn (state: RadioStyleState) style_mod.Style;

pub fn selectedIndex(app: *App, value: Value) usize {
    return value.get(app);
}

pub fn isSelected(app: *App, value: Value, index: usize) bool {
    return selectedIndex(app, value) == index;
}

fn select(app: *App, value: Value, index: usize, on_change: ?ChangeHandler) void {
    const current = selectedIndex(app, value);
    if (current == index) return;
    value.set(app, index);
    if (on_change) |handler| handler.func(handler.ctx, index);
}

// ---------------------------------------------------------------------------
// List (owns arrow-key navigation)
// ---------------------------------------------------------------------------

pub const ListProps = struct {
    id: []const u8,
    value: Value,
    option_count: usize,
    disabled: bool = false,
    on_change: ?ChangeHandler = null,
};

const ListNav = struct {
    app: *App,
    value: Value,
    option_count: usize,
    on_change: ?ChangeHandler,

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *ListNav = @ptrCast(@alignCast(ctx.?));
        if (self.option_count == 0) return false;
        const current = selectedIndex(self.app, self.value);
        const next: usize = switch (event.key) {
            .right, .down => (current + 1) % self.option_count,
            .left, .up => (current + self.option_count - 1) % self.option_count,
            .home => 0,
            .end => self.option_count - 1,
            else => return false,
        };
        select(self.app, self.value, next, self.on_change);
        return true;
    }
};

/// Focusable container for radio options; handles arrow/home/end navigation.
pub fn list(arena: std.mem.Allocator, app: *App, props: ListProps) *Div {
    const focus_id: element.FocusId = element.elementId(props.id);

    var d = div_mod.div(arena)
        .withId(props.id)
        .flexRow()
        .role(.radio_group)
        .a11yOrientation(.horizontal);

    if (!props.disabled) {
        const nav = arena.create(ListNav) catch @panic("frame arena OOM");
        nav.* = .{
            .app = app,
            .value = props.value,
            .option_count = props.option_count,
            .on_change = props.on_change,
        };
        d = d.focusable(focus_id, .{ .ctx = nav, .func = ListNav.onKey });
    }

    return d;
}

// ---------------------------------------------------------------------------
// Radio option
// ---------------------------------------------------------------------------

pub const RadioProps = struct {
    id: []const u8,
    value: Value,
    index: usize,
    list_id: []const u8,
    disabled: bool = false,
    on_change: ?ChangeHandler = null,
    style_fn: ?RadioStyleFn = null,
};

const RadioSelect = struct {
    app: *App,
    value: Value,
    index: usize,
    on_change: ?ChangeHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *RadioSelect = @ptrCast(@alignCast(ctx.?));
        select(self.app, self.value, self.index, self.on_change);
    }
};

pub fn radio(arena: std.mem.Allocator, app: *App, input: *const element.InputState, props: RadioProps) *Div {
    const id = element.elementId(props.id);

    const list_focus_id = element.elementId(props.list_id);
    const state = RadioStyleState{
        .selected = isSelected(app, props.value, props.index),
        .hovered = input.isHovered(id),
        .focused_list = input.isFocused(list_focus_id),
        .focus_visible = input.focus_visible and input.isFocused(list_focus_id),
        .disabled = props.disabled,
    };

    var d = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.radio)
        .a11yChecked(state.selected);
    if (props.disabled) {
        d = d.a11yDisabled(true);
    }
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    }

    if (!props.disabled) {
        const select_ctx = arena.create(RadioSelect) catch @panic("frame arena OOM");
        select_ctx.* = .{
            .app = app,
            .value = props.value,
            .index = props.index,
            .on_change = props.on_change,
        };
        d = d.onClick(select_ctx, RadioSelect.onClick);
    }

    return d;
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const RadioFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(RadioGroupState) = undefined,
    controlled_index: ?usize = null,
    disabled: bool = false,
    change_log: std.ArrayList(usize) = .empty,

    const option_names = [_][]const u8{ "opt-a", "opt-b", "opt-c" };

    fn deinit(self: *RadioFixture) void {
        self.change_log.deinit(std.testing.allocator);
    }

    fn onChange(ctx: ?*anyopaque, index: usize) void {
        const self: *RadioFixture = @ptrCast(@alignCast(ctx.?));
        self.change_log.append(std.testing.allocator, index) catch unreachable;
    }

    fn optionStyle(state: RadioStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 40 };
        s.height = .{ .px = 40 };
        s.background = if (state.selected) color.Rgba.fromHex(0xffffff) else color.Rgba.fromHex(0x444444);
        return s;
    }

    fn currentValue(self: *RadioFixture) Value {
        return if (self.controlled_index) |index|
            .{ .controlled = index }
        else
            .{ .uncontrolled = self.state };
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *RadioFixture = @ptrCast(@alignCast(ctx.?));
        const app = &harness.app;
        const value = self.currentValue();

        var group = list(arena, app, .{
            .id = "radio-list",
            .value = value,
            .option_count = option_names.len,
            .disabled = self.disabled,
            .on_change = .{ .ctx = self, .func = onChange },
        });
        for (option_names, 0..) |name, i| {
            group = group.childDiv(radio(arena, app, &harness.input, .{
                .id = name,
                .value = value,
                .index = i,
                .list_id = "radio-list",
                .on_change = .{ .ctx = self, .func = onChange },
                .style_fn = optionStyle,
            }));
        }

        return div_mod.div(arena)
            .sizePx(200, 80)
            .childDiv(group)
            .any();
    }
};

test "clicking a radio option selects it exclusively" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 80 });
    defer harness.deinit();

    var fixture = RadioFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(RadioGroupState, .{});
    try harness.setRoot(&fixture, RadioFixture.render);

    try std.testing.expectEqual(@as(usize, 0), selectedIndex(&harness.app, fixture.currentValue()));

    try harness.clickOn("opt-b");
    try std.testing.expectEqual(@as(usize, 1), selectedIndex(&harness.app, fixture.currentValue()));
    try std.testing.expectEqualSlices(usize, &.{1}, fixture.change_log.items);

    try harness.clickOn("opt-c");
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(&harness.app, fixture.currentValue()));
}

test "arrow keys navigate radios when list focused" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 80 });
    defer harness.deinit();

    var fixture = RadioFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(RadioGroupState, .{});
    try harness.setRoot(&fixture, RadioFixture.render);

    try harness.focusById(element.elementId("radio-list"));
    try harness.keyDown(.right);
    try std.testing.expectEqual(@as(usize, 1), selectedIndex(&harness.app, fixture.currentValue()));
    try harness.keyDown(.left);
    try std.testing.expectEqual(@as(usize, 0), selectedIndex(&harness.app, fixture.currentValue()));
}

test "radio group exposes radio_group role and option checked state" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 80 });
    defer harness.deinit();

    var fixture = RadioFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(RadioGroupState, .{});
    try harness.setRoot(&fixture, RadioFixture.render);

    const a11y_mod = @import("../a11y.zig");
    try std.testing.expectEqual(a11y_mod.Role.radio_group, harness.a11yRole("radio-list").?);
    try std.testing.expectEqual(a11y_mod.Orientation.horizontal, harness.a11yNode("radio-list").?.orientation.?);
    try std.testing.expectEqual(a11y_mod.Role.radio, harness.a11yRole("opt-a").?);
    try std.testing.expect(harness.a11yNode("opt-a").?.checked.?);
    try std.testing.expect(!harness.a11yNode("opt-b").?.checked.?);
}

test "controlled radio reports intent without updating itself" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 80 });
    defer harness.deinit();

    var fixture = RadioFixture{ .harness = &harness, .controlled_index = 0 };
    defer fixture.deinit();
    fixture.state = try harness.app.new(RadioGroupState, .{});
    try harness.setRoot(&fixture, RadioFixture.render);

    try harness.clickOn("opt-b");
    try harness.renderFrame();

    const quads = harness.scene.quads.items;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), quads[0].background.r, 0.001);
    try std.testing.expectEqualSlices(usize, &.{1}, fixture.change_log.items);
}
