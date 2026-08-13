//! Headless toolbar: single tab-stop roving focus among toolbar buttons.
//! Arrow keys move `focus_visible` highlight; orientation controls which
//! arrow keys apply.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");

const Div = div_mod.Div;
const App = app_mod.App;

pub const ToolbarState = struct {
    focus_index: usize = 0,
};

pub const Orientation = enum {
    horizontal,
    vertical,
};

pub fn focusedIndex(app: *App, state: app_mod.Entity(ToolbarState)) usize {
    return app.read(ToolbarState, state).focus_index;
}

fn notify(app: *App, state: app_mod.Entity(ToolbarState)) void {
    app.notify(state.id);
}

fn moveFocus(app: *App, state: app_mod.Entity(ToolbarState), item_count: usize, delta: i32) void {
    if (item_count == 0) return;
    const tb = app.read(ToolbarState, state);
    tb.focus_index = switch (delta) {
        -1 => (tb.focus_index + item_count - 1) % item_count,
        else => (tb.focus_index + 1) % item_count,
    };
    notify(app, state);
}

// ---------------------------------------------------------------------------
// Toolbar root
// ---------------------------------------------------------------------------

pub const Props = struct {
    id: []const u8,
    state: app_mod.Entity(ToolbarState),
    app: *App,
    item_count: usize,
    orientation: Orientation = .horizontal,
};

const ToolbarNav = struct {
    app: *App,
    state: app_mod.Entity(ToolbarState),
    item_count: usize,
    orientation: Orientation,

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *ToolbarNav = @ptrCast(@alignCast(ctx.?));
        if (self.item_count == 0) return false;

        const delta: ?i32 = switch (self.orientation) {
            .horizontal => switch (event.key) {
                .left => -1,
                .right => 1,
                else => null,
            },
            .vertical => switch (event.key) {
                .up => -1,
                .down => 1,
                else => null,
            },
        };
        if (delta) |d| {
            moveFocus(self.app, self.state, self.item_count, d);
            return true;
        }
        return false;
    }
};

/// Focusable toolbar container. Children are built with `toolbarButton`.
pub fn toolbar(arena: std.mem.Allocator, props: Props) *Div {
    const focus_id: element.FocusId = element.elementId(props.id);

    const nav = arena.create(ToolbarNav) catch @panic("frame arena OOM");
    nav.* = .{
        .app = props.app,
        .state = props.state,
        .item_count = props.item_count,
        .orientation = props.orientation,
    };

    var d = div_mod.div(arena)
        .withId(props.id)
        .role(.list)
        .focusable(focus_id, .{ .ctx = nav, .func = ToolbarNav.onKey });

    d = switch (props.orientation) {
        .horizontal => d.flexRow(),
        .vertical => d.flexCol(),
    };
    return d;
}

// ---------------------------------------------------------------------------
// Toolbar button
// ---------------------------------------------------------------------------

pub const ButtonStyleState = struct {
    focused: bool = false,
    focus_visible: bool = false,
    hovered: bool = false,
    pressed: bool = false,
    disabled: bool = false,
};

pub const ButtonStyleFn = *const fn (state: ButtonStyleState) style_mod.Style;

pub const PressHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque) void,
};

pub const ButtonProps = struct {
    /// Base id; actual element id should be `{id}-{index}`.
    id: []const u8,
    state: app_mod.Entity(ToolbarState),
    app: *App,
    input: *const element.InputState,
    index: usize,
    toolbar_id: []const u8,
    disabled: bool = false,
    on_press: ?PressHandler = null,
    style_fn: ?ButtonStyleFn = null,
};

const ButtonActivate = struct {
    on_press: PressHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *ButtonActivate = @ptrCast(@alignCast(ctx.?));
        self.on_press.func(self.on_press.ctx);
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        if (event.key != .enter and event.key != .space) return false;
        const self: *ButtonActivate = @ptrCast(@alignCast(ctx.?));
        self.on_press.func(self.on_press.ctx);
        return true;
    }
};

/// Toolbar button child. Caller should use ids `{id}-{index}`.
pub fn toolbarButton(arena: std.mem.Allocator, props: ButtonProps) *Div {
    const id = element.elementId(props.id);
    const toolbar_focus_id = element.elementId(props.toolbar_id);
    const focus_idx = focusedIndex(props.app, props.state);

    const state = ButtonStyleState{
        .focused = focus_idx == props.index,
        .focus_visible = props.input.focus_visible and
            props.input.isFocused(toolbar_focus_id) and
            focus_idx == props.index,
        .hovered = props.input.isHovered(id),
        .pressed = props.input.mouse_down_on != null and props.input.mouse_down_on.? == id,
        .disabled = props.disabled,
    };

    var d = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.button)
        .a11ySelected(state.focused);
    if (props.disabled) {
        d = d.a11yDisabled(true);
    }
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    } else {
        var s = style_mod.Style{};
        s.width = .{ .px = 40 };
        s.height = .{ .px = 32 };
        s.background = if (state.focus_visible)
            @import("../color.zig").Rgba.fromHex(0xbfdbfe)
        else if (state.hovered)
            @import("../color.zig").Rgba.fromHex(0xe5e7eb)
        else
            @import("../color.zig").Rgba.fromHex(0xf3f4f6);
        d = d.withStyle(s);
    }

    if (!props.disabled) {
        if (props.on_press) |on_press| {
            const activate = arena.create(ButtonActivate) catch @panic("frame arena OOM");
            activate.* = .{ .on_press = on_press };
            d = d.onClick(activate, ButtonActivate.onClick);
        }
    }

    return d;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const ToolbarFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(ToolbarState) = undefined,
    presses: u32 = 0,

    const button_count = 3;

    fn buttonStyle(state: ButtonStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 40 };
        s.height = .{ .px = 32 };
        s.background = if (state.focus_visible)
            color.Rgba.fromHex(0xbfdbfe)
        else
            color.Rgba.fromHex(0xf3f4f6);
        return s;
    }

    fn onPress(ctx: ?*anyopaque) void {
        const self: *ToolbarFixture = @ptrCast(@alignCast(ctx.?));
        self.presses += 1;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *ToolbarFixture = @ptrCast(@alignCast(ctx.?));
        const app = &harness.app;

        var bar = toolbar(arena, .{
            .id = "toolbar",
            .state = self.state,
            .app = app,
            .item_count = button_count,
            .orientation = .horizontal,
        });

        var i: usize = 0;
        while (i < button_count) : (i += 1) {
            var id_buf: [32]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_buf, "tb-{d}", .{i});
            bar = bar.childDiv(toolbarButton(arena, .{
                .id = id,
                .state = self.state,
                .app = app,
                .input = &harness.input,
                .index = i,
                .toolbar_id = "toolbar",
                .on_press = .{ .ctx = self, .func = onPress },
                .style_fn = buttonStyle,
            }));
        }

        return div_mod.div(arena).sizePx(300, 80).padPx(20).childDiv(bar).any();
    }
};

test "toolbar receives tab focus" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 80 });
    defer harness.deinit();

    var fixture = ToolbarFixture{ .harness = &harness };
    fixture.state = try harness.app.new(ToolbarState, .{});
    try harness.setRoot(&fixture, ToolbarFixture.render);

    try harness.focusById(element.elementId("toolbar"));
    try std.testing.expect(harness.input.isFocused(element.elementId("toolbar")));
    try std.testing.expect(harness.input.focus_visible);
}

test "toolbar arrow keys move roving focus among buttons" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 80 });
    defer harness.deinit();

    var fixture = ToolbarFixture{ .harness = &harness };
    fixture.state = try harness.app.new(ToolbarState, .{});
    try harness.setRoot(&fixture, ToolbarFixture.render);

    try harness.focusById(element.elementId("toolbar"));
    try std.testing.expectEqual(@as(usize, 0), focusedIndex(&harness.app, fixture.state));

    try harness.keyDown(.right);
    try std.testing.expectEqual(@as(usize, 1), focusedIndex(&harness.app, fixture.state));
    try std.testing.expect(harness.input.focus_visible);

    try harness.keyDown(.right);
    try std.testing.expectEqual(@as(usize, 2), focusedIndex(&harness.app, fixture.state));

    try harness.keyDown(.left);
    try std.testing.expectEqual(@as(usize, 1), focusedIndex(&harness.app, fixture.state));
}

test "vertical toolbar uses up/down arrows" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 100, .height = 200 });
    defer harness.deinit();

    const VertFixture = struct {
        harness: *testing_mod.Harness = undefined,
        state: app_mod.Entity(ToolbarState) = undefined,

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, h: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));

            var bar = toolbar(arena, .{
                .id = "v-toolbar",
                .state = self.state,
                .app = &h.app,
                .item_count = 2,
                .orientation = .vertical,
            });
            bar = bar.childDiv(toolbarButton(arena, .{
                .id = "v-toolbar-0",
                .state = self.state,
                .app = &h.app,
                .input = &h.input,
                .index = 0,
                .toolbar_id = "v-toolbar",
            }));
            bar = bar.childDiv(toolbarButton(arena, .{
                .id = "v-toolbar-1",
                .state = self.state,
                .app = &h.app,
                .input = &h.input,
                .index = 1,
                .toolbar_id = "v-toolbar",
            }));

            return div_mod.div(arena).sizePx(100, 200).childDiv(bar).any();
        }
    };

    var fixture = VertFixture{ .harness = &harness };
    fixture.state = try harness.app.new(ToolbarState, .{});
    try harness.setRoot(&fixture, VertFixture.render);

    try harness.focusById(element.elementId("v-toolbar"));
    try harness.keyDown(.down);
    try std.testing.expectEqual(@as(usize, 1), focusedIndex(&harness.app, fixture.state));
}
