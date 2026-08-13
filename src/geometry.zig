//! Core geometry types, modeled on gpui's `geometry.rs` but Zig-idiomatic.
//! All UI-facing lengths are logical pixels (`Pixels`, f32). Device pixels are
//! obtained by multiplying with the window scale factor.

const std = @import("std");

/// Logical pixels (device-independent).
pub const Pixels = f32;

/// Device pixels (after scale factor is applied).
pub const DevicePixels = i32;

pub fn Point(comptime T: type) type {
    return struct {
        x: T = 0,
        y: T = 0,

        const Self = @This();

        pub fn init(x: T, y: T) Self {
            return .{ .x = x, .y = y };
        }

        pub fn add(self: Self, other: Self) Self {
            return .{ .x = self.x + other.x, .y = self.y + other.y };
        }

        pub fn sub(self: Self, other: Self) Self {
            return .{ .x = self.x - other.x, .y = self.y - other.y };
        }

        pub fn scale(self: Self, factor: T) Self {
            return .{ .x = self.x * factor, .y = self.y * factor };
        }

        pub fn max(self: Self, other: Self) Self {
            return .{ .x = @max(self.x, other.x), .y = @max(self.y, other.y) };
        }

        pub fn min(self: Self, other: Self) Self {
            return .{ .x = @min(self.x, other.x), .y = @min(self.y, other.y) };
        }
    };
}

pub fn Size(comptime T: type) type {
    return struct {
        width: T = 0,
        height: T = 0,

        const Self = @This();

        pub fn init(width: T, height: T) Self {
            return .{ .width = width, .height = height };
        }

        pub fn scale(self: Self, factor: T) Self {
            return .{ .width = self.width * factor, .height = self.height * factor };
        }

        pub fn max(self: Self, other: Self) Self {
            return .{
                .width = @max(self.width, other.width),
                .height = @max(self.height, other.height),
            };
        }
    };
}

pub fn Bounds(comptime T: type) type {
    return struct {
        origin: Point(T) = .{},
        size: Size(T) = .{},

        const Self = @This();

        pub fn init(origin: Point(T), size: Size(T)) Self {
            return .{ .origin = origin, .size = size };
        }

        pub fn fromCorners(top_left: Point(T), bottom_right: Point(T)) Self {
            return .{
                .origin = top_left,
                .size = .{
                    .width = bottom_right.x - top_left.x,
                    .height = bottom_right.y - top_left.y,
                },
            };
        }

        pub fn right(self: Self) T {
            return self.origin.x + self.size.width;
        }

        pub fn bottom(self: Self) T {
            return self.origin.y + self.size.height;
        }

        pub fn center(self: Self) Point(T) {
            return .{
                .x = self.origin.x + @divTrunc(self.size.width, 2),
                .y = self.origin.y + @divTrunc(self.size.height, 2),
            };
        }

        pub fn contains(self: Self, point: Point(T)) bool {
            return point.x >= self.origin.x and point.x < self.right() and
                point.y >= self.origin.y and point.y < self.bottom();
        }

        pub fn intersects(self: Self, other: Self) bool {
            return self.origin.x < other.right() and other.origin.x < self.right() and
                self.origin.y < other.bottom() and other.origin.y < self.bottom();
        }

        pub fn intersect(self: Self, other: Self) Self {
            const tl = self.origin.max(other.origin);
            const br = Point(T){
                .x = @min(self.right(), other.right()),
                .y = @min(self.bottom(), other.bottom()),
            };
            return .{
                .origin = tl,
                .size = .{
                    .width = @max(br.x - tl.x, 0),
                    .height = @max(br.y - tl.y, 0),
                },
            };
        }

        pub fn @"union"(self: Self, other: Self) Self {
            const tl = self.origin.min(other.origin);
            const br = Point(T){
                .x = @max(self.right(), other.right()),
                .y = @max(self.bottom(), other.bottom()),
            };
            return fromCorners(tl, br);
        }

        pub fn dilate(self: Self, amount: T) Self {
            return .{
                .origin = .{ .x = self.origin.x - amount, .y = self.origin.y - amount },
                .size = .{
                    .width = self.size.width + amount * 2,
                    .height = self.size.height + amount * 2,
                },
            };
        }

        pub fn isEmpty(self: Self) bool {
            return self.size.width <= 0 or self.size.height <= 0;
        }

        /// Clamp to `[0, framebuffer)`; may become empty if fully outside.
        pub fn clampToFramebuffer(self: Self, framebuffer: Size(T)) Self {
            const fb_w = @max(framebuffer.width, 0);
            const fb_h = @max(framebuffer.height, 0);
            const x0 = @max(self.origin.x, 0);
            const y0 = @max(self.origin.y, 0);
            const x1 = @min(self.right(), fb_w);
            const y1 = @min(self.bottom(), fb_h);
            return .{
                .origin = .{ .x = x0, .y = y0 },
                .size = .{
                    .width = @max(x1 - x0, 0),
                    .height = @max(y1 - y0, 0),
                },
            };
        }
    };
}

/// Convert logical dirty bounds to device-pixel bounds (floor origin, ceil size).
pub fn toDevicePixels(bounds: Bounds(Pixels), scale: f32) Bounds(DevicePixels) {
    const x = @as(DevicePixels, @intFromFloat(@floor(bounds.origin.x * scale)));
    const y = @as(DevicePixels, @intFromFloat(@floor(bounds.origin.y * scale)));
    const w = @as(DevicePixels, @intFromFloat(@ceil(bounds.size.width * scale)));
    const h = @as(DevicePixels, @intFromFloat(@ceil(bounds.size.height * scale)));
    return .{
        .origin = .{ .x = x, .y = y },
        .size = .{ .width = w, .height = h },
    };
}

pub fn Corners(comptime T: type) type {
    return struct {
        top_left: T,
        top_right: T,
        bottom_right: T,
        bottom_left: T,

        const Self = @This();

        /// Only valid for numeric T (lazily analyzed).
        pub const zero: Self = .{
            .top_left = 0,
            .top_right = 0,
            .bottom_right = 0,
            .bottom_left = 0,
        };

        pub fn all(value: T) Self {
            return .{
                .top_left = value,
                .top_right = value,
                .bottom_right = value,
                .bottom_left = value,
            };
        }

        pub fn scale(self: Self, factor: T) Self {
            return .{
                .top_left = self.top_left * factor,
                .top_right = self.top_right * factor,
                .bottom_right = self.bottom_right * factor,
                .bottom_left = self.bottom_left * factor,
            };
        }

        pub fn maxRadius(self: Self) T {
            return @max(
                @max(self.top_left, self.top_right),
                @max(self.bottom_right, self.bottom_left),
            );
        }
    };
}

pub fn Edges(comptime T: type) type {
    return struct {
        top: T,
        right: T,
        bottom: T,
        left: T,

        const Self = @This();

        /// Only valid for numeric T (lazily analyzed).
        pub const zero: Self = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 };

        pub fn all(value: T) Self {
            return .{ .top = value, .right = value, .bottom = value, .left = value };
        }

        pub fn scale(self: Self, factor: T) Self {
            return .{
                .top = self.top * factor,
                .right = self.right * factor,
                .bottom = self.bottom * factor,
                .left = self.left * factor,
            };
        }
    };
}

test "bounds contains and intersect" {
    const b1 = Bounds(f32).init(.{ .x = 0, .y = 0 }, .{ .width = 100, .height = 100 });
    const b2 = Bounds(f32).init(.{ .x = 50, .y = 50 }, .{ .width = 100, .height = 100 });

    try std.testing.expect(b1.contains(.{ .x = 50, .y = 50 }));
    try std.testing.expect(!b1.contains(.{ .x = 100, .y = 100 }));
    try std.testing.expect(b1.intersects(b2));

    const overlap = b1.intersect(b2);
    try std.testing.expectEqual(@as(f32, 50), overlap.origin.x);
    try std.testing.expectEqual(@as(f32, 50), overlap.size.width);
}

test "corners all and max" {
    const c = Corners(f32).all(4);
    try std.testing.expectEqual(@as(f32, 4), c.maxRadius());
}

test "toDevicePixels floor origin ceil size" {
    const logical = Bounds(Pixels).init(.{ .x = 10.2, .y = 20.7 }, .{ .width = 30.1, .height = 40.9 });
    const device = toDevicePixels(logical, 2.0);
    try std.testing.expectEqual(@as(DevicePixels, 20), device.origin.x);
    try std.testing.expectEqual(@as(DevicePixels, 41), device.origin.y);
    try std.testing.expectEqual(@as(DevicePixels, 61), device.size.width);
    try std.testing.expectEqual(@as(DevicePixels, 82), device.size.height);
}

test "clampToFramebuffer" {
    const bounds = Bounds(i32).init(.{ .x = -5, .y = 10 }, .{ .width = 100, .height = 50 });
    const clamped = bounds.clampToFramebuffer(.{ .width = 80, .height = 40 });
    try std.testing.expectEqual(@as(i32, 0), clamped.origin.x);
    try std.testing.expectEqual(@as(i32, 10), clamped.origin.y);
    try std.testing.expectEqual(@as(i32, 80), clamped.size.width);
    try std.testing.expectEqual(@as(i32, 30), clamped.size.height);
}
