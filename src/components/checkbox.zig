//! Headless checkbox component with controlled and uncontrolled modes,
//! following base-gpui's checkbox design.
//!
//! - Uncontrolled: state lives in an app entity (`CheckboxState`); the
//!   component toggles it and notifies.
//! - Controlled: the value comes from props; the component only reports the
//!   intended value via `on_change`, and the parent decides.

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

pub const CheckboxState = struct {
    checked: bool = false,
};

pub const Value = value_mod.FieldValue(CheckboxState, "checked");

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, checked: bool) void,
};

pub const StyleState = struct {
    checked: bool = false,
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
    checked: bool,
    on_change: ?ChangeHandler,

    fn activate(self: *Toggle) void {
        const next = !self.checked;
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

pub fn isChecked(app: *App, value: Value) bool {
    return value.get(app);
}

pub fn checkbox(arena: std.mem.Allocator, app: *App, input: *const element.InputState, props: Props) *Div {
    const id = element.elementId(props.id);
    const focus_id: element.FocusId = id;
    const checked = isChecked(app, props.value);

    const state = StyleState{
        .checked = checked,
        .hovered = input.isHovered(id),
        .pressed = input.mouse_down_on != null and input.mouse_down_on.? == id,
        .focused = input.isFocused(focus_id),
        .focus_visible = input.focus_visible and input.isFocused(focus_id),
        .disabled = props.disabled,
    };

    var d = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.checkbox)
        .a11yChecked(checked);
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
            .checked = checked,
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

const CheckboxFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(CheckboxState) = undefined,
    controlled_value: ?bool = null,
    disabled: bool = false,
    change_log: std.ArrayList(bool) = .empty,

    fn deinit(self: *CheckboxFixture) void {
        self.change_log.deinit(std.testing.allocator);
    }

    fn onChange(ctx: ?*anyopaque, checked: bool) void {
        const self: *CheckboxFixture = @ptrCast(@alignCast(ctx.?));
        self.change_log.append(std.testing.allocator, checked) catch unreachable;
    }

    fn styleFor(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 20 };
        s.height = .{ .px = 20 };
        s.background = if (state.checked) color.Rgba.fromHex(0x00aa00) else color.Rgba.fromHex(0xdddddd);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *CheckboxFixture = @ptrCast(@alignCast(ctx.?));
        const value: Value = if (self.controlled_value) |v|
            .{ .controlled = v }
        else
            .{ .uncontrolled = self.state };

        const root = div_mod.div(arena)
            .sizePx(100, 100)
            .padPx(10)
            .childDiv(checkbox(arena, &harness.app, &harness.input, .{
                .id = "the-checkbox",
                .value = value,
                .disabled = self.disabled,
                .on_change = .{ .ctx = self, .func = onChange },
                .style_fn = styleFor,
            }));
        return root.any();
    }
};

test "uncontrolled checkbox toggles on click and reports changes" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer harness.deinit();

    var fixture = CheckboxFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(CheckboxState, .{});
    try harness.setRoot(&fixture, CheckboxFixture.render);

    try harness.clickOn("the-checkbox");
    try std.testing.expect(harness.app.read(CheckboxState, fixture.state).checked);
    try std.testing.expectEqualSlices(bool, &.{true}, fixture.change_log.items);

    try harness.clickOn("the-checkbox");
    try std.testing.expect(!harness.app.read(CheckboxState, fixture.state).checked);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, fixture.change_log.items);
}

test "controlled checkbox reports intent but does not change itself" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer harness.deinit();

    var fixture = CheckboxFixture{ .harness = &harness, .controlled_value = false };
    defer fixture.deinit();
    fixture.state = try harness.app.new(CheckboxState, .{});
    try harness.setRoot(&fixture, CheckboxFixture.render);

    try harness.clickOn("the-checkbox");
    try harness.renderFrame();

    // Parent did not update the value: still unchecked visually.
    const quad = harness.scene.quads.items[0];
    const unchecked_bg = color.Rgba.fromHex(0xdddddd);
    try std.testing.expectApproxEqAbs(unchecked_bg.g, quad.background.g, 0.001);
    // But the intent was reported.
    try std.testing.expectEqualSlices(bool, &.{true}, fixture.change_log.items);
}

test "checkbox toggles via keyboard" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer harness.deinit();

    var fixture = CheckboxFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(CheckboxState, .{});
    try harness.setRoot(&fixture, CheckboxFixture.render);

    try harness.focusById(element.elementId("the-checkbox"));
    try harness.keyDown(.space);
    try std.testing.expect(harness.app.read(CheckboxState, fixture.state).checked);
}

test "checkbox registers role and reflects checked state" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer harness.deinit();

    var fixture = CheckboxFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(CheckboxState, .{});
    try harness.setRoot(&fixture, CheckboxFixture.render);

    try std.testing.expectEqual(@as(?a11y_mod.Role, .checkbox), harness.a11yRole("the-checkbox"));
    try std.testing.expect(!harness.a11yChecked("the-checkbox").?);

    try harness.clickOn("the-checkbox");
    try std.testing.expect(harness.a11yChecked("the-checkbox").?);
}

test "disabled checkbox does not toggle" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer harness.deinit();

    var fixture = CheckboxFixture{ .harness = &harness, .disabled = true };
    defer fixture.deinit();
    fixture.state = try harness.app.new(CheckboxState, .{});
    try harness.setRoot(&fixture, CheckboxFixture.render);

    try harness.clickOn("the-checkbox");
    try std.testing.expect(!harness.app.read(CheckboxState, fixture.state).checked);
    try std.testing.expectEqual(@as(usize, 0), fixture.change_log.items.len);
}
