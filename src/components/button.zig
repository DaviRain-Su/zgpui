//! Headless button component, following base-gpui's button design:
//! behavior (activation via click and keyboard, disabled handling, style
//! states) without prescribing visuals — callers style via `style_fn`.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const a11y_mod = @import("../a11y.zig");

const Div = div_mod.Div;

pub const StyleState = struct {
    hovered: bool = false,
    pressed: bool = false,
    focused: bool = false,
    focus_visible: bool = false,
    disabled: bool = false,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;

pub const PressHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque) void,
};

pub const Props = struct {
    /// Stable identity (also the focus id).
    id: []const u8,
    /// Accessible name (static string valid for the frame).
    label: ?[]const u8 = null,
    disabled: bool = false,
    on_press: ?PressHandler = null,
    style_fn: ?StyleFn = null,
};

const Activation = struct {
    on_press: PressHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *Activation = @ptrCast(@alignCast(ctx.?));
        self.on_press.func(self.on_press.ctx);
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        if (event.key != .enter and event.key != .space) return false;
        const self: *Activation = @ptrCast(@alignCast(ctx.?));
        self.on_press.func(self.on_press.ctx);
        return true;
    }
};

/// Build a button div. Callers may add children (label, icon) to the
/// returned div. `input` provides hover/press/focus state for styling.
pub fn button(arena: std.mem.Allocator, input: *const element.InputState, props: Props) *Div {
    const id = element.elementId(props.id);
    const focus_id: element.FocusId = id;

    const state = StyleState{
        .hovered = input.isHovered(id),
        .pressed = input.mouse_down_on != null and input.mouse_down_on.? == id,
        .focused = input.isFocused(focus_id),
        .focus_visible = input.focus_visible and input.isFocused(focus_id),
        .disabled = props.disabled,
    };

    var d = div_mod.div(arena).withId(props.id).interactive().role(.button);
    if (props.label) |label| {
        d = d.a11yName(label);
    }
    if (props.disabled) {
        d = d.a11yDisabled(true);
    }
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    }

    if (!props.disabled) {
        if (props.on_press) |on_press| {
            const activation = arena.create(Activation) catch @panic("frame arena OOM");
            activation.* = .{ .on_press = on_press };
            d = d.onClick(activation, Activation.onClick)
                .focusable(focus_id, .{ .ctx = activation, .func = Activation.onKey });
        } else {
            d = d.focusable(focus_id, null);
        }
    }

    return d;
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const app_mod = @import("../app.zig");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");

const ButtonFixture = struct {
    harness: *testing_mod.Harness = undefined,
    counter: app_mod.Entity(Counter) = undefined,
    disabled: bool = false,

    const Counter = struct { presses: u32 = 0 };

    fn onPress(ctx: ?*anyopaque) void {
        const self: *ButtonFixture = @ptrCast(@alignCast(ctx.?));
        self.harness.app.read(Counter, self.counter).presses += 1;
        self.harness.app.notify(self.counter.id);
    }

    fn styleFor(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 100 };
        s.height = .{ .px = 40 };
        s.background = if (state.disabled)
            color.Rgba.fromHex(0x888888)
        else if (state.pressed)
            color.Rgba.fromHex(0x224466)
        else if (state.hovered)
            color.Rgba.fromHex(0x4488cc)
        else
            color.Rgba.fromHex(0x336699);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *ButtonFixture = @ptrCast(@alignCast(ctx.?));
        const root = div_mod.div(arena)
            .sizePx(300, 200)
            .padPx(20)
            .childDiv(button(arena, &harness.input, .{
                .id = "the-button",
                .label = "Save",
                .disabled = self.disabled,
                .on_press = .{ .ctx = self, .func = onPress },
                .style_fn = styleFor,
            }));
        return root.any();
    }

    fn presses(self: *ButtonFixture) u32 {
        return self.harness.app.read(Counter, self.counter).presses;
    }
};

test "button activates on click" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = ButtonFixture{ .harness = &harness };
    fixture.counter = try harness.app.new(ButtonFixture.Counter, .{});
    try harness.setRoot(&fixture, ButtonFixture.render);

    try harness.clickOn("the-button");
    try std.testing.expectEqual(@as(u32, 1), fixture.presses());

    try harness.clickOn("the-button");
    try std.testing.expectEqual(@as(u32, 2), fixture.presses());
}

test "button activates via keyboard (tab focus + enter/space)" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = ButtonFixture{ .harness = &harness };
    fixture.counter = try harness.app.new(ButtonFixture.Counter, .{});
    try harness.setRoot(&fixture, ButtonFixture.render);

    try harness.focusById(element.elementId("the-button"));
    try harness.keyDown(.enter);
    try std.testing.expectEqual(@as(u32, 1), fixture.presses());
    try harness.keyDown(.space);
    try std.testing.expectEqual(@as(u32, 2), fixture.presses());

    // Unrelated keys do nothing.
    try harness.keyDown(.a);
    try std.testing.expectEqual(@as(u32, 2), fixture.presses());
}

test "disabled button ignores clicks, keyboard and is not focusable" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = ButtonFixture{ .harness = &harness, .disabled = true };
    fixture.counter = try harness.app.new(ButtonFixture.Counter, .{});
    try harness.setRoot(&fixture, ButtonFixture.render);

    try harness.clickOn("the-button");
    try std.testing.expectEqual(@as(u32, 0), fixture.presses());

    try std.testing.expectError(error.FocusTargetNotFound, harness.focusById(element.elementId("the-button")));
}

test "button registers accessibility role and name" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = ButtonFixture{ .harness = &harness };
    fixture.counter = try harness.app.new(ButtonFixture.Counter, .{});
    try harness.setRoot(&fixture, ButtonFixture.render);

    try std.testing.expectEqual(@as(?a11y_mod.Role, .button), harness.a11yRole("the-button"));
    try std.testing.expectEqualStrings("the-button", harness.a11yNode("the-button").?.identifier.?);
    try std.testing.expectEqualStrings("Save", harness.a11yName("the-button").?);
}

test "button hover and pressed style states" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = ButtonFixture{ .harness = &harness };
    fixture.counter = try harness.app.new(ButtonFixture.Counter, .{});
    try harness.setRoot(&fixture, ButtonFixture.render);

    // Rest state.
    try std.testing.expect(!harness.input.isHovered(element.elementId("the-button")));

    // Hover: input state reflects it; a re-render would style accordingly.
    try harness.hoverOver("the-button");
    try std.testing.expect(harness.input.isHovered(element.elementId("the-button")));
    try harness.renderFrame();

    // Root div paints no background, so the button is the only quad.
    try std.testing.expectEqual(@as(usize, 1), harness.scene.quads.items.len);
    const button_quad = harness.scene.quads.items[0];
    const expected_hover = color.Rgba.fromHex(0x4488cc);
    try std.testing.expectApproxEqAbs(expected_hover.r, button_quad.background.r, 0.001);
    try std.testing.expectApproxEqAbs(expected_hover.g, button_quad.background.g, 0.001);
}

test "button focus_visible tracks keyboard vs pointer focus" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = ButtonFixture{ .harness = &harness };
    fixture.counter = try harness.app.new(ButtonFixture.Counter, .{});
    try harness.setRoot(&fixture, ButtonFixture.render);

    const focus_id = element.elementId("the-button");

    try harness.focusById(focus_id);
    try std.testing.expect(harness.input.isFocused(focus_id));
    try std.testing.expect(harness.input.focus_visible);

    try harness.clickOn("the-button");
    try std.testing.expect(harness.input.isFocused(focus_id));
    try std.testing.expect(!harness.input.focus_visible);
}
