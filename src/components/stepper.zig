//! Headless multi-step navigator (wizard progress). Selection via
//! `Value(usize)`; each step is a clickable button-like item.

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
    func: *const fn (ctx: ?*anyopaque, step: usize) void,
};

pub const Orientation = enum { horizontal, vertical };

pub const ItemStyleState = struct {
    index: usize = 0,
    selected: bool = false,
    completed: bool = false,
    hovered: bool = false,
    disabled: bool = false,
};

pub const ItemStyleFn = *const fn (state: ItemStyleState) style_mod.Style;
pub const RootStyleFn = *const fn () style_mod.Style;

pub const Item = struct {
    id: []const u8,
    disabled: bool = false,
};

pub const Props = struct {
    id: []const u8,
    value: Value,
    items: []const Item,
    orientation: Orientation = .horizontal,
    disabled: bool = false,
    on_change: ?ChangeHandler = null,
    root_style_fn: ?RootStyleFn = null,
    item_style_fn: ?ItemStyleFn = null,
};

pub fn selectedIndex(app: *App, value: Value) usize {
    return value.get(app);
}

fn setStep(app: *App, value: Value, count: usize, next: usize, on_change: ?ChangeHandler) void {
    if (count == 0) return;
    const clamped = @min(next, count - 1);
    if (value.get(app) == clamped) return;
    value.set(app, clamped);
    if (on_change) |handler| handler.func(handler.ctx, clamped);
}

const StepClick = struct {
    app: *App,
    value: Value,
    index: usize,
    count: usize,
    disabled: bool,
    on_change: ?ChangeHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *StepClick = @ptrCast(@alignCast(ctx.?));
        if (self.disabled) return;
        setStep(self.app, self.value, self.count, self.index, self.on_change);
    }
};

pub fn stepper(arena: std.mem.Allocator, app: *App, input: *const element.InputState, props: Props) *Div {
    const current = if (props.items.len == 0) 0 else @min(selectedIndex(app, props.value), props.items.len - 1);

    var root = div_mod.div(arena).withId(props.id).wFull();
    root = switch (props.orientation) {
        .horizontal => root.flexRow(),
        .vertical => root.flexCol(),
    };
    if (props.root_style_fn) |style_fn| root = root.withStyle(style_fn());

    for (props.items, 0..) |item, index| {
        const disabled = props.disabled or item.disabled;
        const state = ItemStyleState{
            .index = index,
            .selected = index == current,
            .completed = index < current,
            .hovered = input.isHovered(element.elementId(item.id)),
            .disabled = disabled,
        };

        var step = div_mod.div(arena)
            .withId(item.id)
            .interactive()
            .role(.button);
        if (props.item_style_fn) |style_fn| step = step.withStyle(style_fn(state));

        if (!disabled) {
            const click = arena.create(StepClick) catch @panic("frame arena OOM");
            click.* = .{
                .app = app,
                .value = props.value,
                .index = index,
                .count = props.items.len,
                .disabled = false,
                .on_change = props.on_change,
            };
            step = step.onClick(click, StepClick.onClick);
        }

        root = root.childDiv(step);
    }

    return root;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

test "stepper click selects step" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 60 });
    defer harness.deinit();

    const Fixture = struct {
        selected: app_mod.Entity(Value.Store) = undefined,
        log: std.ArrayList(usize) = .empty,

        fn deinit(self: *@This()) void {
            self.log.deinit(std.testing.allocator);
        }

        fn onChange(ctx: ?*anyopaque, step: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.log.append(std.testing.allocator, step) catch unreachable;
        }

        fn itemStyle(state: ItemStyleState) style_mod.Style {
            var s = style_mod.Style{};
            s.width = .{ .px = 80 };
            s.height = .{ .px = 32 };
            s.background = if (state.selected) color.Rgba.fromHex(0x2563eb) else color.Rgba.fromHex(0xe5e7eb);
            return s;
        }

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, h: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const items = [_]Item{
                .{ .id = "step-0" },
                .{ .id = "step-1" },
                .{ .id = "step-2" },
            };
            return div_mod.div(arena).sizePx(300, 60).childDiv(stepper(arena, &h.app, &h.input, .{
                .id = "wizard",
                .value = .{ .uncontrolled = self.selected },
                .items = &items,
                .on_change = .{ .ctx = self, .func = onChange },
                .item_style_fn = itemStyle,
            })).any();
        }
    };

    var fixture: Fixture = .{
        .selected = try harness.app.new(Value.Store, .{ .value = 0 }),
    };
    defer fixture.deinit();
    try harness.setRoot(&fixture, Fixture.render);

    try harness.clickOn("step-2");
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(&harness.app, .{ .uncontrolled = fixture.selected }));
    try std.testing.expectEqual(@as(usize, 1), fixture.log.items.len);
    try std.testing.expectEqual(@as(usize, 2), fixture.log.items[0]);
}
