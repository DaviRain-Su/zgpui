//! Headless star rating: integer value in `0..=max`, click to set (clicking
//! the filled tip clears one, matching gpui-component Rating).

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const value_mod = @import("../value.zig");

const Div = div_mod.Div;
const App = app_mod.App;

pub const Value = value_mod.Value(usize);

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, value: usize) void,
};

pub const StarStyleState = struct {
    index: usize = 1,
    filled: bool = false,
    hovered: bool = false,
    disabled: bool = false,
};

pub const StarStyleFn = *const fn (state: StarStyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    value: Value,
    max: usize = 5,
    disabled: bool = false,
    on_change: ?ChangeHandler = null,
    star_style_fn: ?StarStyleFn = null,
};

pub fn readValue(app: *App, value: Value, max: usize) usize {
    if (max == 0) return 0;
    return @min(value.get(app), max);
}

fn setValue(app: *App, value: Value, max: usize, next: usize, on_change: ?ChangeHandler) void {
    const clamped = if (max == 0) 0 else @min(next, max);
    if (value.get(app) == clamped) return;
    value.set(app, clamped);
    if (on_change) |handler| handler.func(handler.ctx, clamped);
}

const StarClick = struct {
    app: *App,
    value: Value,
    max: usize,
    /// 1-based star index.
    index: usize,
    disabled: bool,
    on_change: ?ChangeHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *StarClick = @ptrCast(@alignCast(ctx.?));
        if (self.disabled or self.max == 0) return;
        const current = readValue(self.app, self.value, self.max);
        const next: usize = if (current >= self.index) self.index -| 1 else self.index;
        setValue(self.app, self.value, self.max, next, self.on_change);
    }
};

pub fn rating(arena: std.mem.Allocator, app: *App, input: *const element.InputState, props: Props) *Div {
    const current = readValue(app, props.value, props.max);
    var root = div_mod.div(arena)
        .withId(props.id)
        .flexRow()
        .role(.slider)
        .a11yValueText(std.fmt.allocPrint(arena, "{d}/{d}", .{ current, props.max }) catch @panic("frame arena OOM"));

    var ix: usize = 1;
    while (ix <= props.max) : (ix += 1) {
        const star_id = std.fmt.allocPrint(arena, "{s}-star-{d}", .{ props.id, ix }) catch @panic("frame arena OOM");
        const state = StarStyleState{
            .index = ix,
            .filled = ix <= current,
            .hovered = input.isHovered(element.elementId(star_id)),
            .disabled = props.disabled,
        };

        var star = div_mod.div(arena)
            .withId(star_id)
            .interactive()
            .role(.button);
        if (props.star_style_fn) |style_fn| star = star.withStyle(style_fn(state));

        if (!props.disabled) {
            const click = arena.create(StarClick) catch @panic("frame arena OOM");
            click.* = .{
                .app = app,
                .value = props.value,
                .max = props.max,
                .index = ix,
                .disabled = false,
                .on_change = props.on_change,
            };
            star = star.onClick(click, StarClick.onClick);
        }
        root = root.childDiv(star);
    }

    return root;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

test "rating click sets and clears value" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 40 });
    defer harness.deinit();

    const Fixture = struct {
        value: app_mod.Entity(Value.Store) = undefined,

        fn starStyle(state: StarStyleState) style_mod.Style {
            var s = style_mod.Style{};
            s.width = .{ .px = 24 };
            s.height = .{ .px = 24 };
            s.background = if (state.filled) color.Rgba.fromHex(0xeab308) else color.Rgba.fromHex(0xd1d5db);
            return s;
        }

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, h: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return div_mod.div(arena).sizePx(200, 40).childDiv(rating(arena, &h.app, &h.input, .{
                .id = "stars",
                .value = .{ .uncontrolled = self.value },
                .max = 5,
                .star_style_fn = starStyle,
            })).any();
        }
    };

    var fixture: Fixture = .{
        .value = try harness.app.new(Value.Store, .{ .value = 0 }),
    };
    try harness.setRoot(&fixture, Fixture.render);

    try harness.clickOn("stars-star-3");
    try std.testing.expectEqual(@as(usize, 3), readValue(&harness.app, .{ .uncontrolled = fixture.value }, 5));

    try harness.clickOn("stars-star-3");
    try std.testing.expectEqual(@as(usize, 2), readValue(&harness.app, .{ .uncontrolled = fixture.value }, 5));
}
