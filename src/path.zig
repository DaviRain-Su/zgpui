//! CPU-side path builder: polylines and cubic beziers tessellated into
//! triangle lists for the path render pipeline.
//!
//! Coordinates are logical pixels (same space as Scene). The builder does
//! not own GPU resources — call `scene.insertPath` with the emitted vertices.

const std = @import("std");
const geometry = @import("geometry.zig");
const color = @import("color.zig");
const scene_mod = @import("scene.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Rgba = color.Rgba;

pub const PathVertex = scene_mod.PathVertex;

pub const PathBuilder = struct {
    allocator: std.mem.Allocator,
    /// Polyline points for the current contour (not yet stroked).
    points: std.ArrayList(Point(Pixels)),
    /// Triangle-list vertices ready for the GPU.
    vertices: std.ArrayList(PathVertex),
    color: Rgba = Rgba.black,
    has_point: bool = false,
    current: Point(Pixels) = .{},

    pub fn init(allocator: std.mem.Allocator) PathBuilder {
        return .{
            .allocator = allocator,
            .points = .empty,
            .vertices = .empty,
        };
    }

    pub fn deinit(self: *PathBuilder) void {
        self.points.deinit(self.allocator);
        self.vertices.deinit(self.allocator);
    }

    pub fn clear(self: *PathBuilder) void {
        self.points.clearRetainingCapacity();
        self.vertices.clearRetainingCapacity();
        self.has_point = false;
        self.current = .{};
    }

    pub fn setColor(self: *PathBuilder, c: Rgba) *PathBuilder {
        self.color = c;
        return self;
    }

    pub fn moveTo(self: *PathBuilder, x: Pixels, y: Pixels) !void {
        try self.flushContourAsPolyline();
        self.points.clearRetainingCapacity();
        self.current = .{ .x = x, .y = y };
        self.has_point = true;
        try self.points.append(self.allocator, self.current);
    }

    pub fn lineTo(self: *PathBuilder, x: Pixels, y: Pixels) !void {
        if (!self.has_point) {
            try self.moveTo(x, y);
            return;
        }
        self.current = .{ .x = x, .y = y };
        try self.points.append(self.allocator, self.current);
    }

    /// Approximate a cubic bezier with `segments` line segments (default 16).
    pub fn cubicTo(
        self: *PathBuilder,
        c1x: Pixels,
        c1y: Pixels,
        c2x: Pixels,
        c2y: Pixels,
        x: Pixels,
        y: Pixels,
        segments: u32,
    ) !void {
        if (!self.has_point) try self.moveTo(c1x, c1y);
        const p0 = self.current;
        const p1 = Point(Pixels){ .x = c1x, .y = c1y };
        const p2 = Point(Pixels){ .x = c2x, .y = c2y };
        const p3 = Point(Pixels){ .x = x, .y = y };
        const n = @max(segments, 1);
        var i: u32 = 1;
        while (i <= n) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const pt = cubicPoint(p0, p1, p2, p3, t);
            try self.lineTo(pt.x, pt.y);
        }
    }

    pub fn close(self: *PathBuilder) !void {
        if (self.points.items.len >= 2) {
            const first = self.points.items[0];
            try self.lineTo(first.x, first.y);
        }
    }

    /// Stroke the current contour as a triangle strip-of-quads with the given
    /// width, then clear the contour points (vertices accumulate).
    pub fn stroke(self: *PathBuilder, width: Pixels) !void {
        try strokePolyline(self.allocator, &self.vertices, self.points.items, width, self.color);
        self.points.clearRetainingCapacity();
        self.has_point = false;
    }

    /// Fill the current contour as a triangle fan (must be convex). Clears
    /// contour points.
    pub fn fillConvex(self: *PathBuilder) !void {
        try fillConvexPolygon(self.allocator, &self.vertices, self.points.items, self.color);
        self.points.clearRetainingCapacity();
        self.has_point = false;
    }

    fn flushContourAsPolyline(self: *PathBuilder) !void {
        // Contours are only committed via stroke/fill; moveTo starts a new one.
        _ = self;
    }
};

fn cubicPoint(p0: Point(Pixels), p1: Point(Pixels), p2: Point(Pixels), p3: Point(Pixels), t: f32) Point(Pixels) {
    const u = 1.0 - t;
    const tt = t * t;
    const uu = u * u;
    const uuu = uu * u;
    const ttt = tt * t;
    return .{
        .x = uuu * p0.x + 3 * uu * t * p1.x + 3 * u * tt * p2.x + ttt * p3.x,
        .y = uuu * p0.y + 3 * uu * t * p1.y + 3 * u * tt * p2.y + ttt * p3.y,
    };
}

fn vertex(p: Point(Pixels), c: Rgba) PathVertex {
    return .{
        .x = p.x,
        .y = p.y,
        .color = scene_mod.ColorF.from(c),
    };
}

fn emitTriangle(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(PathVertex),
    a: Point(Pixels),
    b: Point(Pixels),
    c: Point(Pixels),
    color_v: Rgba,
) !void {
    try out.append(allocator, vertex(a, color_v));
    try out.append(allocator, vertex(b, color_v));
    try out.append(allocator, vertex(c, color_v));
}

/// Stroke a polyline as independent segment quads (miter-less; gaps at sharp
/// corners are acceptable for UI hairlines / underlines / icons).
pub fn strokePolyline(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(PathVertex),
    points: []const Point(Pixels),
    width: Pixels,
    color_v: Rgba,
) !void {
    if (points.len < 2 or width <= 0) return;
    const half = width * 0.5;
    var i: usize = 0;
    while (i + 1 < points.len) : (i += 1) {
        const a = points[i];
        const b = points[i + 1];
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 1e-6) continue;
        const nx = -dy / len * half;
        const ny = dx / len * half;
        const a0 = Point(Pixels){ .x = a.x + nx, .y = a.y + ny };
        const a1 = Point(Pixels){ .x = a.x - nx, .y = a.y - ny };
        const b0 = Point(Pixels){ .x = b.x + nx, .y = b.y + ny };
        const b1 = Point(Pixels){ .x = b.x - nx, .y = b.y - ny };
        try emitTriangle(allocator, out, a0, b0, b1, color_v);
        try emitTriangle(allocator, out, a0, b1, a1, color_v);
    }
}

pub fn fillConvexPolygon(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(PathVertex),
    points: []const Point(Pixels),
    color_v: Rgba,
) !void {
    if (points.len < 3) return;
    const pivot = points[0];
    var i: usize = 1;
    while (i + 1 < points.len) : (i += 1) {
        try emitTriangle(allocator, out, pivot, points[i], points[i + 1], color_v);
    }
}

test "stroke polyline emits two triangles per segment" {
    var verts: std.ArrayList(PathVertex) = .empty;
    defer verts.deinit(std.testing.allocator);

    const pts = [_]Point(Pixels){
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
    };
    try strokePolyline(std.testing.allocator, &verts, &pts, 2, Rgba.black);
    try std.testing.expectEqual(@as(usize, 12), verts.items.len); // 2 segments * 6 verts
}

test "path builder cubic produces vertices after stroke" {
    var builder = PathBuilder.init(std.testing.allocator);
    defer builder.deinit();

    try builder.moveTo(0, 0);
    try builder.cubicTo(10, 0, 10, 20, 0, 20, 8);
    try builder.setColor(Rgba.red).stroke(2);
    try std.testing.expect(builder.vertices.items.len >= 6);
}

test "fillConvex triangle" {
    var builder = PathBuilder.init(std.testing.allocator);
    defer builder.deinit();

    try builder.moveTo(0, 0);
    try builder.lineTo(10, 0);
    try builder.lineTo(0, 10);
    try builder.fillConvex();
    try std.testing.expectEqual(@as(usize, 3), builder.vertices.items.len);
}
