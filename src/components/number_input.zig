//! Headless number input: click-to-focus, arrow keys and +/- adjust by step,
//! optional min/max clamping. Uses `Value(i64)` for crisp integer keyboard steps.

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

/// Controlled/uncontrolled numeric value (`i64` for exact step/min/max semantics).
pub const Value = value_mod.Value(i64);

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, value: i64) void,
};

pub const StyleState = struct {
    value: i64 = 0,
    hovered: bool = false,
    focused: bool = false,
    focus_visible: bool = false,
    disabled: bool = false,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    value: Value,
    min: ?i64 = null,
    max: ?i64 = null,
    step: i64 = 1,
    disabled: bool = false,
    on_change: ?ChangeHandler = null,
    style_fn: ?StyleFn = null,
};

pub fn clampValue(value: i64, min: ?i64, max: ?i64) i64 {
    var v = value;
    if (min) |m| v = @max(v, m);
    if (max) |m| v = @min(v, m);
    return v;
}

pub fn readValue(app: *App, value: Value, min: ?i64, max: ?i64) i64 {
    return clampValue(value.get(app), min, max);
}

const Control = struct {
    app: *App,
    input: *element.InputState,
    value: Value,
    min: ?i64,
    max: ?i64,
    step: i64,
    on_change: ?ChangeHandler,
    focus_id: element.FocusId,

    fn currentValue(self: *Control) i64 {
        return readValue(self.app, self.value, self.min, self.max);
    }

    fn setValue(self: *Control, next: i64) void {
        const clamped = clampValue(next, self.min, self.max);
        if (self.currentValue() == clamped and self.value.get(self.app) == clamped) return;
        _ = self.value.setIfUncontrolled(self.app, clamped);
        if (self.on_change) |handler| handler.func(handler.ctx, clamped);
    }

    fn nudge(self: *Control, delta: i64) void {
        self.setValue(self.currentValue() + delta);
    }

    fn onMouseDown(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *Control = @ptrCast(@alignCast(ctx.?));
        self.input.focus(self.focus_id);
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *Control = @ptrCast(@alignCast(ctx.?));
        const delta: i64 = switch (event.key) {
            .up, .equal => self.step,
            .down, .minus => -self.step,
            else => return false,
        };
        self.nudge(delta);
        return true;
    }
};

pub fn numberInput(
    arena: std.mem.Allocator,
    app: *App,
    input: *element.InputState,
    props: Props,
) *Div {
    const id = element.elementId(props.id);
    const focus_id: element.FocusId = id;
    const value = readValue(app, props.value, props.min, props.max);

    var d = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.slider)
        .a11yOrientation(.vertical);
    const value_text = std.fmt.allocPrint(arena, "{d}", .{value}) catch @panic("frame arena OOM");
    d = d.a11yValueText(value_text);
    const min_f: f64 = if (props.min) |m| @floatFromInt(m) else @floatFromInt(value - 100);
    const max_f: f64 = if (props.max) |m| @floatFromInt(m) else @floatFromInt(value + 100);
    d = d.a11yNumeric(@floatFromInt(value), min_f, max_f);
    d = d.a11yValueDescription(value_text);
    if (props.disabled) d = d.a11yDisabled(true);
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(.{
            .value = value,
            .hovered = input.isHovered(id),
            .focused = input.isFocused(focus_id),
            .focus_visible = input.focus_visible and input.isFocused(focus_id),
            .disabled = props.disabled,
        }));
    }

    if (!props.disabled) {
        const control = arena.create(Control) catch @panic("frame arena OOM");
        control.* = .{
            .app = app,
            .input = input,
            .value = props.value,
            .min = props.min,
            .max = props.max,
            .step = props.step,
            .on_change = props.on_change,
            .focus_id = focus_id,
        };

        d = d.onMouseDown(control, Control.onMouseDown)
            .focusable(focus_id, .{ .ctx = control, .func = Control.onKey });
    }

    return d;
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const NumberInputFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(Value.Store) = undefined,
    controlled_value: ?i64 = null,
    min: ?i64 = null,
    max: ?i64 = null,
    step: i64 = 1,
    disabled: bool = false,
    change_log: std.ArrayList(i64) = .empty,

    fn deinit(self: *NumberInputFixture) void {
        self.change_log.deinit(std.testing.allocator);
    }

    fn onChange(ctx: ?*anyopaque, value: i64) void {
        const self: *NumberInputFixture = @ptrCast(@alignCast(ctx.?));
        self.change_log.append(std.testing.allocator, value) catch unreachable;
    }

    fn styleFor(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 80 };
        s.height = .{ .px = 32 };
        s.background = if (state.value > 0)
            color.Rgba.fromHex(0x00aa00)
        else
            color.Rgba.fromHex(0x333333);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *NumberInputFixture = @ptrCast(@alignCast(ctx.?));
        const value: Value = if (self.controlled_value) |v|
            .{ .controlled = v }
        else
            .{ .uncontrolled = self.state };

        const root = div_mod.div(arena)
            .sizePx(200, 100)
            .padPx(20)
            .childDiv(numberInput(arena, &harness.app, &harness.input, .{
                .id = "the-number",
                .value = value,
                .min = self.min,
                .max = self.max,
                .step = self.step,
                .disabled = self.disabled,
                .on_change = .{ .ctx = self, .func = onChange },
                .style_fn = styleFor,
            }));
        return root.any();
    }
};

test "number input exposes slider numeric a11y" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 100 });
    defer harness.deinit();

    var fixture = NumberInputFixture{ .harness = &harness, .min = 0, .max = 100 };
    defer fixture.deinit();
    fixture.state = try harness.app.new(Value.Store, .{ .value = 42 });
    try harness.setRoot(&fixture, NumberInputFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.slider, harness.a11yRole("the-number").?);
    try std.testing.expectEqual(a11y_mod.Orientation.vertical, harness.a11yNode("the-number").?.orientation.?);
    try std.testing.expectEqual(@as(f64, 42), harness.a11yNode("the-number").?.numeric_value.?);
    try std.testing.expectEqual(@as(f64, 0), harness.a11yNode("the-number").?.min_value.?);
    try std.testing.expectEqual(@as(f64, 100), harness.a11yNode("the-number").?.max_value.?);
    try std.testing.expectEqualStrings("42", harness.a11yNode("the-number").?.value_text.?);
}

test "click focuses number input" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 100 });
    defer harness.deinit();

    var fixture = NumberInputFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(Value.Store, .{ .value = 0 });
    try harness.setRoot(&fixture, NumberInputFixture.render);

    try harness.clickOn("the-number");
    try std.testing.expect(harness.input.isFocused(element.elementId("the-number")));
}

test "arrow keys adjust value by step" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 100 });
    defer harness.deinit();

    var fixture = NumberInputFixture{ .harness = &harness, .step = 5 };
    defer fixture.deinit();
    fixture.state = try harness.app.new(Value.Store, .{ .value = 10 });
    try harness.setRoot(&fixture, NumberInputFixture.render);

    try harness.focusById(element.elementId("the-number"));
    try harness.keyDown(.up);
    try std.testing.expectEqual(@as(i64, 15), harness.app.read(Value.Store, fixture.state).value);
    try harness.keyDown(.down);
    try std.testing.expectEqual(@as(i64, 10), harness.app.read(Value.Store, fixture.state).value);
}

test "plus and minus keys adjust value" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 100 });
    defer harness.deinit();

    var fixture = NumberInputFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(Value.Store, .{ .value = 3 });
    try harness.setRoot(&fixture, NumberInputFixture.render);

    try harness.focusById(element.elementId("the-number"));
    try harness.keyDown(.equal);
    try std.testing.expectEqual(@as(i64, 4), harness.app.read(Value.Store, fixture.state).value);
    try harness.keyDown(.minus);
    try std.testing.expectEqual(@as(i64, 3), harness.app.read(Value.Store, fixture.state).value);
}

test "value clamps to min and max" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 100 });
    defer harness.deinit();

    var fixture = NumberInputFixture{ .harness = &harness, .min = 0, .max = 5 };
    defer fixture.deinit();
    fixture.state = try harness.app.new(Value.Store, .{ .value = 5 });
    try harness.setRoot(&fixture, NumberInputFixture.render);

    try harness.focusById(element.elementId("the-number"));
    try harness.keyDown(.up);
    try std.testing.expectEqual(@as(i64, 5), harness.app.read(Value.Store, fixture.state).value);

    harness.app.read(Value.Store, fixture.state).value = 0;
    try harness.keyDown(.down);
    try std.testing.expectEqual(@as(i64, 0), harness.app.read(Value.Store, fixture.state).value);
}

test "disabled number input ignores input" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 100 });
    defer harness.deinit();

    var fixture = NumberInputFixture{ .harness = &harness, .disabled = true };
    defer fixture.deinit();
    fixture.state = try harness.app.new(Value.Store, .{ .value = 0 });
    try harness.setRoot(&fixture, NumberInputFixture.render);

    try harness.clickOn("the-number");
    try std.testing.expect(!harness.input.isFocused(element.elementId("the-number")));
    try std.testing.expectEqual(@as(usize, 0), fixture.change_log.items.len);
}

test "controlled number input reports intent without self-updating" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 100 });
    defer harness.deinit();

    var fixture = NumberInputFixture{ .harness = &harness, .controlled_value = 2 };
    defer fixture.deinit();
    try harness.setRoot(&fixture, NumberInputFixture.render);

    try harness.focusById(element.elementId("the-number"));
    try harness.keyDown(.up);
    try harness.renderFrame();
    try std.testing.expectEqual(@as(i64, 2), fixture.controlled_value.?);
    try std.testing.expect(fixture.change_log.items.len > 0);
    try std.testing.expectEqual(@as(i64, 3), fixture.change_log.items[fixture.change_log.items.len - 1]);
}
