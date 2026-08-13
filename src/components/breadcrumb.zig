//! Headless breadcrumb (compound parts): `list` row container, interactive
//! `item` links, and optional `separator` between items. The current item is
//! non-interactive.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");

const Div = div_mod.Div;
const a11y_mod = @import("../a11y.zig");

pub const ItemStyleState = struct {
    current: bool = false,
    hovered: bool = false,
    focused: bool = false,
    disabled: bool = false,
};

pub const ItemStyleFn = *const fn (state: ItemStyleState) style_mod.Style;

pub const SeparatorStyleState = struct {};

pub const SeparatorStyleFn = *const fn (state: SeparatorStyleState) style_mod.Style;

pub const PressHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque) void,
};

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

pub const ListProps = struct {
    id: []const u8,
    a11y_label: []const u8 = "Breadcrumb",
};

/// Horizontal breadcrumb trail container. Add `item` and `separator` divs.
pub fn list(arena: std.mem.Allocator, props: ListProps) *Div {
    return div_mod.div(arena)
        .withId(props.id)
        .flexRow()
        .itemsCenter()
        .role(.list)
        .a11yOrientation(.horizontal)
        .a11yName(props.a11y_label);
}

// ---------------------------------------------------------------------------
// Item
// ---------------------------------------------------------------------------

pub const ItemProps = struct {
    id: []const u8,
    /// Current (last) crumb: rendered non-interactively.
    current: bool = false,
    disabled: bool = false,
    a11y_label: ?[]const u8 = null,
    on_press: ?PressHandler = null,
    style_fn: ?ItemStyleFn = null,
};

const ItemActivate = struct {
    on_press: PressHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *ItemActivate = @ptrCast(@alignCast(ctx.?));
        self.on_press.func(self.on_press.ctx);
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        if (event.key != .enter and event.key != .space) return false;
        const self: *ItemActivate = @ptrCast(@alignCast(ctx.?));
        self.on_press.func(self.on_press.ctx);
        return true;
    }
};

pub fn item(arena: std.mem.Allocator, input: *const element.InputState, props: ItemProps) *Div {
    const id = element.elementId(props.id);
    const focus_id: element.FocusId = id;

    const state = ItemStyleState{
        .current = props.current,
        .hovered = if (props.current) false else input.isHovered(id),
        .focused = if (props.current) false else input.isFocused(focus_id),
        .disabled = props.disabled,
    };

    var d = div_mod.div(arena).withId(props.id);
    if (props.current) {
        d = d.role(.list_item).a11ySelected(true);
    } else {
        d = d.role(.link);
    }
    if (props.a11y_label) |label| d = d.a11yName(label);
    if (props.disabled) d = d.a11yDisabled(true);
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    }

    if (props.current or props.disabled) {
        return d;
    }

    d = d.interactive();
    if (props.on_press) |on_press| {
        const activation = arena.create(ItemActivate) catch @panic("frame arena OOM");
        activation.* = .{ .on_press = on_press };
        d = d.onClick(activation, ItemActivate.onClick)
            .focusable(focus_id, .{ .ctx = activation, .func = ItemActivate.onKey });
    } else {
        d = d.focusable(focus_id, null);
    }

    return d;
}

// ---------------------------------------------------------------------------
// Separator
// ---------------------------------------------------------------------------

pub const SeparatorProps = struct {
    id: []const u8,
    style_fn: ?SeparatorStyleFn = null,
};

pub fn separator(arena: std.mem.Allocator, props: SeparatorProps) *Div {
    const state = SeparatorStyleState{};
    var d = div_mod.div(arena)
        .withId(props.id)
        .role(.separator)
        .a11yOrientation(.horizontal);
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    }
    return d;
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const app_mod = @import("../app.zig");
const color = @import("../color.zig");

const BreadcrumbFixture = struct {
    harness: *testing_mod.Harness = undefined,
    counter: app_mod.Entity(Counter) = undefined,
    last_clicked: usize = 0,

    const Counter = struct { clicks: u32 = 0 };

    fn onItemPress(ctx: ?*anyopaque) void {
        const self: *BreadcrumbFixture = @ptrCast(@alignCast(ctx.?));
        self.harness.app.read(Counter, self.counter).clicks += 1;
        self.harness.app.notify(self.counter.id);
    }

    fn itemStyle(state: ItemStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 50 };
        s.height = .{ .px = 24 };
        s.background = if (state.current)
            color.Rgba.fromHex(0xffffff)
        else if (state.hovered)
            color.Rgba.fromHex(0x4488cc)
        else
            color.Rgba.fromHex(0x444444);
        return s;
    }

    fn sepStyle(_: SeparatorStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 12 };
        s.height = .{ .px = 24 };
        s.background = color.Rgba.fromHex(0x222222);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *BreadcrumbFixture = @ptrCast(@alignCast(ctx.?));
        self.harness = harness;

        var trail = list(arena, .{ .id = "crumbs" });
        trail = trail
            .childDiv(item(arena, &harness.input, .{
                .id = "crumb-home",
                .on_press = .{ .ctx = self, .func = onItemPress },
                .style_fn = itemStyle,
            }))
            .childDiv(separator(arena, .{ .id = "sep-1", .style_fn = sepStyle }))
            .childDiv(item(arena, &harness.input, .{
                .id = "crumb-docs",
                .on_press = .{ .ctx = self, .func = onItemPress },
                .style_fn = itemStyle,
            }))
            .childDiv(separator(arena, .{ .id = "sep-2", .style_fn = sepStyle }))
            .childDiv(item(arena, &harness.input, .{
                .id = "crumb-current",
                .current = true,
                .style_fn = itemStyle,
            }));

        const root = div_mod.div(arena)
            .sizePx(300, 60)
            .padPx(10)
            .childDiv(trail);
        return root.any();
    }

    fn clicks(self: *BreadcrumbFixture) u32 {
        return self.harness.app.read(Counter, self.counter).clicks;
    }
};

test "breadcrumb item click activates on_press" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 60 });
    defer harness.deinit();

    var fixture = BreadcrumbFixture{ .harness = &harness };
    fixture.counter = try harness.app.new(BreadcrumbFixture.Counter, .{});
    try harness.setRoot(&fixture, BreadcrumbFixture.render);

    try harness.clickOn("crumb-home");
    try std.testing.expectEqual(@as(u32, 1), fixture.clicks());
    try harness.clickOn("crumb-docs");
    try std.testing.expectEqual(@as(u32, 2), fixture.clicks());
}

test "current breadcrumb item is non-interactive" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 60 });
    defer harness.deinit();

    var fixture = BreadcrumbFixture{ .harness = &harness };
    fixture.counter = try harness.app.new(BreadcrumbFixture.Counter, .{});
    try harness.setRoot(&fixture, BreadcrumbFixture.render);

    try std.testing.expect(harness.hitboxBounds(element.elementId("crumb-current")) == null);
    try std.testing.expectError(error.FocusTargetNotFound, harness.focusById(element.elementId("crumb-current")));
    try std.testing.expectEqual(@as(u32, 0), fixture.clicks());
}

test "current breadcrumb item uses current style" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 60 });
    defer harness.deinit();

    var fixture = BreadcrumbFixture{ .harness = &harness };
    fixture.counter = try harness.app.new(BreadcrumbFixture.Counter, .{});
    try harness.setRoot(&fixture, BreadcrumbFixture.render);

    // Quads: home, sep1, docs, sep2, current (5 items).
    try std.testing.expectEqual(@as(usize, 5), harness.scene.quads.items.len);
    const current_quad = harness.scene.quads.items[4];
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), current_quad.background.r, 0.001);
}

test "breadcrumb exposes list link and separator a11y roles" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 60 });
    defer harness.deinit();

    var fixture = BreadcrumbFixture{ .harness = &harness };
    fixture.counter = try harness.app.new(BreadcrumbFixture.Counter, .{});
    try harness.setRoot(&fixture, BreadcrumbFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.list, harness.a11yRole("crumbs").?);
    try std.testing.expectEqual(a11y_mod.Orientation.horizontal, harness.a11yNode("crumbs").?.orientation.?);
    try std.testing.expectEqualStrings("Breadcrumb", a11y_mod.resolveName(harness.a11yNode("crumbs").?).?);
    try std.testing.expectEqual(a11y_mod.Role.link, harness.a11yRole("crumb-home").?);
    try std.testing.expectEqual(a11y_mod.Role.separator, harness.a11yRole("sep-1").?);
    try std.testing.expectEqual(a11y_mod.Role.list_item, harness.a11yRole("crumb-current").?);
    try std.testing.expect(harness.a11yNode("crumb-current").?.selected.?);
}
