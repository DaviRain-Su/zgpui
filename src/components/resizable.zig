//! Headless resizable split panels: drag handle adjusts primary/secondary
//! panel ratio. Visuals are entirely caller-defined via `handle_style_fn`.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const value_mod = @import("../value.zig");
const geometry = @import("../geometry.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Bounds = geometry.Bounds;
const Pixels = geometry.Pixels;
const Point = geometry.Point;

pub const Orientation = enum {
    horizontal,
    vertical,
};

pub const ResizableState = struct {
    ratio: f32 = 0.5,
    dragging: bool = false,
    container_bounds: Bounds(Pixels) = .{},
};

pub const Value = value_mod.FieldValue(ResizableState, "ratio");

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, ratio: f32) void,
};

pub const StyleState = struct {
    ratio: f32 = 0.5,
    hovered: bool = false,
    focused: bool = false,
    focus_visible: bool = false,
    dragging: bool = false,
    disabled: bool = false,
    orientation: Orientation = .horizontal,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    ratio: Value,
    orientation: Orientation = .horizontal,
    min_ratio: f32 = 0.15,
    max_ratio: f32 = 0.85,
    step: ?f32 = null,
    disabled: bool = false,
    on_change: ?ChangeHandler = null,
    handle_style_fn: ?StyleFn = null,
    /// Stable container bounds for drag mapping across frame rebuilds.
    drag_bounds: ?*Bounds(Pixels) = null,
};

var empty_drag_bounds: Bounds(Pixels) = .{};

const Control = struct {
    app: *App,
    value: Value,
    orientation: Orientation,
    min_ratio: f32,
    max_ratio: f32,
    step: f32,
    on_change: ?ChangeHandler,
    container: *Div,
    handle_id: element.ElementId,
    drag_bounds: *Bounds(Pixels),

    fn clamp(self: *const Control, ratio: f32) f32 {
        return std.math.clamp(ratio, self.min_ratio, self.max_ratio);
    }

    fn currentRatio(self: *Control) f32 {
        return self.clamp(self.value.get(self.app));
    }

    fn setRatio(self: *Control, next: f32) void {
        const clamped = self.clamp(next);
        if (self.currentRatio() == clamped) return;
        _ = self.value.setIfUncontrolled(self.app, clamped);
        if (self.on_change) |handler| handler.func(handler.ctx, clamped);
    }

    fn containerBounds(self: *Control) Bounds(Pixels) {
        const live = self.container.bounds;
        if (self.orientation == .horizontal) {
            if (live.size.width > 0) return live;
        } else if (live.size.height > 0) {
            return live;
        }
        if (self.value == .uncontrolled) {
            const stored = self.app.read(ResizableState, self.value.uncontrolled).container_bounds;
            if (self.orientation == .horizontal) {
                if (stored.size.width > 0) return stored;
            } else if (stored.size.height > 0) {
                return stored;
            }
        }
        if (self.orientation == .horizontal) {
            if (self.drag_bounds.size.width > 0) return self.drag_bounds.*;
        } else if (self.drag_bounds.size.height > 0) {
            return self.drag_bounds.*;
        }
        return .{};
    }

    fn persistContainerBounds(self: *Control) void {
        self.drag_bounds.* = self.container.bounds;
        if (self.value != .uncontrolled) return;
        self.app.read(ResizableState, self.value.uncontrolled).container_bounds = self.container.bounds;
    }

    fn setDragging(self: *Control, dragging: bool) void {
        if (self.value != .uncontrolled) return;
        self.app.read(ResizableState, self.value.uncontrolled).dragging = dragging;
    }

    fn isDragging(self: *Control) bool {
        return switch (self.value) {
            .uncontrolled => |entity| self.app.read(ResizableState, entity).dragging,
            .controlled => false,
        };
    }

    fn ratioFromPoint(self: *Control, position: Point(Pixels)) f32 {
        const bounds = self.containerBounds();
        return switch (self.orientation) {
            .horizontal => blk: {
                if (bounds.size.width <= 0) break :blk self.currentRatio();
                const t = (position.x - bounds.origin.x) / bounds.size.width;
                break :blk self.clamp(t);
            },
            .vertical => blk: {
                if (bounds.size.height <= 0) break :blk self.currentRatio();
                const t = (position.y - bounds.origin.y) / bounds.size.height;
                break :blk self.clamp(t);
            },
        };
    }

    fn applyPointer(self: *Control, position: Point(Pixels)) void {
        self.setRatio(self.ratioFromPoint(position));
    }

    fn onMouseDown(ctx: ?*anyopaque, event: *const platform.MouseButtonEvent) void {
        const self: *Control = @ptrCast(@alignCast(ctx.?));
        self.persistContainerBounds();
        self.setDragging(true);
        self.applyPointer(event.position);
    }

    fn onMouseUp(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *Control = @ptrCast(@alignCast(ctx.?));
        self.setDragging(false);
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *Control = @ptrCast(@alignCast(ctx.?));
        const delta = switch (self.orientation) {
            .horizontal => switch (event.key) {
                .left => -self.step,
                .right => self.step,
                else => return false,
            },
            .vertical => switch (event.key) {
                .up => -self.step,
                .down => self.step,
                else => return false,
            },
        };
        self.setRatio(self.currentRatio() + delta);
        return true;
    }
};

pub fn defaultStep(min_ratio: f32, max_ratio: f32) f32 {
    const range = max_ratio - min_ratio;
    const percent = range * 0.01;
    return if (percent > 0.005) percent else 0.005;
}

pub fn readRatio(app: *App, value: Value, min_ratio: f32, max_ratio: f32) f32 {
    return std.math.clamp(value.get(app), min_ratio, max_ratio);
}

fn defaultHandleStyle(orientation: Orientation) style_mod.Style {
    var s = style_mod.Style{};
    s.flex_shrink = 0;
    switch (orientation) {
        .horizontal => {
            s.width = .{ .px = 4 };
            s.height = .{ .percent = 100 };
        },
        .vertical => {
            s.width = .{ .percent = 100 };
            s.height = .{ .px = 4 };
        },
    }
    return s;
}

fn stylePrimaryPanel(panel: *Div, orientation: Orientation, ratio: f32) void {
    var s = style_mod.Style{};
    s.flex_shrink = 0;
    s.flex_basis = .{ .percent = ratio * 100 };
    s.overflow_x = .hidden;
    s.overflow_y = .hidden;
    switch (orientation) {
        .horizontal => s.height = .{ .percent = 100 },
        .vertical => s.width = .{ .percent = 100 },
    }
    _ = panel.withStyle(s);
}

fn buildHandle(
    arena: std.mem.Allocator,
    app: *App,
    input: *const element.InputState,
    props: Props,
    container: *Div,
    handle_id_name: []const u8,
    drag_bounds: *Bounds(Pixels),
) *Div {
    const handle_id = element.elementId(handle_id_name);
    const focus_id: element.FocusId = handle_id;
    const ratio = readRatio(app, props.ratio, props.min_ratio, props.max_ratio);
    const step = props.step orelse defaultStep(props.min_ratio, props.max_ratio);

    const dragging = switch (props.ratio) {
        .uncontrolled => |entity| app.read(ResizableState, entity).dragging,
        .controlled => input.mouse_down_on != null and input.mouse_down_on.? == handle_id,
    };

    var handle = div_mod.div(arena)
        .withId(handle_id_name)
        .interactive();

    const style_state = StyleState{
        .ratio = ratio,
        .hovered = input.isHovered(handle_id),
        .focused = input.isFocused(focus_id),
        .focus_visible = input.focus_visible and input.isFocused(focus_id),
        .dragging = dragging,
        .disabled = props.disabled,
        .orientation = props.orientation,
    };

    if (props.handle_style_fn) |style_fn| {
        handle = handle.withStyle(style_fn(style_state));
    } else {
        handle = handle.withStyle(defaultHandleStyle(props.orientation));
    }

    if (!props.disabled) {
        const control = arena.create(Control) catch @panic("frame arena OOM");
        control.* = .{
            .app = app,
            .value = props.ratio,
            .orientation = props.orientation,
            .min_ratio = props.min_ratio,
            .max_ratio = props.max_ratio,
            .step = step,
            .on_change = props.on_change,
            .container = container,
            .handle_id = handle_id,
            .drag_bounds = drag_bounds,
        };

        if (dragging and input.mouse_down_on != null and input.mouse_down_on.? == handle_id) {
            control.applyPointer(input.mouse_position);
        }

        handle = handle
            .onMouseDown(control, Control.onMouseDown)
            .onMouseUp(control, Control.onMouseUp)
            .focusable(focus_id, .{ .ctx = control, .func = Control.onKey });
    }

    return handle;
}

/// Build the outer flex container for a resizable split. Attach panels with
/// `split` or manually via `childDiv`.
pub fn root(arena: std.mem.Allocator, props: Props) *Div {
    var container = div_mod.div(arena)
        .withId(props.id)
        .wFull()
        .hFull()
        .overflowHidden();

    container = switch (props.orientation) {
        .horizontal => container.flexRow(),
        .vertical => container.flexCol(),
    };

    return container;
}

/// Two-panel resizable split: primary panel sized by `ratio`, drag handle,
/// secondary panel fills remaining space.
pub fn split(
    arena: std.mem.Allocator,
    app: *App,
    input: *const element.InputState,
    props: Props,
    panel_a: *Div,
    panel_b: *Div,
) *Div {
    const ratio = readRatio(app, props.ratio, props.min_ratio, props.max_ratio);
    const handle_id_name = std.fmt.allocPrint(arena, "{s}-handle", .{props.id}) catch @panic("frame arena OOM");

    const drag_bounds = props.drag_bounds orelse &empty_drag_bounds;

    const container = root(arena, props);

    stylePrimaryPanel(panel_a, props.orientation, ratio);

    _ = panel_b.grow().overflowHidden();

    const handle = buildHandle(arena, app, input, props, container, handle_id_name, drag_bounds);

    return container
        .childDiv(panel_a)
        .childDiv(handle)
        .childDiv(panel_b);
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const ResizableFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(ResizableState) = undefined,
    controlled_ratio: ?f32 = null,
    orientation: Orientation = .horizontal,
    disabled: bool = false,
    min_ratio: f32 = 0.15,
    max_ratio: f32 = 0.85,
    drag_bounds: Bounds(Pixels) = .{},
    change_log: std.ArrayList(f32) = .empty,

    fn deinit(self: *ResizableFixture) void {
        self.change_log.deinit(std.testing.allocator);
    }

    fn onChange(ctx: ?*anyopaque, ratio: f32) void {
        const self: *ResizableFixture = @ptrCast(@alignCast(ctx.?));
        self.change_log.append(std.testing.allocator, ratio) catch unreachable;
    }

    fn handleStyle(state: StyleState) style_mod.Style {
        var s = defaultHandleStyle(state.orientation);
        s.background = if (state.dragging)
            color.Rgba.fromHex(0x0066ff)
        else if (state.hovered)
            color.Rgba.fromHex(0x888888)
        else
            color.Rgba.fromHex(0x444444);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *ResizableFixture = @ptrCast(@alignCast(ctx.?));
        const value: Value = if (self.controlled_ratio) |r|
            .{ .controlled = r }
        else
            .{ .uncontrolled = self.state };

        const panel_a = div_mod.div(arena)
            .withId("panel-a")
            .bg(color.Rgba.fromHex(0xff0000));
        const panel_b = div_mod.div(arena)
            .withId("panel-b")
            .bg(color.Rgba.fromHex(0x00ff00));

        const split_root = split(arena, &harness.app, &harness.input, .{
            .id = "the-split",
            .ratio = value,
            .orientation = self.orientation,
            .min_ratio = self.min_ratio,
            .max_ratio = self.max_ratio,
            .disabled = self.disabled,
            .on_change = .{ .ctx = self, .func = onChange },
            .handle_style_fn = handleStyle,
            .drag_bounds = &self.drag_bounds,
        }, panel_a, panel_b);

        const outer = div_mod.div(arena)
            .sizePx(400, 200)
            .childDiv(split_root);
        return outer.any();
    }

    fn containerBounds(self: *ResizableFixture) !geometry.Bounds(Pixels) {
        return self.harness.hitboxBounds(element.elementId("the-split-handle")) orelse error.ElementNotFound;
    }

    fn dragHandleToFraction(self: *ResizableFixture, fraction: f32) !void {
        const handle = self.harness.hitboxBounds(element.elementId("the-split-handle")) orelse return error.ElementNotFound;
        const root_bounds = geometry.Bounds(Pixels){
            .origin = .{ .x = 0, .y = 0 },
            .size = self.harness.viewport,
        };
        const x = root_bounds.origin.x + root_bounds.size.width * fraction;
        const y = handle.origin.y + handle.size.height / 2;
        const down_x = handle.origin.x + handle.size.width / 2;
        try self.harness.dispatch(.{ .mouse_down = .{ .button = .left, .position = .{ .x = down_x, .y = y } } });
        try self.harness.moveMouse(x, y);
        // Re-render while the button is still down so drag applies pointer position.
        try self.harness.renderFrame();
        try self.harness.dispatch(.{ .mouse_up = .{ .button = .left, .position = .{ .x = x, .y = y } } });
    }
};

test "drag handle changes ratio" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 200 });
    defer harness.deinit();

    var fixture = ResizableFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(ResizableState, .{ .ratio = 0.5 });
    try harness.setRoot(&fixture, ResizableFixture.render);

    try fixture.dragHandleToFraction(0.75);
    try std.testing.expectApproxEqAbs(0.75, harness.app.read(ResizableState, fixture.state).ratio, 0.02);
}

test "ratio clamps at min and max" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 200 });
    defer harness.deinit();

    var fixture = ResizableFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(ResizableState, .{ .ratio = 0.5 });
    try harness.setRoot(&fixture, ResizableFixture.render);

    try fixture.dragHandleToFraction(0.02);
    try std.testing.expectApproxEqAbs(0.15, harness.app.read(ResizableState, fixture.state).ratio, 0.02);

    try fixture.dragHandleToFraction(0.98);
    try std.testing.expectApproxEqAbs(0.85, harness.app.read(ResizableState, fixture.state).ratio, 0.02);
}

test "arrow keys nudge horizontal ratio" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 200 });
    defer harness.deinit();

    var fixture = ResizableFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(ResizableState, .{ .ratio = 0.5 });
    try harness.setRoot(&fixture, ResizableFixture.render);

    try harness.focusById(element.elementId("the-split-handle"));
    try harness.keyDown(.right);
    try std.testing.expect(harness.app.read(ResizableState, fixture.state).ratio > 0.5);
    try harness.keyDown(.left);
    try std.testing.expectApproxEqAbs(0.5, harness.app.read(ResizableState, fixture.state).ratio, 0.001);
}

test "arrow keys nudge vertical ratio" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 200 });
    defer harness.deinit();

    var fixture = ResizableFixture{ .harness = &harness, .orientation = .vertical };
    defer fixture.deinit();
    fixture.state = try harness.app.new(ResizableState, .{ .ratio = 0.5 });
    try harness.setRoot(&fixture, ResizableFixture.render);

    try harness.focusById(element.elementId("the-split-handle"));
    try harness.keyDown(.down);
    try std.testing.expect(harness.app.read(ResizableState, fixture.state).ratio > 0.5);
    try harness.keyDown(.up);
    try std.testing.expectApproxEqAbs(0.5, harness.app.read(ResizableState, fixture.state).ratio, 0.001);
}

test "disabled split ignores drag" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 200 });
    defer harness.deinit();

    var fixture = ResizableFixture{ .harness = &harness, .disabled = true };
    defer fixture.deinit();
    fixture.state = try harness.app.new(ResizableState, .{ .ratio = 0.5 });
    try harness.setRoot(&fixture, ResizableFixture.render);

    try fixture.dragHandleToFraction(0.8);
    try std.testing.expectApproxEqAbs(0.5, harness.app.read(ResizableState, fixture.state).ratio, 0.001);
    try std.testing.expectEqual(@as(usize, 0), fixture.change_log.items.len);
}

test "controlled split reports intent without self-updating" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 200 });
    defer harness.deinit();

    var fixture = ResizableFixture{ .harness = &harness, .controlled_ratio = 0.3 };
    defer fixture.deinit();
    try harness.setRoot(&fixture, ResizableFixture.render);

    try fixture.dragHandleToFraction(0.7);
    try harness.renderFrame();
    try std.testing.expectApproxEqAbs(0.3, fixture.controlled_ratio.?, 0.001);
    try std.testing.expect(fixture.change_log.items.len > 0);
    try std.testing.expectApproxEqAbs(0.7, fixture.change_log.items[fixture.change_log.items.len - 1], 0.05);
}
