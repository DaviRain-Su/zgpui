//! Read-only gauge (meter): track + indicator with determinate value.
//! Unlike `progress`, meters are non-interactive display-only widgets.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const a11y_mod = @import("../a11y.zig");

const Div = div_mod.Div;

pub const StyleState = struct {
    fraction: f32 = 0,
};

pub const RootStyleFn = *const fn (state: StyleState) style_mod.Style;
pub const TrackStyleFn = *const fn (state: StyleState) style_mod.Style;
pub const IndicatorStyleFn = *const fn (state: StyleState) style_mod.Style;
pub const ValueLabelStyleFn = *const fn (state: StyleState) style_mod.Style;

pub const RootProps = struct {
    id: []const u8,
    value: f32,
    min: f32 = 0,
    max: f32 = 1,
    root_style_fn: ?RootStyleFn = null,
    track_style_fn: ?TrackStyleFn = null,
    indicator_style_fn: ?IndicatorStyleFn = null,
};

pub const ValueLabelProps = struct {
    id: []const u8,
    value: f32,
    min: f32 = 0,
    max: f32 = 1,
    style_fn: ?ValueLabelStyleFn = null,
};

pub fn fraction(value: f32, min: f32, max: f32) f32 {
    const range = max - min;
    if (range <= 0) return 0;
    return std.math.clamp((value - min) / range, 0, 1);
}

fn styleState(value: f32, min: f32, max: f32) StyleState {
    return .{ .fraction = fraction(value, min, max) };
}

/// Meter root containing track and indicator. Registers `role(.progressbar)`.
pub fn root(arena: std.mem.Allocator, props: RootProps) *Div {
    const state = styleState(props.value, props.min, props.max);

    var meter = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.progressbar)
        .a11yOrientation(.horizontal)
        .flexRow()
        .overflowHidden()
        .wFull();

    const value_text = std.fmt.allocPrint(arena, "{d:.0}%", .{state.fraction * 100}) catch @panic("frame arena OOM");
    meter = meter.a11yValueText(value_text);
    meter = meter.a11yNumeric(props.value, props.min, props.max);
    const value_description = std.fmt.allocPrint(arena, "{d:.0} percent", .{state.fraction * 100}) catch @panic("frame arena OOM");
    meter = meter.a11yValueDescription(value_description);

    if (props.root_style_fn) |style_fn| {
        meter = meter.withStyle(style_fn(state));
    }

    var track = trackPart(arena, .{
        .id = std.fmt.allocPrint(arena, "{s}-track", .{props.id}) catch @panic("frame arena OOM"),
        .value = props.value,
        .min = props.min,
        .max = props.max,
        .style_fn = props.track_style_fn,
    });

    const indicator = indicatorPart(arena, .{
        .id = std.fmt.allocPrint(arena, "{s}-indicator", .{props.id}) catch @panic("frame arena OOM"),
        .value = props.value,
        .min = props.min,
        .max = props.max,
        .style_fn = props.indicator_style_fn,
    });

    track = track.childDiv(indicator);
    return meter.childDiv(track);
}

pub const TrackProps = struct {
    id: []const u8,
    value: f32,
    min: f32 = 0,
    max: f32 = 1,
    style_fn: ?TrackStyleFn = null,
};

/// Track bar (non-interactive).
pub fn trackPart(arena: std.mem.Allocator, props: TrackProps) *Div {
    const state = styleState(props.value, props.min, props.max);
    var d = div_mod.div(arena)
        .withId(props.id)
        .flexRow()
        .overflowHidden()
        .wFull()
        .hFull();
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    }
    return d;
}

pub const IndicatorProps = struct {
    id: []const u8,
    value: f32,
    min: f32 = 0,
    max: f32 = 1,
    style_fn: ?IndicatorStyleFn = null,
};

/// Fill indicator sized to the current fraction.
pub fn indicatorPart(arena: std.mem.Allocator, props: IndicatorProps) *Div {
    const state = styleState(props.value, props.min, props.max);
    var d = div_mod.div(arena)
        .withId(props.id)
        .hFull()
        .withStyle(.{
            .width = .{ .percent = state.fraction * 100 },
        });
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    }
    return d;
}

/// Optional text label showing the current percentage.
pub fn valueLabel(arena: std.mem.Allocator, props: ValueLabelProps) *Div {
    const state = styleState(props.value, props.min, props.max);
    var d = div_mod.div(arena).withId(props.id);
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    }
    return d;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const MeterFixture = struct {
    value: f32 = 50,
    min: f32 = 0,
    max: f32 = 100,

    fn trackStyle(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .percent = 100 };
        s.height = .{ .px = 8 };
        s.background = color.Rgba.fromHex(0x333333);
        _ = state;
        return s;
    }

    fn indicatorStyle(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.height = .{ .percent = 100 };
        s.width = .{ .percent = state.fraction * 100 };
        s.background = color.Rgba.fromHex(0x3b82f6);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *MeterFixture = @ptrCast(@alignCast(ctx.?));
        const root_el = root(arena, .{
            .id = "disk-meter",
            .value = self.value,
            .min = self.min,
            .max = self.max,
            .track_style_fn = trackStyle,
            .indicator_style_fn = indicatorStyle,
        });
        _ = harness;
        return div_mod.div(arena).sizePx(200, 40).padPx(10).childDiv(root_el).any();
    }
};

test "meter indicator width reflects value fraction" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 40 });
    defer harness.deinit();

    var fixture = MeterFixture{ .value = 50, .max = 100 };
    try harness.setRoot(&fixture, MeterFixture.render);

    try std.testing.expectEqual(@as(usize, 2), harness.scene.quads.items.len);
    const track = harness.scene.quads.items[0];
    const indicator = harness.scene.quads.items[1];
    try std.testing.expectApproxEqAbs(track.bounds.size_w * 0.5, indicator.bounds.size_w, 1.0);
}

test "meter exposes progressbar role and value text" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 40 });
    defer harness.deinit();

    var fixture = MeterFixture{ .value = 75, .max = 100 };
    try harness.setRoot(&fixture, MeterFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.progressbar, harness.a11yRole("disk-meter").?);
    const node = harness.a11yNode("disk-meter").?;
    try std.testing.expectEqual(a11y_mod.Orientation.horizontal, node.orientation.?);
    try std.testing.expectEqualStrings("75%", node.value_text.?);
    try std.testing.expectEqualStrings("75 percent", node.value_description.?);
    try std.testing.expectEqual(@as(?f64, 75), node.numeric_value);
    try std.testing.expectEqual(@as(?f64, 0), node.min_value);
    try std.testing.expectEqual(@as(?f64, 100), node.max_value);
}

test "fraction clamps out-of-range values" {
    try std.testing.expectApproxEqAbs(@as(f32, 1), fraction(150, 0, 100), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), fraction(-10, 0, 100), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), fraction(50, 0, 100), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), fraction(50, 50, 50), 0.001);
}
