//! Headless checkbox group (compound parts): multiple checkboxes sharing a
//! multi-select bitmask (`selected_mask` on `CheckboxGroupState`).

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const value_mod = @import("../value.zig");

const Div = div_mod.Div;
const App = app_mod.App;

pub const CheckboxGroupState = struct {
    selected_mask: u32 = 0,
};

pub const Value = value_mod.FieldValue(CheckboxGroupState, "selected_mask");

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, mask: u32) void,
};

pub const ItemStyleState = struct {
    checked: bool = false,
    hovered: bool = false,
    focused: bool = false,
    focus_visible: bool = false,
    disabled: bool = false,
};

pub const ItemStyleFn = *const fn (state: ItemStyleState) style_mod.Style;

pub fn selectedMask(app: *App, value: Value) u32 {
    return value.get(app);
}

pub fn isChecked(app: *App, value: Value, index: usize) bool {
    if (index >= 32) return false;
    const mask = selectedMask(app, value);
    return (mask & (@as(u32, 1) << @intCast(index))) != 0;
}

fn setMask(app: *App, value: Value, mask: u32, on_change: ?ChangeHandler) void {
    const current = selectedMask(app, value);
    if (current == mask) return;
    _ = value.setIfUncontrolled(app, mask);
    if (on_change) |handler| handler.func(handler.ctx, mask);
}

fn toggleAt(app: *App, value: Value, index: usize, on_change: ?ChangeHandler) void {
    if (index >= 32) return;
    const bit = @as(u32, 1) << @intCast(index);
    const mask = selectedMask(app, value) ^ bit;
    setMask(app, value, mask, on_change);
}

// ---------------------------------------------------------------------------
// Group container
// ---------------------------------------------------------------------------

pub const GroupProps = struct {
    id: []const u8,
    disabled: bool = false,
};

/// Vertical or horizontal container for checkbox items.
pub fn group(arena: std.mem.Allocator, props: GroupProps) *Div {
    var d = div_mod.div(arena)
        .withId(props.id)
        .flexCol();
    if (props.disabled) {
        d = d.a11yDisabled(true);
    }
    return d;
}

// ---------------------------------------------------------------------------
// Checkbox item
// ---------------------------------------------------------------------------

pub const ItemProps = struct {
    id: []const u8,
    value: Value,
    index: usize,
    disabled: bool = false,
    on_change: ?ChangeHandler = null,
    style_fn: ?ItemStyleFn = null,
};

const ItemToggle = struct {
    app: *App,
    value: Value,
    index: usize,
    on_change: ?ChangeHandler,

    fn activate(self: *ItemToggle) void {
        toggleAt(self.app, self.value, self.index, self.on_change);
    }

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *ItemToggle = @ptrCast(@alignCast(ctx.?));
        self.activate();
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        if (event.key != .space and event.key != .enter) return false;
        const self: *ItemToggle = @ptrCast(@alignCast(ctx.?));
        self.activate();
        return true;
    }
};

pub fn item(arena: std.mem.Allocator, app: *App, input: *const element.InputState, props: ItemProps) *Div {
    const id = element.elementId(props.id);
    const focus_id: element.FocusId = id;
    const checked = isChecked(app, props.value, props.index);
    const disabled = props.disabled;

    const state = ItemStyleState{
        .checked = checked,
        .hovered = input.isHovered(id),
        .focused = input.isFocused(focus_id),
        .focus_visible = input.focus_visible and input.isFocused(focus_id),
        .disabled = disabled,
    };

    var d = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.checkbox)
        .a11yChecked(checked);
    if (disabled) {
        d = d.a11yDisabled(true);
    }
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    }

    if (!disabled) {
        const toggle = arena.create(ItemToggle) catch @panic("frame arena OOM");
        toggle.* = .{
            .app = app,
            .value = props.value,
            .index = props.index,
            .on_change = props.on_change,
        };
        d = d.onClick(toggle, ItemToggle.onClick)
            .focusable(focus_id, .{ .ctx = toggle, .func = ItemToggle.onKey });
    }

    return d;
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const CheckboxGroupFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(CheckboxGroupState) = undefined,
    controlled_mask: ?u32 = null,
    group_disabled: bool = false,
    change_log: std.ArrayList(u32) = .empty,

    const item_names = [_][]const u8{ "cb-a", "cb-b", "cb-c" };

    fn deinit(self: *CheckboxGroupFixture) void {
        self.change_log.deinit(std.testing.allocator);
    }

    fn onChange(ctx: ?*anyopaque, mask: u32) void {
        const self: *CheckboxGroupFixture = @ptrCast(@alignCast(ctx.?));
        self.change_log.append(std.testing.allocator, mask) catch unreachable;
    }

    fn itemStyle(state: ItemStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 24 };
        s.height = .{ .px = 24 };
        s.background = if (state.checked) color.Rgba.fromHex(0x00aa00) else color.Rgba.fromHex(0xdddddd);
        return s;
    }

    fn currentValue(self: *CheckboxGroupFixture) Value {
        return if (self.controlled_mask) |mask|
            .{ .controlled = mask }
        else
            .{ .uncontrolled = self.state };
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *CheckboxGroupFixture = @ptrCast(@alignCast(ctx.?));
        const app = &harness.app;
        const value = self.currentValue();

        var container = group(arena, .{
            .id = "checkbox-group",
            .disabled = self.group_disabled,
        });
        for (item_names, 0..) |name, i| {
            container = container.childDiv(item(arena, app, &harness.input, .{
                .id = name,
                .value = value,
                .index = i,
                .disabled = self.group_disabled,
                .on_change = .{ .ctx = self, .func = onChange },
                .style_fn = itemStyle,
            }));
        }

        return div_mod.div(arena)
            .sizePx(200, 120)
            .childDiv(container)
            .any();
    }
};

test "checkbox group allows multi select" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 120 });
    defer harness.deinit();

    var fixture = CheckboxGroupFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(CheckboxGroupState, .{});
    try harness.setRoot(&fixture, CheckboxGroupFixture.render);

    try harness.clickOn("cb-a");
    try harness.clickOn("cb-c");
    try std.testing.expect(isChecked(&harness.app, fixture.currentValue(), 0));
    try std.testing.expect(!isChecked(&harness.app, fixture.currentValue(), 1));
    try std.testing.expect(isChecked(&harness.app, fixture.currentValue(), 2));
    try std.testing.expectEqual(@as(u32, (1 << 0) | (1 << 2)), selectedMask(&harness.app, fixture.currentValue()));

    try harness.clickOn("cb-a");
    try std.testing.expect(!isChecked(&harness.app, fixture.currentValue(), 0));
    try std.testing.expectEqual(@as(u32, 1 << 2), selectedMask(&harness.app, fixture.currentValue()));
}

test "checkbox group controlled mode reports intent without updating itself" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 120 });
    defer harness.deinit();

    var fixture = CheckboxGroupFixture{ .harness = &harness, .controlled_mask = 0 };
    defer fixture.deinit();
    fixture.state = try harness.app.new(CheckboxGroupState, .{});
    try harness.setRoot(&fixture, CheckboxGroupFixture.render);

    try harness.clickOn("cb-b");
    try harness.renderFrame();

    try std.testing.expect(!isChecked(&harness.app, fixture.currentValue(), 1));
    try std.testing.expectEqualSlices(u32, &.{1 << 1}, fixture.change_log.items);
}

test "checkbox group toggles via keyboard" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 120 });
    defer harness.deinit();

    var fixture = CheckboxGroupFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(CheckboxGroupState, .{});
    try harness.setRoot(&fixture, CheckboxGroupFixture.render);

    try harness.focusById(element.elementId("cb-b"));
    try harness.keyDown(.space);
    try std.testing.expect(isChecked(&harness.app, fixture.currentValue(), 1));
}

test "disabled checkbox group does not toggle" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 120 });
    defer harness.deinit();

    var fixture = CheckboxGroupFixture{ .harness = &harness, .group_disabled = true };
    defer fixture.deinit();
    fixture.state = try harness.app.new(CheckboxGroupState, .{});
    try harness.setRoot(&fixture, CheckboxGroupFixture.render);

    try harness.clickOn("cb-a");
    try std.testing.expectEqual(@as(u32, 0), selectedMask(&harness.app, fixture.currentValue()));
    try std.testing.expectEqual(@as(usize, 0), fixture.change_log.items.len);
}
