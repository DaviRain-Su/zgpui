//! Headless plot geometry (gpui-component plot scales + bar/line helpers).
//!
//! Ports d3-style linear/band scales and chart-area insets — not themed chart
//! chrome, Path painters, or interactive tooltips.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");

const Div = div_mod.Div;
const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Size = geometry.Size;
const Bounds = geometry.Bounds;
const Rgba = color.Rgba;

pub const Margins = struct {
    top: Pixels = 0,
    right: Pixels = 0,
    bottom: Pixels = 0,
    left: Pixels = 0,
};

/// Inner plot area after axis/label margins.
pub fn plotArea(outer: Bounds(Pixels), margins: Margins) Bounds(Pixels) {
    const w = @max(@as(Pixels, 0), outer.size.width - margins.left - margins.right);
    const h = @max(@as(Pixels, 0), outer.size.height - margins.top - margins.bottom);
    return Bounds(Pixels).init(
        .{ .x = outer.origin.x + margins.left, .y = outer.origin.y + margins.top },
        .{ .width = w, .height = h },
    );
}

// ---------------------------------------------------------------------------
// Linear scale (d3-scale/linear)
// ---------------------------------------------------------------------------

pub const ScaleLinear = struct {
    domain_start: f32,
    domain_diff: f32,
    range_start: f32,
    range_diff: f32,

    pub fn init(domain_min: f32, domain_max: f32, range_min: f32, range_max: f32) ScaleLinear {
        return .{
            .domain_start = domain_min,
            .domain_diff = domain_max - domain_min,
            .range_start = range_min,
            .range_diff = range_max - range_min,
        };
    }

    /// Map a domain value into the range, or null when the domain is empty.
    pub fn tick(self: ScaleLinear, value: f32) ?f32 {
        if (self.domain_diff == 0) return null;
        const ratio = (value - self.domain_start) / self.domain_diff;
        return ratio * self.range_diff + self.range_start;
    }

    /// Invert a range tick back into the domain, or null when the range is empty.
    pub fn invert(self: ScaleLinear, tick_v: f32) ?f32 {
        if (self.range_diff == 0) return null;
        const ratio = (tick_v - self.range_start) / self.range_diff;
        return ratio * self.domain_diff + self.domain_start;
    }
};

/// Domain extent of a value slice (min, max). Empty → (0, 0).
pub fn domainExtent(values: []const f32) struct { min: f32, max: f32 } {
    if (values.len == 0) return .{ .min = 0, .max = 0 };
    var lo = values[0];
    var hi = values[0];
    for (values[1..]) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    return .{ .min = lo, .max = hi };
}

// ---------------------------------------------------------------------------
// Band scale (d3-scale/band)
// ---------------------------------------------------------------------------

pub const ScaleBand = struct {
    count: usize,
    range_diff: f32,
    padding_inner: f32 = 0,
    padding_outer: f32 = 0,

    pub fn init(count: usize, range_min: f32, range_max: f32) ScaleBand {
        return .{
            .count = count,
            .range_diff = range_max - range_min,
        };
    }

    pub fn withPadding(self: ScaleBand, inner: f32, outer: f32) ScaleBand {
        var next = self;
        next.padding_inner = std.math.clamp(inner, 0, 1);
        next.padding_outer = std.math.clamp(outer, 0, 1);
        return next;
    }

    fn avgWidth(self: ScaleBand) f32 {
        if (self.count == 0) return 0;
        return self.range_diff / @as(f32, @floatFromInt(self.count));
    }

    fn displayAvgWidth(self: ScaleBand) f32 {
        if (self.count == 0) return 0;
        const outer_w = self.avgWidth() * self.padding_outer;
        return (self.range_diff - outer_w * 2) / @as(f32, @floatFromInt(self.count));
    }

    fn ratio(self: ScaleBand) f32 {
        if (self.count <= 1) return 1;
        return 1 + self.padding_inner / @as(f32, @floatFromInt(self.count - 1));
    }

    /// Pixel width of one band (capped like upstream at 30 for dense charts).
    pub fn bandWidth(self: ScaleBand) f32 {
        return @min(self.avgWidth() * (1 - self.padding_inner), 30);
    }

    /// Start x (or y) of band `index` within [0, range_diff].
    pub fn tick(self: ScaleBand, index: usize) ?f32 {
        if (self.count == 0 or index >= self.count) return null;
        if (self.count == 1) return (self.range_diff - self.bandWidth()) / 2;
        const avg = self.displayAvgWidth();
        const outer_w = self.avgWidth() * self.padding_outer;
        return @as(f32, @floatFromInt(index)) * avg * self.ratio() + outer_w;
    }

    /// Nearest band index for a pointer tick along the band axis.
    pub fn leastIndex(self: ScaleBand, tick_v: f32) usize {
        if (self.count == 0) return 0;
        if (self.count == 1) return 0;
        var best: usize = 0;
        var best_d: f32 = std.math.floatMax(f32);
        for (0..self.count) |i| {
            const t = self.tick(i) orelse continue;
            const center = t + self.bandWidth() / 2;
            const d = @abs(center - tick_v);
            if (d < best_d) {
                best_d = d;
                best = i;
            }
        }
        return best;
    }
};

// ---------------------------------------------------------------------------
// Series helpers
// ---------------------------------------------------------------------------

pub const BarAlignment = enum { vertical, horizontal };

/// Vertical bar growing up from the plot baseline (y = bottom of area).
pub fn verticalBar(
    area: Bounds(Pixels),
    band: ScaleBand,
    value_scale: ScaleLinear,
    index: usize,
    value: f32,
) ?Bounds(Pixels) {
    const x0 = band.tick(index) orelse return null;
    const y_tip = value_scale.tick(value) orelse return null;
    const bw = band.bandWidth();
    const baseline = area.origin.y + area.size.height;
    // value_scale range typically maps high values to smaller y (top).
    const top = @min(y_tip, baseline);
    const bottom = @max(y_tip, baseline);
    return Bounds(Pixels).init(
        .{ .x = area.origin.x + x0, .y = top },
        .{ .width = bw, .height = @max(@as(Pixels, 0), bottom - top) },
    );
}

/// Map (index, value) points for a line chart into plot-absolute coordinates.
pub fn linePoints(
    area: Bounds(Pixels),
    x_scale: ScaleLinear,
    y_scale: ScaleLinear,
    xs: []const f32,
    ys: []const f32,
    out: []Point(Pixels),
) usize {
    const n = @min(@min(xs.len, ys.len), out.len);
    var written: usize = 0;
    for (0..n) |i| {
        const x = x_scale.tick(xs[i]) orelse continue;
        const y = y_scale.tick(ys[i]) orelse continue;
        out[written] = .{ .x = area.origin.x + x, .y = area.origin.y + y };
        written += 1;
    }
    return written;
}

/// Index of the value whose mapped tick is closest to `pointer` on a linear axis.
pub fn nearestLinearIndex(scale: ScaleLinear, values: []const f32, pointer: f32) ?usize {
    if (values.len == 0) return null;
    var best_i: usize = 0;
    var best_d: f32 = std.math.floatMax(f32);
    for (values, 0..) |v, i| {
        const t = scale.tick(v) orelse continue;
        const d = @abs(t - pointer);
        if (d < best_d) {
            best_d = d;
            best_i = i;
        }
    }
    return best_i;
}

// ---------------------------------------------------------------------------
// Pie slices (d3-shape/pie angles; no Path paint)
// ---------------------------------------------------------------------------

pub const tau: f32 = std.math.tau;

pub const PieSlice = struct {
    index: usize,
    value: f32,
    start_angle: f32,
    end_angle: f32,

    pub fn midAngle(self: PieSlice) f32 {
        return (self.start_angle + self.end_angle) / 2;
    }

    pub fn fraction(self: PieSlice) f32 {
        const span = self.end_angle - self.start_angle;
        if (span <= 0) return 0;
        return span / tau;
    }
};

/// Compute pie slice angles for positive values in `values`.
/// `out.len` must be >= number of positive entries; returns written count.
pub fn pieSlices(
    values: []const f32,
    start_angle: f32,
    end_angle: f32,
    out: []PieSlice,
) usize {
    var sum: f32 = 0;
    var positives: usize = 0;
    for (values) |v| {
        if (v > 0) {
            sum += v;
            positives += 1;
        }
    }
    if (positives == 0 or out.len == 0) return 0;

    const sweep = end_angle - start_angle;
    var k = start_angle;
    var written: usize = 0;
    for (values, 0..) |v, i| {
        if (v <= 0) continue;
        if (written >= out.len) break;
        const delta = if (sum > 0) (v / sum) * sweep else 0;
        const start = k;
        k += delta;
        out[written] = .{
            .index = i,
            .value = v,
            .start_angle = start,
            .end_angle = k,
        };
        written += 1;
    }
    return written;
}

/// Unit-circle point for an angle (radians, 0 = +x, CCW).
pub fn polarPoint(angle: f32, radius: f32) Point(Pixels) {
    return .{
        .x = @cos(angle) * radius,
        .y = @sin(angle) * radius,
    };
}

// ---------------------------------------------------------------------------
// Thin bar-chart / line-chart shells
// ---------------------------------------------------------------------------

pub const BarDatum = struct {
    value: f32,
};

pub const BarStyleFn = *const fn (index: usize, value: f32) style_mod.Style;

pub const BarChartProps = struct {
    id: []const u8,
    values: []const f32,
    width: Pixels,
    height: Pixels,
    margins: Margins = .{ .top = 8, .right = 8, .bottom = 24, .left = 32 },
    /// Domain for the value axis; null → auto from data (floor at 0).
    value_domain: ?struct { min: f32, max: f32 } = null,
    bar_style_fn: ?BarStyleFn = null,
};

/// Render a vertical bar chart as absolutely positioned children.
pub fn barChart(arena: std.mem.Allocator, props: BarChartProps) *Div {
    var root = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .sizePx(props.width, props.height)
        .overflowHidden();

    var bg = style_mod.Style{};
    bg.background = Rgba.fromHex(0xf8fafc);
    root = root.withStyle(bg);

    const outer = Bounds(Pixels).init(.{}, .{ .width = props.width, .height = props.height });
    const area = plotArea(outer, props.margins);
    const band = ScaleBand.init(props.values.len, 0, area.size.width).withPadding(0.1, 0.05);

    const extent = domainExtent(props.values);
    const dmin = if (props.value_domain) |d| d.min else @min(@as(f32, 0), extent.min);
    const dmax = if (props.value_domain) |d| d.max else @max(@as(f32, 1), extent.max);
    // High values at the top of the plot area.
    const y_scale = ScaleLinear.init(dmin, dmax, area.size.height, 0);

    for (props.values, 0..) |value, i| {
        const bar = verticalBar(area, band, .{
            .domain_start = y_scale.domain_start,
            .domain_diff = y_scale.domain_diff,
            .range_start = area.origin.y + y_scale.range_start,
            .range_diff = y_scale.range_diff,
        }, i, value) orelse continue;

        const bar_id = std.fmt.allocPrint(arena, "{s}-bar-{d}", .{ props.id, i }) catch @panic("frame arena OOM");
        var panel = div_mod.div(arena).withId(bar_id).absolute().interactive();
        var s = style_mod.Style{};
        s.position = .absolute;
        s.inset.top = .{ .px = bar.origin.y };
        s.inset.left = .{ .px = bar.origin.x };
        s.width = .{ .px = bar.size.width };
        s.height = .{ .px = bar.size.height };
        s.background = Rgba.fromHex(0x3b82f6);
        if (props.bar_style_fn) |style_fn| {
            var styled = style_fn(i, value);
            styled.position = .absolute;
            styled.inset = s.inset;
            styled.width = s.width;
            styled.height = s.height;
            panel = panel.withStyle(styled);
        } else {
            panel = panel.withStyle(s);
        }
        root = root.childDiv(panel);
    }

    return root;
}

pub const DotStyleFn = *const fn (index: usize, value: f32) style_mod.Style;

pub const LineChartProps = struct {
    id: []const u8,
    values: []const f32,
    width: Pixels,
    height: Pixels,
    margins: Margins = .{ .top = 8, .right = 8, .bottom = 24, .left = 32 },
    value_domain: ?struct { min: f32, max: f32 } = null,
    dot_radius: Pixels = 4,
    dot_style_fn: ?DotStyleFn = null,
};

/// Render a line series as absolute dots (Path strokes stay app-side).
pub fn lineChart(arena: std.mem.Allocator, props: LineChartProps) *Div {
    var root = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .sizePx(props.width, props.height)
        .overflowHidden();

    var bg = style_mod.Style{};
    bg.background = Rgba.fromHex(0xf8fafc);
    root = root.withStyle(bg);

    if (props.values.len == 0) return root;

    const outer = Bounds(Pixels).init(.{}, .{ .width = props.width, .height = props.height });
    const area = plotArea(outer, props.margins);
    const extent = domainExtent(props.values);
    const dmin = if (props.value_domain) |d| d.min else extent.min;
    const dmax = if (props.value_domain) |d| d.max else @max(extent.max, extent.min + 1);

    var xs_buf: [64]f32 = undefined;
    const n = @min(props.values.len, xs_buf.len);
    for (0..n) |i| xs_buf[i] = @floatFromInt(i);
    const x_scale = ScaleLinear.init(0, @floatFromInt(@max(n, 2) - 1), 0, area.size.width);
    const y_scale = ScaleLinear.init(dmin, dmax, 0, area.size.height);

    var pts: [64]Point(Pixels) = undefined;
    const written = linePoints(area, x_scale, .{
        .domain_start = y_scale.domain_start,
        .domain_diff = y_scale.domain_diff,
        .range_start = area.size.height,
        .range_diff = -area.size.height,
    }, xs_buf[0..n], props.values[0..n], pts[0..n]);

    const r = props.dot_radius;
    for (pts[0..written], 0..) |pt, i| {
        const did = std.fmt.allocPrint(arena, "{s}-dot-{d}", .{ props.id, i }) catch @panic("frame arena OOM");
        var dot = div_mod.div(arena).withId(did).absolute().interactive();
        var s = style_mod.Style{};
        s.position = .absolute;
        s.inset.left = .{ .px = pt.x - r };
        s.inset.top = .{ .px = pt.y - r };
        s.width = .{ .px = r * 2 };
        s.height = .{ .px = r * 2 };
        s.corner_radii = geometry.Corners(Pixels).all(r);
        s.background = Rgba.fromHex(0x0ea5e9);
        if (props.dot_style_fn) |style_fn| {
            var styled = style_fn(i, props.values[i]);
            styled.position = .absolute;
            styled.inset = s.inset;
            styled.width = s.width;
            styled.height = s.height;
            styled.corner_radii = s.corner_radii;
            dot = dot.withStyle(styled);
        } else {
            dot = dot.withStyle(s);
        }
        root = root.childDiv(dot);
    }
    return root;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

test "ScaleLinear maps domain to range" {
    const scale = ScaleLinear.init(1, 3, 0, 100);
    try std.testing.expectEqual(@as(?f32, 0), scale.tick(1));
    try std.testing.expectEqual(@as(?f32, 50), scale.tick(2));
    try std.testing.expectEqual(@as(?f32, 100), scale.tick(3));

    const inv = ScaleLinear.init(1, 3, 100, 0);
    try std.testing.expectEqual(@as(?f32, 100), inv.tick(1));
    try std.testing.expectEqual(@as(?f32, 0), inv.tick(3));
    try std.testing.expectEqual(@as(?f32, 2), inv.invert(50));
}

test "ScaleBand tick and leastIndex" {
    const band = ScaleBand.init(3, 0, 300).withPadding(0, 0);
    try std.testing.expect(band.tick(0) != null);
    try std.testing.expectEqual(@as(usize, 0), band.leastIndex(0));
    try std.testing.expectEqual(@as(usize, 1), band.leastIndex(150));
    try std.testing.expectEqual(@as(usize, 2), band.leastIndex(299));
}

test "plotArea applies margins" {
    const outer = Bounds(Pixels).init(.{}, .{ .width = 200, .height = 100 });
    const area = plotArea(outer, .{ .top = 10, .right = 20, .bottom = 30, .left = 40 });
    try std.testing.expectEqual(@as(Pixels, 40), area.origin.x);
    try std.testing.expectEqual(@as(Pixels, 10), area.origin.y);
    try std.testing.expectEqual(@as(Pixels, 140), area.size.width);
    try std.testing.expectEqual(@as(Pixels, 60), area.size.height);
}

test "barChart lays out absolute bars" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 320, .height = 200 });
    defer harness.deinit();

    const Fixture = struct {
        fn render(_: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
            const values = [_]f32{ 10, 40, 25 };
            return barChart(arena, .{
                .id = "sales",
                .values = &values,
                .width = 320,
                .height = 200,
            }).any();
        }
    };

    var fixture: Fixture = .{};
    try harness.setRoot(&fixture, Fixture.render);
    const b0 = harness.hitboxBounds(element.elementId("sales-bar-0")).?;
    const b1 = harness.hitboxBounds(element.elementId("sales-bar-1")).?;
    try std.testing.expect(b1.size.height > b0.size.height);
    try std.testing.expect(b1.origin.x > b0.origin.x);
}

test "pieSlices and lineChart dots" {
    const values = [_]f32{ 1, 1, 2 };
    var slices: [3]PieSlice = undefined;
    const n = pieSlices(&values, 0, tau, &slices);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectApproxEqAbs(@as(f32, 0), slices[0].start_angle, 1e-5);
    try std.testing.expectApproxEqAbs(tau / 4, slices[0].end_angle, 1e-5);
    try std.testing.expectApproxEqAbs(tau / 2, slices[1].end_angle, 1e-5);
    try std.testing.expectApproxEqAbs(tau, slices[2].end_angle, 1e-5);

    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 280, .height = 160 });
    defer harness.deinit();
    const Fixture = struct {
        fn render(_: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
            const ys = [_]f32{ 1, 3, 2 };
            return lineChart(arena, .{
                .id = "trend",
                .values = &ys,
                .width = 280,
                .height = 160,
            }).any();
        }
    };
    var fixture: Fixture = .{};
    try harness.setRoot(&fixture, Fixture.render);
    try std.testing.expect(harness.hitboxBounds(element.elementId("trend-dot-0")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("trend-dot-2")) != null);
}
