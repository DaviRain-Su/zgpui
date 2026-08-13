//! Headless switch component (binary toggle) with controlled and uncontrolled
//! modes, following base-gpui's switch design.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const value_mod = @import("../value.zig");
const a11y_mod = @import("../a11y.zig");

const Div = div_mod.Div;
const App = app_mod.App;

pub const SwitchState = struct {
    on: bool = false,
};

pub const Value = value_mod.FieldValue(SwitchState, "on");

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, on: bool) void,
};

pub const StyleState = struct {
    on: bool = false,
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,
    focus_visible: bool = false,
    disabled: bool = false,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    value: Value,
    disabled: bool = false,
    on_change: ?ChangeHandler = null,
    style_fn: ?StyleFn = null,
};

const Toggle = struct {
    app: *App,
    value: Value,
    on: bool,
    on_change: ?ChangeHandler,

    fn activate(self: *Toggle) void {
        const next = !self.on;
        self.value.set(self.app, next);
        if (self.on_change) |handler| handler.func(handler.ctx, next);
    }

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *Toggle = @ptrCast(@alignCast(ctx.?));
        self.activate();
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        if (event.key != .space and event.key != .enter) return false;
        const self: *Toggle = @ptrCast(@alignCast(ctx.?));
        self.activate();
        return true;
    }
};

pub fn isOn(app: *App, value: Value) bool {
    return value.get(app);
}

pub fn switchEl(arena: std.mem.Allocator, app: *App, input: *const element.InputState, props: Props) *Div {
    const id = element.elementId(props.id);
    const focus_id: element.FocusId = id;
    const on = isOn(app, props.value);

    const state = StyleState{
        .on = on,
        .hovered = input.isHovered(id),
        .pressed = input.mouse_down_on != null and input.mouse_down_on.? == id,
        .focused = input.isFocused(focus_id),
        .focus_visible = input.focus_visible and input.isFocused(focus_id),
        .disabled = props.disabled,
    };

    var d = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.switch_control)
        .a11yChecked(on);
    if (props.disabled) {
        d = d.a11yDisabled(true);
    }
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    }

    if (!props.disabled) {
        const toggle = arena.create(Toggle) catch @panic("frame arena OOM");
        toggle.* = .{
            .app = app,
            .value = props.value,
            .on = on,
            .on_change = props.on_change,
        };
        d = d.onClick(toggle, Toggle.onClick)
            .focusable(focus_id, .{ .ctx = toggle, .func = Toggle.onKey });
    }

    return d;
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const SwitchFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(SwitchState) = undefined,
    controlled_value: ?bool = null,
    disabled: bool = false,
    change_log: std.ArrayList(bool) = .empty,

    fn deinit(self: *SwitchFixture) void {
        self.change_log.deinit(std.testing.allocator);
    }

    fn onChange(ctx: ?*anyopaque, on: bool) void {
        const self: *SwitchFixture = @ptrCast(@alignCast(ctx.?));
        self.change_log.append(std.testing.allocator, on) catch unreachable;
    }

    fn styleFor(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 40 };
        s.height = .{ .px = 20 };
        s.background = if (state.on) color.Rgba.fromHex(0x00aa00) else color.Rgba.fromHex(0xdddddd);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *SwitchFixture = @ptrCast(@alignCast(ctx.?));
        const value: Value = if (self.controlled_value) |v|
            .{ .controlled = v }
        else
            .{ .uncontrolled = self.state };

        const root = div_mod.div(arena)
            .sizePx(100, 100)
            .padPx(10)
            .childDiv(switchEl(arena, &harness.app, &harness.input, .{
                .id = "the-switch",
                .value = value,
                .disabled = self.disabled,
                .on_change = .{ .ctx = self, .func = onChange },
                .style_fn = styleFor,
            }));
        return root.any();
    }
};

test "uncontrolled switch toggles on click and reports changes" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer harness.deinit();

    var fixture = SwitchFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(SwitchState, .{});
    try harness.setRoot(&fixture, SwitchFixture.render);

    try harness.clickOn("the-switch");
    try std.testing.expect(harness.app.read(SwitchState, fixture.state).on);
    try std.testing.expectEqualSlices(bool, &.{true}, fixture.change_log.items);

    try harness.clickOn("the-switch");
    try std.testing.expect(!harness.app.read(SwitchState, fixture.state).on);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, fixture.change_log.items);
}

test "controlled switch reports intent but does not change itself" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer harness.deinit();

    var fixture = SwitchFixture{ .harness = &harness, .controlled_value = false };
    defer fixture.deinit();
    fixture.state = try harness.app.new(SwitchState, .{});
    try harness.setRoot(&fixture, SwitchFixture.render);

    try harness.clickOn("the-switch");
    try harness.renderFrame();

    const quad = harness.scene.quads.items[0];
    const off_bg = color.Rgba.fromHex(0xdddddd);
    try std.testing.expectApproxEqAbs(off_bg.g, quad.background.g, 0.001);
    try std.testing.expectEqualSlices(bool, &.{true}, fixture.change_log.items);
}

test "switch toggles via keyboard" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer harness.deinit();

    var fixture = SwitchFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(SwitchState, .{});
    try harness.setRoot(&fixture, SwitchFixture.render);

    try harness.focusById(element.elementId("the-switch"));
    try harness.keyDown(.space);
    try std.testing.expect(harness.app.read(SwitchState, fixture.state).on);
}

test "disabled switch does not toggle" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer harness.deinit();

    var fixture = SwitchFixture{ .harness = &harness, .disabled = true };
    defer fixture.deinit();
    fixture.state = try harness.app.new(SwitchState, .{});
    try harness.setRoot(&fixture, SwitchFixture.render);

    try harness.clickOn("the-switch");
    try std.testing.expect(!harness.app.read(SwitchState, fixture.state).on);
    try std.testing.expectEqual(@as(usize, 0), fixture.change_log.items.len);
}

test "switch exposes switch_control role and checked state" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer harness.deinit();

    var fixture = SwitchFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(SwitchState, .{});
    try harness.setRoot(&fixture, SwitchFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.switch_control, harness.a11yRole("the-switch").?);
    try std.testing.expectEqual(@as(?bool, false), harness.a11yNode("the-switch").?.checked);

    try harness.clickOn("the-switch");
    try std.testing.expectEqual(@as(?bool, true), harness.a11yNode("the-switch").?.checked);
}
