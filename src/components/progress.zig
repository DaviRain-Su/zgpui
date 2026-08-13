//! Headless progress bar: track + fill structure with determinate value
//! (0..1 or value/max). `indeterminate` is a style-state flag only.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");

const Div = div_mod.Div;

pub const StyleState = struct {
    progress: f32 = 0,
    indeterminate: bool = false,
};

pub const TrackStyleFn = *const fn (state: StyleState) style_mod.Style;
pub const FillStyleFn = *const fn (state: StyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    value: f32 = 0,
    max: f32 = 1,
    indeterminate: bool = false,
    track_style_fn: ?TrackStyleFn = null,
    fill_style_fn: ?FillStyleFn = null,
};

pub fn fraction(value: f32, max: f32) f32 {
    if (max <= 0) return 0;
    return std.math.clamp(value / max, 0, 1);
}

/// Build a progress bar root containing a track div and fill div child.
pub fn progress(arena: std.mem.Allocator, props: Props) *Div {
    const progress_fraction = fraction(props.value, props.max);
    const state = StyleState{
        .progress = progress_fraction,
        .indeterminate = props.indeterminate,
    };

    var track = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.progressbar)
        .a11yOrientation(.horizontal)
        .flexRow()
        .overflowHidden()
        .wFull();

    if (props.indeterminate) {
        track = track.a11yBusy(true);
    } else {
        const value_text = std.fmt.allocPrint(arena, "{d:.0}%", .{progress_fraction * 100}) catch @panic("frame arena OOM");
        track = track.a11yValueText(value_text);
        track = track.a11yNumeric(props.value, 0, props.max);
        const value_description = std.fmt.allocPrint(arena, "{d:.0} percent", .{progress_fraction * 100}) catch @panic("frame arena OOM");
        track = track.a11yValueDescription(value_description);
    }

    if (props.track_style_fn) |track_style_fn| {
        track = track.withStyle(track_style_fn(state));
    }

    var fill = div_mod.div(arena)
        .withId(std.fmt.allocPrint(arena, "{s}-fill", .{props.id}) catch @panic("frame arena OOM"))
        .hFull();

    if (props.indeterminate) {
        fill = fill.wPx(40);
    } else {
        fill = fill.withStyle(.{
            .width = .{ .percent = progress_fraction * 100 },
        });
    }

    if (props.fill_style_fn) |fill_style_fn| {
        fill = fill.withStyle(fill_style_fn(state));
    }

    return track.childDiv(fill);
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const a11y_mod = @import("../a11y.zig");
const color = @import("../color.zig");

const ProgressFixture = struct {
    value: f32 = 0.5,
    max: f32 = 1,
    indeterminate: bool = false,

    fn trackStyle(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .percent = 100 };
        s.height = .{ .px = 8 };
        s.background = color.Rgba.fromHex(0x333333);
        _ = state;
        return s;
    }

    fn fillStyle(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.height = .{ .percent = 100 };
        if (!state.indeterminate) {
            s.width = .{ .percent = state.progress * 100 };
        } else {
            s.width = .{ .px = 40 };
        }
        s.background = color.Rgba.fromHex(0x00aa00);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *ProgressFixture = @ptrCast(@alignCast(ctx.?));
        const root = div_mod.div(arena)
            .sizePx(200, 40)
            .padPx(10)
            .childDiv(progress(arena, .{
                .id = "the-progress",
                .value = self.value,
                .max = self.max,
                .indeterminate = self.indeterminate,
                .track_style_fn = trackStyle,
                .fill_style_fn = fillStyle,
            }));
        _ = harness;
        return root.any();
    }
};

test "determinate progress fill width reflects value/max" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 40 });
    defer harness.deinit();

    var fixture = ProgressFixture{ .value = 50, .max = 100 };
    try harness.setRoot(&fixture, ProgressFixture.render);

    try std.testing.expectEqual(@as(usize, 2), harness.scene.quads.items.len);
    const track = harness.scene.quads.items[0];
    const fill = harness.scene.quads.items[1];
    try std.testing.expectApproxEqAbs(track.bounds.size_w * 0.5, fill.bounds.size_w, 1.0);
}

test "indeterminate progress uses fixed fill width" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 40 });
    defer harness.deinit();

    var fixture = ProgressFixture{ .indeterminate = true };
    try harness.setRoot(&fixture, ProgressFixture.render);

    const fill = harness.scene.quads.items[1];
    try std.testing.expectApproxEqAbs(@as(f32, 40), fill.bounds.size_w, 0.5);
}

test "fraction clamps out-of-range values" {
    try std.testing.expectApproxEqAbs(@as(f32, 1), fraction(150, 100), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), fraction(-10, 100), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), fraction(50, 0), 0.001);
}

test "determinate progress exposes numeric a11y range" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 40 });
    defer harness.deinit();

    var fixture = ProgressFixture{ .value = 25, .max = 100 };
    try harness.setRoot(&fixture, ProgressFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.progressbar, harness.a11yRole("the-progress").?);
    const node = harness.a11yNode("the-progress").?;
    try std.testing.expectEqual(a11y_mod.Orientation.horizontal, node.orientation.?);
    try std.testing.expect(!node.busy);
    try std.testing.expectEqualStrings("25%", node.value_text.?);
    try std.testing.expectEqualStrings("25 percent", node.value_description.?);
    try std.testing.expectEqual(@as(?f64, 25), node.numeric_value);
    try std.testing.expectEqual(@as(?f64, 0), node.min_value);
    try std.testing.expectEqual(@as(?f64, 100), node.max_value);
}

test "indeterminate progress marks busy without numeric value" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 40 });
    defer harness.deinit();

    var fixture = ProgressFixture{ .indeterminate = true };
    try harness.setRoot(&fixture, ProgressFixture.render);

    const node = harness.a11yNode("the-progress").?;
    try std.testing.expect(node.busy);
    try std.testing.expectEqual(a11y_mod.Orientation.horizontal, node.orientation.?);
    try std.testing.expect(node.value_text == null);
    try std.testing.expect(node.numeric_value == null);
}
