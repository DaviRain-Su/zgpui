//! Headless link: focusable, clickable control with optional href stored for
//! accessibility semantics (no networking). Visuals via `style_fn`.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");

const Div = div_mod.Div;

pub const StyleState = struct {
    hovered: bool = false,
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
    disabled: bool = false,
    /// Stored on the div for semantics only; does not perform navigation.
    href: ?[]const u8 = null,
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

/// Build a link div. Callers add label children.
pub fn link(arena: std.mem.Allocator, input: *const element.InputState, props: Props) *Div {
    const id = element.elementId(props.id);
    const focus_id: element.FocusId = id;

    const state = StyleState{
        .hovered = input.isHovered(id),
        .focused = input.isFocused(focus_id),
        .focus_visible = input.focus_visible and input.isFocused(focus_id),
        .disabled = props.disabled,
    };

    var d = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.link);
    if (props.href) |href| {
        d = d.withHref(href);
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
const a11y_mod = @import("../a11y.zig");
const app_mod = @import("../app.zig");
const color = @import("../color.zig");

const LinkFixture = struct {
    harness: *testing_mod.Harness = undefined,
    counter: app_mod.Entity(Counter) = undefined,
    disabled: bool = false,
    href: ?[]const u8 = "/home",

    const Counter = struct { presses: u32 = 0 };

    fn onPress(ctx: ?*anyopaque) void {
        const self: *LinkFixture = @ptrCast(@alignCast(ctx.?));
        self.harness.app.read(Counter, self.counter).presses += 1;
        self.harness.app.notify(self.counter.id);
    }

    fn styleFor(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 80 };
        s.height = .{ .px = 24 };
        s.background = if (state.disabled)
            color.Rgba.fromHex(0x888888)
        else if (state.focused)
            color.Rgba.fromHex(0x224466)
        else if (state.hovered)
            color.Rgba.fromHex(0x4488cc)
        else
            color.Rgba.fromHex(0x336699);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *LinkFixture = @ptrCast(@alignCast(ctx.?));
        const link_div = link(arena, &harness.input, .{
            .id = "the-link",
            .disabled = self.disabled,
            .href = self.href,
            .on_press = .{ .ctx = self, .func = onPress },
            .style_fn = styleFor,
        });
        if (self.href) |expected| {
            try std.testing.expectEqualStrings(expected, link_div.href.?);
        } else {
            try std.testing.expect(link_div.href == null);
        }

        const root = div_mod.div(arena)
            .sizePx(200, 80)
            .padPx(20)
            .childDiv(link_div);
        return root.any();
    }

    fn presses(self: *LinkFixture) u32 {
        return self.harness.app.read(Counter, self.counter).presses;
    }
};

test "link activates on click" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 80 });
    defer harness.deinit();

    var fixture = LinkFixture{ .harness = &harness };
    fixture.counter = try harness.app.new(LinkFixture.Counter, .{});
    try harness.setRoot(&fixture, LinkFixture.render);

    try harness.clickOn("the-link");
    try std.testing.expectEqual(@as(u32, 1), fixture.presses());
}

test "link activates via keyboard and stores href" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 80 });
    defer harness.deinit();

    var fixture = LinkFixture{ .harness = &harness, .href = "/docs" };
    fixture.counter = try harness.app.new(LinkFixture.Counter, .{});
    try harness.setRoot(&fixture, LinkFixture.render);

    try harness.focusById(element.elementId("the-link"));
    try harness.keyDown(.enter);
    try std.testing.expectEqual(@as(u32, 1), fixture.presses());
}

test "disabled link ignores input and is not focusable" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 80 });
    defer harness.deinit();

    var fixture = LinkFixture{ .harness = &harness, .disabled = true };
    fixture.counter = try harness.app.new(LinkFixture.Counter, .{});
    try harness.setRoot(&fixture, LinkFixture.render);

    try harness.clickOn("the-link");
    try std.testing.expectEqual(@as(u32, 0), fixture.presses());
    try std.testing.expectError(error.FocusTargetNotFound, harness.focusById(element.elementId("the-link")));
}

test "link exposes link role" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 80 });
    defer harness.deinit();

    var fixture = LinkFixture{ .harness = &harness };
    fixture.counter = try harness.app.new(LinkFixture.Counter, .{});
    try harness.setRoot(&fixture, LinkFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.link, harness.a11yRole("the-link").?);
}

test "link hover and focused style states" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 80 });
    defer harness.deinit();

    var fixture = LinkFixture{ .harness = &harness };
    fixture.counter = try harness.app.new(LinkFixture.Counter, .{});
    try harness.setRoot(&fixture, LinkFixture.render);

    try harness.hoverOver("the-link");
    try harness.renderFrame();
    try std.testing.expectEqual(@as(usize, 1), harness.scene.quads.items.len);
    const hover = color.Rgba.fromHex(0x4488cc);
    const quad = harness.scene.quads.items[0];
    try std.testing.expectApproxEqAbs(hover.r, quad.background.r, 0.001);

    try harness.focusById(element.elementId("the-link"));
    try harness.renderFrame();
    const focused = color.Rgba.fromHex(0x224466);
    const quad_focus = harness.scene.quads.items[0];
    try std.testing.expectApproxEqAbs(focused.r, quad_focus.background.r, 0.001);
}
