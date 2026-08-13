//! Scene: the list of draw primitives produced by painting a frame,
//! modeled on gpui's `scene.rs`.
//!
//! All coordinates are logical pixels; the renderer applies the window
//! scale factor. Primitives carry a monotonically increasing draw `order`
//! so the renderer can batch by primitive kind while preserving z-order.

const std = @import("std");
const geometry = @import("geometry.zig");
const color = @import("color.zig");

const Bounds = geometry.Bounds;
const Corners = geometry.Corners;
const Edges = geometry.Edges;
const Pixels = geometry.Pixels;
const Rgba = color.Rgba;

pub const DrawOrder = u32;

/// A rectangle with background, border and corner radii, rendered with an
/// SDF shader.
pub const Quad = extern struct {
    order: DrawOrder = 0,
    _pad: u32 = 0,
    bounds: BoundsF = .{},
    clip_bounds: BoundsF = .{},
    background: ColorF = .{},
    border_color: ColorF = .{},
    corner_radii: CornersF = .{},
    border_widths: EdgesF = .{},
};

/// A blurred drop shadow behind a rounded rectangle.
pub const Shadow = extern struct {
    order: DrawOrder = 0,
    blur_radius: f32 = 0,
    bounds: BoundsF = .{},
    clip_bounds: BoundsF = .{},
    corner_radii: CornersF = .{},
    color: ColorF = .{},
};

/// A single-channel (alpha) sprite from the glyph/icon atlas, tinted with a
/// color. Used for text glyphs and monochrome icons.
pub const MonochromeSprite = extern struct {
    order: DrawOrder = 0,
    _pad: u32 = 0,
    bounds: BoundsF = .{},
    clip_bounds: BoundsF = .{},
    /// Texel rectangle in the atlas.
    uv_bounds: BoundsF = .{},
    color: ColorF = .{},
};

/// A full-color sprite (images, emoji).
pub const PolychromeSprite = extern struct {
    order: DrawOrder = 0,
    opacity: f32 = 1,
    bounds: BoundsF = .{},
    clip_bounds: BoundsF = .{},
    uv_bounds: BoundsF = .{},
};

/// GPU-friendly plain structs (extern layout, f32 fields) mirrored by the
/// WGSL shader definitions in `renderer/shaders/*.wgsl`.
pub const BoundsF = extern struct {
    origin_x: f32 = 0,
    origin_y: f32 = 0,
    size_w: f32 = 0,
    size_h: f32 = 0,

    pub fn from(b: Bounds(Pixels)) BoundsF {
        return .{
            .origin_x = b.origin.x,
            .origin_y = b.origin.y,
            .size_w = b.size.width,
            .size_h = b.size.height,
        };
    }
};

pub const CornersF = extern struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_right: f32 = 0,
    bottom_left: f32 = 0,

    pub fn from(c: Corners(Pixels)) CornersF {
        return .{
            .top_left = c.top_left,
            .top_right = c.top_right,
            .bottom_right = c.bottom_right,
            .bottom_left = c.bottom_left,
        };
    }
};

pub const EdgesF = extern struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn from(e: Edges(Pixels)) EdgesF {
        return .{ .top = e.top, .right = e.right, .bottom = e.bottom, .left = e.left };
    }
};

pub const ColorF = extern struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,

    pub fn from(c: Rgba) ColorF {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
    }
};

/// One vertex of a triangle-list path (logical pixels).
pub const PathVertex = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    color: ColorF = .{},
};

/// A draw range into `Scene.path_vertices`, ordered with other primitives.
pub const PathRange = struct {
    order: DrawOrder = 0,
    clip_bounds: BoundsF = .{},
    start: u32 = 0,
    count: u32 = 0,
};

pub const PrimitiveKind = enum {
    shadow,
    quad,
    monochrome_sprite,
    polychrome_sprite,
    path,
};

/// A batch of consecutive primitives of the same kind, in draw order.
/// Indices refer to the scene's per-kind arrays.
pub const Batch = struct {
    kind: PrimitiveKind,
    start: usize,
    end: usize,
};

pub const Scene = struct {
    allocator: std.mem.Allocator,
    shadows: std.ArrayList(Shadow),
    quads: std.ArrayList(Quad),
    monochrome_sprites: std.ArrayList(MonochromeSprite),
    polychrome_sprites: std.ArrayList(PolychromeSprite),
    path_vertices: std.ArrayList(PathVertex),
    path_ranges: std.ArrayList(PathRange),
    next_order: DrawOrder,

    pub fn init(allocator: std.mem.Allocator) Scene {
        return .{
            .allocator = allocator,
            .shadows = .empty,
            .quads = .empty,
            .monochrome_sprites = .empty,
            .polychrome_sprites = .empty,
            .path_vertices = .empty,
            .path_ranges = .empty,
            .next_order = 0,
        };
    }

    pub fn deinit(self: *Scene) void {
        self.shadows.deinit(self.allocator);
        self.quads.deinit(self.allocator);
        self.monochrome_sprites.deinit(self.allocator);
        self.polychrome_sprites.deinit(self.allocator);
        self.path_vertices.deinit(self.allocator);
        self.path_ranges.deinit(self.allocator);
    }

    /// Reset for a new frame, keeping allocated capacity.
    pub fn clear(self: *Scene) void {
        self.shadows.clearRetainingCapacity();
        self.quads.clearRetainingCapacity();
        self.monochrome_sprites.clearRetainingCapacity();
        self.polychrome_sprites.clearRetainingCapacity();
        self.path_vertices.clearRetainingCapacity();
        self.path_ranges.clearRetainingCapacity();
        self.next_order = 0;
    }

    fn nextOrder(self: *Scene) DrawOrder {
        const order = self.next_order;
        self.next_order += 1;
        return order;
    }

    pub fn insertShadow(self: *Scene, shadow: Shadow) !void {
        var s = shadow;
        s.order = self.nextOrder();
        try self.shadows.append(self.allocator, s);
    }

    pub fn insertQuad(self: *Scene, quad: Quad) !void {
        var q = quad;
        q.order = self.nextOrder();
        try self.quads.append(self.allocator, q);
    }

    pub fn insertMonochromeSprite(self: *Scene, sprite: MonochromeSprite) !void {
        var s = sprite;
        s.order = self.nextOrder();
        try self.monochrome_sprites.append(self.allocator, s);
    }

    pub fn insertPolychromeSprite(self: *Scene, sprite: PolychromeSprite) !void {
        var s = sprite;
        s.order = self.nextOrder();
        try self.polychrome_sprites.append(self.allocator, s);
    }

    /// Append a triangle-list path. `vertices.len` must be a multiple of 3.
    pub fn insertPath(self: *Scene, vertices: []const PathVertex, clip_bounds: BoundsF) !void {
        std.debug.assert(vertices.len % 3 == 0);
        if (vertices.len == 0) return;
        const start: u32 = @intCast(self.path_vertices.items.len);
        try self.path_vertices.appendSlice(self.allocator, vertices);
        try self.path_ranges.append(self.allocator, .{
            .order = self.nextOrder(),
            .clip_bounds = clip_bounds,
            .start = start,
            .count = @intCast(vertices.len),
        });
    }

    pub fn isEmpty(self: *const Scene) bool {
        return self.next_order == 0;
    }

    /// Iterate batches of same-kind primitives in global draw order.
    pub fn batches(self: *const Scene) BatchIterator {
        return .{ .scene = self };
    }
};

/// Merges the per-kind arrays (each already sorted by order) into contiguous
/// same-kind runs, preserving global draw order — gpui's BatchIterator.
pub const BatchIterator = struct {
    scene: *const Scene,
    shadow_i: usize = 0,
    quad_i: usize = 0,
    mono_i: usize = 0,
    poly_i: usize = 0,
    path_i: usize = 0,

    const max_order = std.math.maxInt(DrawOrder);

    fn headOrder(self: *const BatchIterator, kind: PrimitiveKind) DrawOrder {
        return switch (kind) {
            .shadow => if (self.shadow_i < self.scene.shadows.items.len)
                self.scene.shadows.items[self.shadow_i].order
            else
                max_order,
            .quad => if (self.quad_i < self.scene.quads.items.len)
                self.scene.quads.items[self.quad_i].order
            else
                max_order,
            .monochrome_sprite => if (self.mono_i < self.scene.monochrome_sprites.items.len)
                self.scene.monochrome_sprites.items[self.mono_i].order
            else
                max_order,
            .polychrome_sprite => if (self.poly_i < self.scene.polychrome_sprites.items.len)
                self.scene.polychrome_sprites.items[self.poly_i].order
            else
                max_order,
            .path => if (self.path_i < self.scene.path_ranges.items.len)
                self.scene.path_ranges.items[self.path_i].order
            else
                max_order,
        };
    }

    pub fn next(self: *BatchIterator) ?Batch {
        var best_kind: ?PrimitiveKind = null;
        var best_order: DrawOrder = max_order;
        inline for (@typeInfo(PrimitiveKind).@"enum".fields) |field| {
            const kind: PrimitiveKind = @enumFromInt(field.value);
            const order = self.headOrder(kind);
            if (order < best_order) {
                best_order = order;
                best_kind = kind;
            }
        }
        const kind = best_kind orelse return null;

        // Extend the batch while the next primitive in global order is the
        // same kind.
        switch (kind) {
            .shadow => {
                const start = self.shadow_i;
                self.shadow_i += 1;
                while (self.headOrder(.shadow) < self.minOtherOrder(.shadow)) self.shadow_i += 1;
                return .{ .kind = kind, .start = start, .end = self.shadow_i };
            },
            .quad => {
                const start = self.quad_i;
                self.quad_i += 1;
                while (self.headOrder(.quad) < self.minOtherOrder(.quad)) self.quad_i += 1;
                return .{ .kind = kind, .start = start, .end = self.quad_i };
            },
            .monochrome_sprite => {
                const start = self.mono_i;
                self.mono_i += 1;
                while (self.headOrder(.monochrome_sprite) < self.minOtherOrder(.monochrome_sprite)) self.mono_i += 1;
                return .{ .kind = kind, .start = start, .end = self.mono_i };
            },
            .polychrome_sprite => {
                const start = self.poly_i;
                self.poly_i += 1;
                while (self.headOrder(.polychrome_sprite) < self.minOtherOrder(.polychrome_sprite)) self.poly_i += 1;
                return .{ .kind = kind, .start = start, .end = self.poly_i };
            },
            .path => {
                const start = self.path_i;
                self.path_i += 1;
                while (self.headOrder(.path) < self.minOtherOrder(.path)) self.path_i += 1;
                return .{ .kind = kind, .start = start, .end = self.path_i };
            },
        }
    }

    fn minOtherOrder(self: *const BatchIterator, comptime kind: PrimitiveKind) DrawOrder {
        var min_order: DrawOrder = max_order;
        inline for (@typeInfo(PrimitiveKind).@"enum".fields) |field| {
            const other: PrimitiveKind = @enumFromInt(field.value);
            if (other != kind) {
                min_order = @min(min_order, self.headOrder(other));
            }
        }
        return min_order;
    }
};

test "scene assigns increasing draw order" {
    var scene = Scene.init(std.testing.allocator);
    defer scene.deinit();

    try scene.insertQuad(.{});
    try scene.insertShadow(.{});
    try scene.insertQuad(.{});

    try std.testing.expectEqual(@as(DrawOrder, 0), scene.quads.items[0].order);
    try std.testing.expectEqual(@as(DrawOrder, 1), scene.shadows.items[0].order);
    try std.testing.expectEqual(@as(DrawOrder, 2), scene.quads.items[1].order);
}

test "batch iterator preserves global order and batches runs" {
    var scene = Scene.init(std.testing.allocator);
    defer scene.deinit();

    // shadow, quad, quad, sprite, quad
    try scene.insertShadow(.{});
    try scene.insertQuad(.{});
    try scene.insertQuad(.{});
    try scene.insertMonochromeSprite(.{});
    try scene.insertQuad(.{});

    var it = scene.batches();

    const b1 = it.next().?;
    try std.testing.expectEqual(PrimitiveKind.shadow, b1.kind);
    try std.testing.expectEqual(@as(usize, 0), b1.start);
    try std.testing.expectEqual(@as(usize, 1), b1.end);

    const b2 = it.next().?;
    try std.testing.expectEqual(PrimitiveKind.quad, b2.kind);
    try std.testing.expectEqual(@as(usize, 0), b2.start);
    try std.testing.expectEqual(@as(usize, 2), b2.end);

    const b3 = it.next().?;
    try std.testing.expectEqual(PrimitiveKind.monochrome_sprite, b3.kind);

    const b4 = it.next().?;
    try std.testing.expectEqual(PrimitiveKind.quad, b4.kind);
    try std.testing.expectEqual(@as(usize, 2), b4.start);
    try std.testing.expectEqual(@as(usize, 3), b4.end);

    try std.testing.expectEqual(@as(?Batch, null), it.next());
}

test "clear retains capacity and resets order" {
    var scene = Scene.init(std.testing.allocator);
    defer scene.deinit();

    try scene.insertQuad(.{});
    scene.clear();
    try std.testing.expect(scene.isEmpty());
    try scene.insertQuad(.{});
    try std.testing.expectEqual(@as(DrawOrder, 0), scene.quads.items[0].order);
}
