//! Headless collapsible component: a focusable trigger toggles open state;
//! the parent omits or hides content children when closed.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const value_mod = @import("../value.zig");

const Div = div_mod.Div;
const App = app_mod.App;

pub const OpenValue = value_mod.Value(bool);

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, open: bool) void,
};

pub const StyleState = struct {
    open: bool = false,
    hovered: bool = false,
    focused: bool = false,
    disabled: bool = false,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;

pub const TriggerProps = struct {
    id: []const u8,
    value: OpenValue,
    disabled: bool = false,
    on_change: ?ChangeHandler = null,
    style_fn: ?StyleFn = null,
};

const Toggle = struct {
    app: *App,
    value: OpenValue,
    open: bool,
    on_change: ?ChangeHandler,

    fn activate(self: *Toggle) void {
        const next = !self.open;
        if (!self.value.setIfUncontrolled(self.app, next)) {}
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

pub fn isOpen(app: *App, value: OpenValue) bool {
    return value.get(app);
}

/// Focusable trigger that toggles the collapsible open state.
pub fn trigger(arena: std.mem.Allocator, app: *App, input: *const element.InputState, props: TriggerProps) *Div {
    const id = element.elementId(props.id);
    const focus_id: element.FocusId = id;
    const open = isOpen(app, props.value);

    const state = StyleState{
        .open = open,
        .hovered = input.isHovered(id),
        .focused = input.isFocused(focus_id),
        .disabled = props.disabled,
    };

    var d = div_mod.div(arena).withId(props.id).interactive();
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    }

    if (!props.disabled) {
        const toggle = arena.create(Toggle) catch @panic("frame arena OOM");
        toggle.* = .{
            .app = app,
            .value = props.value,
            .open = open,
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

const CollapsibleFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(OpenValue.Store) = undefined,
    controlled_value: ?bool = null,
    disabled: bool = false,
    change_log: std.ArrayList(bool) = .empty,

    fn deinit(self: *CollapsibleFixture) void {
        self.change_log.deinit(std.testing.allocator);
    }

    fn onChange(ctx: ?*anyopaque, open: bool) void {
        const self: *CollapsibleFixture = @ptrCast(@alignCast(ctx.?));
        self.change_log.append(std.testing.allocator, open) catch unreachable;
    }

    fn triggerStyle(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 100 };
        s.height = .{ .px = 30 };
        s.background = if (state.open) color.Rgba.fromHex(0x00aa00) else color.Rgba.fromHex(0xdddddd);
        return s;
    }

    fn currentValue(self: *CollapsibleFixture) OpenValue {
        return if (self.controlled_value) |v|
            .{ .controlled = v }
        else
            .{ .uncontrolled = self.state };
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *CollapsibleFixture = @ptrCast(@alignCast(ctx.?));
        const value = self.currentValue();
        const open = isOpen(&harness.app, value);

        var root = div_mod.div(arena)
            .flexCol()
            .sizePx(200, 200)
            .childDiv(trigger(arena, &harness.app, &harness.input, .{
                .id = "collapsible-trigger",
                .value = value,
                .disabled = self.disabled,
                .on_change = .{ .ctx = self, .func = onChange },
                .style_fn = triggerStyle,
            }));

        if (open) {
            root = root.childDiv(div_mod.div(arena)
                .withId("collapsible-content")
                .interactive()
                .wFull()
                .hPx(80)
                .bg(color.Rgba.fromHex(0x333333)));
        }

        return root.any();
    }
};

test "uncontrolled collapsible toggles on click and shows content" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 200 });
    defer harness.deinit();

    var fixture = CollapsibleFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(OpenValue.Store, .{ .value = false });
    try harness.setRoot(&fixture, CollapsibleFixture.render);

    try std.testing.expect(harness.hitboxBounds(element.elementId("collapsible-content")) == null);

    try harness.clickOn("collapsible-trigger");
    try std.testing.expect(harness.app.read(OpenValue.Store, fixture.state).value);
    try std.testing.expect(harness.hitboxBounds(element.elementId("collapsible-content")) != null);
    try std.testing.expectEqualSlices(bool, &.{true}, fixture.change_log.items);

    try harness.clickOn("collapsible-trigger");
    try std.testing.expect(!harness.app.read(OpenValue.Store, fixture.state).value);
    try std.testing.expect(harness.hitboxBounds(element.elementId("collapsible-content")) == null);
}

test "controlled collapsible reports intent but does not change itself" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 200 });
    defer harness.deinit();

    var fixture = CollapsibleFixture{ .harness = &harness, .controlled_value = false };
    defer fixture.deinit();
    fixture.state = try harness.app.new(OpenValue.Store, .{ .value = false });
    try harness.setRoot(&fixture, CollapsibleFixture.render);

    try harness.clickOn("collapsible-trigger");
    try harness.renderFrame();

    try std.testing.expect(harness.hitboxBounds(element.elementId("collapsible-content")) == null);
    try std.testing.expectEqualSlices(bool, &.{true}, fixture.change_log.items);
}

test "collapsible toggles via keyboard" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 200 });
    defer harness.deinit();

    var fixture = CollapsibleFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(OpenValue.Store, .{ .value = false });
    try harness.setRoot(&fixture, CollapsibleFixture.render);

    try harness.focusById(element.elementId("collapsible-trigger"));
    try harness.keyDown(.space);
    try std.testing.expect(harness.app.read(OpenValue.Store, fixture.state).value);
    try std.testing.expect(harness.hitboxBounds(element.elementId("collapsible-content")) != null);
}

test "disabled collapsible does not toggle" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 200 });
    defer harness.deinit();

    var fixture = CollapsibleFixture{ .harness = &harness, .disabled = true };
    defer fixture.deinit();
    fixture.state = try harness.app.new(OpenValue.Store, .{ .value = false });
    try harness.setRoot(&fixture, CollapsibleFixture.render);

    try harness.clickOn("collapsible-trigger");
    try std.testing.expect(!harness.app.read(OpenValue.Store, fixture.state).value);
    try std.testing.expectEqual(@as(usize, 0), fixture.change_log.items.len);
}
