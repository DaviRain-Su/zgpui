//! Headless horizontal slider: click/drag on the track maps x position to
//! value; arrow keys nudge by step. Visuals are entirely caller-defined.

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

pub const SliderState = struct {
    value: f32 = 0,
    min: f32 = 0,
    max: f32 = 1,
    dragging: bool = false,
    track_bounds: Bounds(Pixels) = .{},
};

pub const Value = value_mod.FieldValue(SliderState, "value");

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, value: f32) void,
};

pub const StyleState = struct {
    value: f32 = 0,
    hovered: bool = false,
    focused: bool = false,
    focus_visible: bool = false,
    disabled: bool = false,
    dragging: bool = false,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    value: Value,
    min: f32 = 0,
    max: f32 = 1,
    step: ?f32 = null,
    /// Accessible name (static string valid for the frame).
    label: ?[]const u8 = null,
    disabled: bool = false,
    on_change: ?ChangeHandler = null,
    style_fn: ?StyleFn = null,
};

const Control = struct {
    app: *App,
    value: Value,
    min: f32,
    max: f32,
    step: f32,
    on_change: ?ChangeHandler,
    div: *Div,
    element_id: element.ElementId,

    fn clamp(self: *const Control, v: f32) f32 {
        return std.math.clamp(v, self.min, self.max);
    }

    fn valueFromX(self: *Control, x: Pixels) f32 {
        const bounds = self.div.bounds;
        if (bounds.size.width <= 0) {
            if (self.value == .uncontrolled) {
                const b = self.app.read(SliderState, self.value.uncontrolled).track_bounds;
                if (b.size.width > 0) return self.valueFromBounds(x, b);
            }
            return self.currentValue();
        }
        return self.valueFromBounds(x, bounds);
    }

    fn valueFromBounds(self: *Control, x: Pixels, bounds: Bounds(Pixels)) f32 {
        const t = std.math.clamp((x - bounds.origin.x) / bounds.size.width, 0, 1);
        return self.clamp(self.min + t * (self.max - self.min));
    }

    fn currentValue(self: *Control) f32 {
        return self.clamp(self.value.get(self.app));
    }

    fn setValue(self: *Control, next: f32) void {
        const clamped = self.clamp(next);
        if (self.currentValue() == clamped) return;
        _ = self.value.setIfUncontrolled(self.app, clamped);
        if (self.on_change) |handler| handler.func(handler.ctx, clamped);
    }

    fn persistTrackBounds(self: *Control) void {
        if (self.value != .uncontrolled) return;
        const state = self.app.read(SliderState, self.value.uncontrolled);
        state.track_bounds = self.div.bounds;
    }

    fn setDragging(self: *Control, dragging: bool) void {
        if (self.value != .uncontrolled) return;
        self.app.read(SliderState, self.value.uncontrolled).dragging = dragging;
    }

    fn isDragging(self: *Control) bool {
        return switch (self.value) {
            .uncontrolled => |entity| self.app.read(SliderState, entity).dragging,
            .controlled => false,
        };
    }

    fn applyPointer(self: *Control, x: Pixels) void {
        self.setValue(self.valueFromX(x));
    }

    fn onMouseDown(ctx: ?*anyopaque, event: *const platform.MouseButtonEvent) void {
        const self: *Control = @ptrCast(@alignCast(ctx.?));
        self.persistTrackBounds();
        self.setDragging(true);
        self.applyPointer(event.position.x);
    }

    fn onMouseUp(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *Control = @ptrCast(@alignCast(ctx.?));
        self.setDragging(false);
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        if (event.key != .left and event.key != .right) return false;
        const self: *Control = @ptrCast(@alignCast(ctx.?));
        const delta = if (event.key == .left) -self.step else self.step;
        self.setValue(self.currentValue() + delta);
        return true;
    }
};

pub fn defaultStep(min: f32, max: f32) f32 {
    const range = max - min;
    const percent = range * 0.01;
    return if (percent > 0.05) percent else 0.05;
}

pub fn readValue(app: *App, value: Value, min: f32, max: f32) f32 {
    return std.math.clamp(value.get(app), min, max);
}

pub fn slider(arena: std.mem.Allocator, app: *App, input: *const element.InputState, props: Props) *Div {
    const id = element.elementId(props.id);
    const focus_id: element.FocusId = id;
    const step = props.step orelse defaultStep(props.min, props.max);
    const value = readValue(app, props.value, props.min, props.max);

    var d = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.slider)
        .a11yOrientation(.horizontal);
    if (props.label) |label| {
        d = d.a11yName(label);
    }
    const value_text = std.fmt.allocPrint(arena, "{d:.2}", .{value}) catch @panic("frame arena OOM");
    d = d.a11yValueText(value_text);
    d = d.a11yNumeric(value, props.min, props.max);
    const range = props.max - props.min;
    if (range > 0) {
        const percent = ((value - props.min) / range) * 100.0;
        const value_description = std.fmt.allocPrint(arena, "{d:.0} percent", .{percent}) catch @panic("frame arena OOM");
        d = d.a11yValueDescription(value_description);
    } else {
        d = d.a11yValueDescription(value_text);
    }
    if (props.disabled) {
        d = d.a11yDisabled(true);
    }
    if (props.style_fn) |style_fn| {
        const dragging = switch (props.value) {
            .uncontrolled => |entity| app.read(SliderState, entity).dragging,
            .controlled => input.mouse_down_on != null and input.mouse_down_on.? == id,
        };
        d = d.withStyle(style_fn(.{
            .value = value,
            .hovered = input.isHovered(id),
            .focused = input.isFocused(focus_id),
            .focus_visible = input.focus_visible and input.isFocused(focus_id),
            .disabled = props.disabled,
            .dragging = dragging,
        }));
    }

    if (!props.disabled) {
        const control = arena.create(Control) catch @panic("frame arena OOM");
        control.* = .{
            .app = app,
            .value = props.value,
            .min = props.min,
            .max = props.max,
            .step = step,
            .on_change = props.on_change,
            .div = d,
            .element_id = id,
        };

        if (control.isDragging() and input.mouse_down_on != null and input.mouse_down_on.? == id) {
            control.applyPointer(input.mouse_position.x);
        }

        d = d.onMouseDown(control, Control.onMouseDown)
            .onMouseUp(control, Control.onMouseUp)
            .focusable(focus_id, .{ .ctx = control, .func = Control.onKey });
    }

    return d;
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const a11y_mod = @import("../a11y.zig");
const color = @import("../color.zig");

const SliderFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(SliderState) = undefined,
    controlled_value: ?f32 = null,
    disabled: bool = false,
    label: ?[]const u8 = null,
    change_log: std.ArrayList(f32) = .empty,

    fn deinit(self: *SliderFixture) void {
        self.change_log.deinit(std.testing.allocator);
    }

    fn onChange(ctx: ?*anyopaque, value: f32) void {
        const self: *SliderFixture = @ptrCast(@alignCast(ctx.?));
        self.change_log.append(std.testing.allocator, value) catch unreachable;
    }

    fn styleFor(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 200 };
        s.height = .{ .px = 20 };
        s.background = if (state.value > 0.5) color.Rgba.fromHex(0x00aa00) else color.Rgba.fromHex(0x333333);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *SliderFixture = @ptrCast(@alignCast(ctx.?));
        const value: Value = if (self.controlled_value) |v|
            .{ .controlled = v }
        else
            .{ .uncontrolled = self.state };

        const root = div_mod.div(arena)
            .sizePx(300, 100)
            .padPx(20)
            .childDiv(slider(arena, &harness.app, &harness.input, .{
            .id = "the-slider",
            .value = value,
            .label = self.label,
            .disabled = self.disabled,
            .on_change = .{ .ctx = self, .func = onChange },
            .style_fn = styleFor,
        }));
        return root.any();
    }

    fn clickTrackFraction(self: *SliderFixture, fraction: f32) !void {
        const bounds = self.harness.hitboxBounds(element.elementId("the-slider")) orelse return error.ElementNotFound;
        const x = bounds.origin.x + bounds.size.width * fraction;
        const y = bounds.origin.y + bounds.size.height / 2;
        try self.harness.click(x, y);
    }
};

test "click sets approximate value at left center and right" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 100 });
    defer harness.deinit();

    var fixture = SliderFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(SliderState, .{});
    try harness.setRoot(&fixture, SliderFixture.render);

    try fixture.clickTrackFraction(0.05);
    try std.testing.expectApproxEqAbs(0.0, harness.app.read(SliderState, fixture.state).value, 0.1);

    try fixture.clickTrackFraction(0.5);
    try std.testing.expectApproxEqAbs(0.5, harness.app.read(SliderState, fixture.state).value, 0.1);

    try fixture.clickTrackFraction(0.95);
    try std.testing.expectApproxEqAbs(1.0, harness.app.read(SliderState, fixture.state).value, 0.1);
}

test "arrow keys nudge slider value" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 100 });
    defer harness.deinit();

    var fixture = SliderFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(SliderState, .{ .value = 0.5 });
    try harness.setRoot(&fixture, SliderFixture.render);

    try harness.focusById(element.elementId("the-slider"));
    try harness.keyDown(.right);
    try std.testing.expectApproxEqAbs(0.55, harness.app.read(SliderState, fixture.state).value, 0.001);
    try harness.keyDown(.left);
    try std.testing.expectApproxEqAbs(0.5, harness.app.read(SliderState, fixture.state).value, 0.001);
}

test "disabled slider ignores input" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 100 });
    defer harness.deinit();

    var fixture = SliderFixture{ .harness = &harness, .disabled = true };
    defer fixture.deinit();
    fixture.state = try harness.app.new(SliderState, .{});
    try harness.setRoot(&fixture, SliderFixture.render);

    try fixture.clickTrackFraction(0.5);
    try std.testing.expectApproxEqAbs(0.0, harness.app.read(SliderState, fixture.state).value, 0.001);
    try std.testing.expectEqual(@as(usize, 0), fixture.change_log.items.len);

    try std.testing.expectError(error.FocusTargetNotFound, harness.focusById(element.elementId("the-slider")));
    try std.testing.expect(!harness.a11yNode("the-slider").?.adjustable);
    try std.testing.expectError(error.ElementNotFound, harness.a11yIncrementOn("the-slider"));
}

test "uncontrolled slider persists value across re-render" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 100 });
    defer harness.deinit();

    var fixture = SliderFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(SliderState, .{});
    try harness.setRoot(&fixture, SliderFixture.render);

    try fixture.clickTrackFraction(0.75);
    const before = harness.app.read(SliderState, fixture.state).value;
    try harness.renderFrame();
    try std.testing.expectApproxEqAbs(before, harness.app.read(SliderState, fixture.state).value, 0.001);
}

test "slider exposes slider role and value text" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 100 });
    defer harness.deinit();

    var fixture = SliderFixture{ .harness = &harness, .label = "Volume" };
    defer fixture.deinit();
    fixture.state = try harness.app.new(SliderState, .{ .value = 0.25 });
    try harness.setRoot(&fixture, SliderFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.slider, harness.a11yRole("the-slider").?);
    try std.testing.expectEqualStrings("Volume", harness.a11yName("the-slider").?);
    const node = harness.a11yNode("the-slider").?;
    try std.testing.expect(node.adjustable);
    try std.testing.expectEqual(a11y_mod.Orientation.horizontal, node.orientation.?);
    try std.testing.expectEqualStrings("0.25", node.value_text.?);
    try std.testing.expectEqualStrings("25 percent", node.value_description.?);
    try std.testing.expectEqual(@as(?f64, 0.25), node.numeric_value);
    try std.testing.expectEqual(@as(?f64, 0.0), node.min_value);
    try std.testing.expectEqual(@as(?f64, 1.0), node.max_value);
}

test "accessibility increment and decrement use slider step" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 100 });
    defer harness.deinit();

    var fixture = SliderFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(SliderState, .{ .value = 0.5 });
    try harness.setRoot(&fixture, SliderFixture.render);

    try harness.a11yIncrementOn("the-slider");
    try std.testing.expectApproxEqAbs(0.55, harness.app.read(SliderState, fixture.state).value, 0.001);
    try harness.a11yDecrementOn("the-slider");
    try std.testing.expectApproxEqAbs(0.5, harness.app.read(SliderState, fixture.state).value, 0.001);
}

test "controlled slider reports intent without self-updating" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 100 });
    defer harness.deinit();

    var fixture = SliderFixture{ .harness = &harness, .controlled_value = 0.2 };
    defer fixture.deinit();
    try harness.setRoot(&fixture, SliderFixture.render);

    try fixture.clickTrackFraction(0.8);
    try harness.renderFrame();
    try std.testing.expectApproxEqAbs(0.2, fixture.controlled_value.?, 0.001);
    try std.testing.expect(fixture.change_log.items.len > 0);
    try std.testing.expectApproxEqAbs(0.8, fixture.change_log.items[fixture.change_log.items.len - 1], 0.1);
}
