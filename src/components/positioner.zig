//! Shared popup positioning (headless), aligned with gpui-base `Positioner`.
//!
//! Pure functions: preferred side + flip, alignment along that side, then
//! viewport clamp. Corner anchoring clamps without flipping.

const std = @import("std");
const geometry = @import("../geometry.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Size = geometry.Size;
const Bounds = geometry.Bounds;

pub const Placement = enum { top, bottom, left, right };

pub const Align = enum { start, center, end };

pub const SideRequest = struct {
    trigger: Bounds(Pixels),
    popup_size: Size(Pixels),
    viewport: Size(Pixels),
    preferred: Placement = .bottom,
    alignment: Align = .center,
    offset: Pixels = 4,
    margin: Pixels = 8,
};

pub const Resolved = struct {
    origin: Point(Pixels),
    placement: Placement,
};

pub fn resolveSide(req: SideRequest) Resolved {
    const placement = resolvePlacement(req);
    const origin = sideOrigin(req.trigger, req.popup_size, placement, req.alignment, req.offset);
    const clamped = clampBounds(.{ .origin = origin, .size = req.popup_size }, req.viewport, req.margin);
    return .{ .origin = clamped.origin, .placement = placement };
}

/// Place the popup's top-left at `anchor_point`, then clamp into the viewport.
/// Never flips to another side (context-menu / point-anchor path).
pub fn resolveCorner(
    anchor_point: Point(Pixels),
    popup_size: Size(Pixels),
    viewport: Size(Pixels),
    margin: Pixels,
) Point(Pixels) {
    const clamped = clampBounds(.{ .origin = anchor_point, .size = popup_size }, viewport, margin);
    return clamped.origin;
}

fn resolvePlacement(req: SideRequest) Placement {
    const margin = req.margin;
    const right_limit = @max(req.viewport.width - margin, margin);
    const bottom_limit = @max(req.viewport.height - margin, margin);
    const available_left = @max(req.trigger.origin.x - margin, @as(Pixels, 0));
    const available_right = @max(right_limit - req.trigger.right(), @as(Pixels, 0));
    const available_above = @max(req.trigger.origin.y - margin, @as(Pixels, 0));
    const available_below = @max(bottom_limit - req.trigger.bottom(), @as(Pixels, 0));
    const w = req.popup_size.width;
    const h = req.popup_size.height;

    return switch (req.preferred) {
        .right => blk: {
            if (w <= available_right) break :blk .right;
            if (w <= available_left) break :blk .left;
            break :blk if (available_right >= available_left) .right else .left;
        },
        .left => blk: {
            if (w <= available_left) break :blk .left;
            if (w <= available_right) break :blk .right;
            break :blk if (available_left >= available_right) .left else .right;
        },
        .bottom => blk: {
            if (h <= available_below) break :blk .bottom;
            if (h <= available_above) break :blk .top;
            break :blk if (available_below >= available_above) .bottom else .top;
        },
        .top => blk: {
            if (h <= available_above) break :blk .top;
            if (h <= available_below) break :blk .bottom;
            break :blk if (available_below >= available_above) .bottom else .top;
        },
    };
}

fn sideOrigin(
    trigger: Bounds(Pixels),
    popup_size: Size(Pixels),
    placement: Placement,
    alignment: Align,
    offset: Pixels,
) Point(Pixels) {
    const aligned_x: Pixels = switch (alignment) {
        .start => trigger.origin.x,
        .center => trigger.center().x - popup_size.width / 2,
        .end => trigger.right() - popup_size.width,
    };
    const aligned_y: Pixels = switch (alignment) {
        .start => trigger.origin.y,
        .center => trigger.center().y - popup_size.height / 2,
        .end => trigger.bottom() - popup_size.height,
    };

    return switch (placement) {
        .top => .{ .x = aligned_x, .y = trigger.origin.y - popup_size.height - offset },
        .bottom => .{ .x = aligned_x, .y = trigger.bottom() + offset },
        .left => .{ .x = trigger.origin.x - popup_size.width - offset, .y = aligned_y },
        .right => .{ .x = trigger.right() + offset, .y = aligned_y },
    };
}

fn clampBounds(bounds_in: Bounds(Pixels), viewport: Size(Pixels), margin: Pixels) Bounds(Pixels) {
    var bounds = bounds_in;
    const right_limit = @max(viewport.width - margin, margin);
    const bottom_limit = @max(viewport.height - margin, margin);

    if (bounds.right() > right_limit) {
        bounds.origin.x -= bounds.right() - right_limit;
    }
    if (bounds.origin.x < margin) {
        bounds.origin.x = margin;
    }
    if (bounds.bottom() > bottom_limit) {
        bounds.origin.y -= bounds.bottom() - bottom_limit;
    }
    if (bounds.origin.y < margin) {
        bounds.origin.y = margin;
    }
    return bounds;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolveSide prefers bottom when space fits" {
    const resolved = resolveSide(.{
        .trigger = Bounds(Pixels).init(.{ .x = 200, .y = 100 }, .{ .width = 40, .height = 20 }),
        .popup_size = .{ .width = 80, .height = 30 },
        .viewport = .{ .width = 500, .height = 400 },
        .preferred = .bottom,
        .alignment = .start,
        .offset = 4,
        .margin = 8,
    });
    try std.testing.expectEqual(Placement.bottom, resolved.placement);
    try std.testing.expectEqual(@as(Pixels, 200), resolved.origin.x);
    try std.testing.expectEqual(@as(Pixels, 124), resolved.origin.y);
}

test "resolveSide flips to top when trigger is near bottom" {
    const resolved = resolveSide(.{
        .trigger = Bounds(Pixels).init(.{ .x = 200, .y = 360 }, .{ .width = 40, .height = 20 }),
        .popup_size = .{ .width = 80, .height = 60 },
        .viewport = .{ .width = 500, .height = 400 },
        .preferred = .bottom,
        .alignment = .center,
        .offset = 4,
        .margin = 8,
    });
    try std.testing.expectEqual(Placement.top, resolved.placement);
    try std.testing.expectEqual(@as(Pixels, 296), resolved.origin.y); // 360 - 60 - 4
}

test "resolveSide clamps end-aligned popup on the right edge" {
    const resolved = resolveSide(.{
        .trigger = Bounds(Pixels).init(.{ .x = 480, .y = 100 }, .{ .width = 20, .height = 20 }),
        .popup_size = .{ .width = 120, .height = 30 },
        .viewport = .{ .width = 500, .height = 400 },
        .preferred = .bottom,
        .alignment = .end,
        .offset = 0,
        .margin = 8,
    });
    try std.testing.expectEqual(Placement.bottom, resolved.placement);
    // end-align wants x=380 → right edge 500; clamp keeps margin 8
    try std.testing.expectEqual(@as(Pixels, 372), resolved.origin.x);
    try std.testing.expectEqual(@as(Pixels, 492), resolved.origin.x + 120);
}

test "resolveCorner clamps without flipping" {
    const origin = resolveCorner(
        .{ .x = 480, .y = 390 },
        .{ .width = 40, .height = 30 },
        .{ .width = 500, .height = 400 },
        8,
    );
    try std.testing.expectEqual(@as(Pixels, 452), origin.x); // 500 - 8 - 40
    try std.testing.expectEqual(@as(Pixels, 362), origin.y); // 400 - 8 - 30
}

test "resolveSide alignment start center end" {
    const trigger = Bounds(Pixels).init(.{ .x = 200, .y = 200 }, .{ .width = 100, .height = 20 });
    const popup = Size(Pixels).init(40, 30);

    const start = resolveSide(.{
        .trigger = trigger,
        .popup_size = popup,
        .viewport = .{ .width = 500, .height = 400 },
        .preferred = .bottom,
        .alignment = .start,
        .offset = 0,
        .margin = 4,
    });
    const center = resolveSide(.{
        .trigger = trigger,
        .popup_size = popup,
        .viewport = .{ .width = 500, .height = 400 },
        .preferred = .bottom,
        .alignment = .center,
        .offset = 0,
        .margin = 4,
    });
    const end = resolveSide(.{
        .trigger = trigger,
        .popup_size = popup,
        .viewport = .{ .width = 500, .height = 400 },
        .preferred = .bottom,
        .alignment = .end,
        .offset = 0,
        .margin = 4,
    });

    try std.testing.expectEqual(@as(Pixels, 200), start.origin.x);
    try std.testing.expectEqual(@as(Pixels, 230), center.origin.x);
    try std.testing.expectEqual(@as(Pixels, 260), end.origin.x);
}
