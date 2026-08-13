//! Dirty-region bookkeeping for incremental redraw.
//!
//! Tracks whether the next frame needs a full or partial redraw. With
//! `Window.partial_present`, hover-only input uses regional dirty bounds so
//! the GPU path can Load + scissor. Regional paint without `layout` can keep
//! the previous element/Yoga tree (retained paint-only frames).

const std = @import("std");
const geometry = @import("geometry.zig");

const Pixels = geometry.Pixels;
const Bounds = geometry.Bounds;

pub const DirtyTracker = struct {
    /// First frame, resize, or other cases that invalidate the whole surface.
    full: bool = true,
    /// When true, the next frame must rebuild elements and re-run Yoga layout.
    /// Regional paint-only dirties leave this false so the window can retain
    /// the previous tree (TextInput edits, ScrollView offset, etc.).
    layout: bool = true,
    /// Union of all partial dirty rects since the last clear.
    union_rect: Bounds(Pixels) = .{},
    has_union: bool = false,

    pub fn markFull(self: *DirtyTracker) void {
        self.full = true;
        self.layout = true;
        self.has_union = false;
    }

    /// Structure/style rebuild required; may still be a regional GPU dirty.
    pub fn markLayout(self: *DirtyTracker) void {
        self.layout = true;
    }

    pub fn markBounds(self: *DirtyTracker, bounds: Bounds(Pixels)) void {
        if (self.full) return;
        if (bounds.isEmpty()) return;
        if (self.has_union) {
            self.union_rect = self.union_rect.@"union"(bounds);
        } else {
            self.union_rect = bounds;
            self.has_union = true;
        }
    }

    pub fn clear(self: *DirtyTracker) void {
        self.full = false;
        self.layout = false;
        self.has_union = false;
        self.union_rect = .{};
    }

    pub fn needsRedraw(self: *const DirtyTracker) bool {
        return self.full or self.has_union;
    }

    pub fn needsLayout(self: *const DirtyTracker) bool {
        return self.layout or self.full;
    }

    /// Overall dirty union when partial; `null` when clean or full redraw.
    pub fn unionBounds(self: *const DirtyTracker) ?Bounds(Pixels) {
        if (self.full or !self.has_union) return null;
        return self.union_rect;
    }
};

/// GPU scissor rect in device pixels for partial present.
pub const ScissorRect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// Outcome of partial-present planning for one frame.
pub const PartialPresentPlan = struct {
    /// Use `Load` instead of `Clear` on the color attachment.
    use_load: bool = false,
    /// Non-null when the render pass should be scissored to the dirty region.
    scissor: ?ScissorRect = null,

    pub const full_clear: PartialPresentPlan = .{};
};

/// Decide whether this frame can use partial GPU present (load + scissor).
/// Falls back to full clear when the flag is off, the tracker is full-dirty,
/// union bounds are missing/empty, or the clamped device rect is invalid.
pub fn planPartialPresent(
    partial_present: bool,
    dirty: *const DirtyTracker,
    framebuffer: geometry.Size(geometry.DevicePixels),
    scale: f32,
) PartialPresentPlan {
    if (!partial_present or dirty.full) return .full_clear;

    const logical = dirty.unionBounds() orelse return .full_clear;
    if (logical.isEmpty()) return .full_clear;

    var device = geometry.toDevicePixels(logical, scale);
    device = device.dilate(@as(geometry.DevicePixels, 1)); // AA halo
    device = device.clampToFramebuffer(framebuffer);
    if (device.isEmpty()) return .full_clear;

    const vw: u32 = @intCast(@max(framebuffer.width, 1));
    const vh: u32 = @intCast(@max(framebuffer.height, 1));
    const x0: u32 = @intCast(@max(device.origin.x, 0));
    const y0: u32 = @intCast(@max(device.origin.y, 0));
    const x1: u32 = @min(@as(u32, @intCast(@max(device.right(), 0))), vw);
    const y1: u32 = @min(@as(u32, @intCast(@max(device.bottom(), 0))), vh);
    if (x1 <= x0 or y1 <= y0) return .full_clear;

    return .{
        .use_load = true,
        .scissor = .{
            .x = x0,
            .y = y0,
            .width = x1 - x0,
            .height = y1 - y0,
        },
    };
}

/// Logical-pixel paint cull rect for partial frames. `null` means paint everything.
/// Dilates the dirty union so shadows / AA near the edge still emit.
pub fn planPaintClip(
    partial_present: bool,
    dirty: *const DirtyTracker,
    halo: Pixels,
) ?Bounds(Pixels) {
    if (!partial_present or dirty.full) return null;
    const logical = dirty.unionBounds() orelse return null;
    if (logical.isEmpty()) return null;
    return logical.dilate(halo);
}

/// How an input event should dirty the window when `partial_present` is on.
pub const InputDirtyKind = enum {
    none,
    /// Hover enter/leave only — caller should mark previous + next hover bounds.
    regional_hover,
    /// Anything that may change layout/content broadly.
    full,
};

/// Classify input dirtying for partial-present windows.
///
/// `consumed` should be:
/// - `mouse_moved`: true when hover id changed (`InputState.dispatch` result)
/// - other events: true when a handler / focus / click consumed the event
///
/// Overlay-handled events always force a full dirty. `mouse_exited` always
/// dirties (regional when partial, full otherwise).
pub fn classifyInputDirty(
    partial_present: bool,
    is_mouse_moved: bool,
    is_mouse_exited: bool,
    overlay_handled: bool,
    consumed: bool,
) InputDirtyKind {
    if (overlay_handled) return .full;
    if (partial_present) {
        if (is_mouse_moved and consumed) return .regional_hover;
        if (is_mouse_exited) return .regional_hover;
        if (consumed) return .full;
        return .none;
    }
    if (consumed or is_mouse_exited) return .full;
    return .none;
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "markBounds unions correctly" {
    var dirty: DirtyTracker = .{};
    dirty.full = false;

    dirty.markBounds(Bounds(Pixels).init(.{ .x = 0, .y = 0 }, .{ .width = 10, .height = 10 }));
    dirty.markBounds(Bounds(Pixels).init(.{ .x = 5, .y = 5 }, .{ .width = 10, .height = 10 }));

    const union_bounds = dirty.unionBounds().?;
    try std.testing.expectEqual(@as(Pixels, 0), union_bounds.origin.x);
    try std.testing.expectEqual(@as(Pixels, 0), union_bounds.origin.y);
    try std.testing.expectEqual(@as(Pixels, 15), union_bounds.right());
    try std.testing.expectEqual(@as(Pixels, 15), union_bounds.bottom());
}

test "clear resets" {
    var dirty: DirtyTracker = .{};
    dirty.markFull();
    try std.testing.expect(dirty.needsRedraw());
    try std.testing.expect(dirty.needsLayout());

    dirty.clear();
    try std.testing.expect(!dirty.needsRedraw());
    try std.testing.expect(!dirty.needsLayout());
    try std.testing.expect(dirty.unionBounds() == null);
    try std.testing.expect(!dirty.full);
}

test "markBounds is paint-only; markLayout requests rebuild" {
    var dirty: DirtyTracker = .{ .full = false, .layout = false };
    dirty.markBounds(Bounds(Pixels).init(.{ .x = 0, .y = 0 }, .{ .width = 10, .height = 10 }));
    try std.testing.expect(dirty.needsRedraw());
    try std.testing.expect(!dirty.needsLayout());
    dirty.markLayout();
    try std.testing.expect(dirty.needsLayout());
}

test "markFull dominates" {
    var dirty: DirtyTracker = .{ .full = false };
    dirty.markBounds(Bounds(Pixels).init(.{ .x = 0, .y = 0 }, .{ .width = 20, .height = 20 }));
    try std.testing.expect(dirty.unionBounds() != null);

    dirty.markFull();
    try std.testing.expect(dirty.full);
    try std.testing.expect(!dirty.has_union);
    try std.testing.expect(dirty.unionBounds() == null);

    dirty.markBounds(Bounds(Pixels).init(.{ .x = 1, .y = 1 }, .{ .width = 5, .height = 5 }));
    try std.testing.expect(!dirty.has_union);
    try std.testing.expect(dirty.unionBounds() == null);
}

test "empty bounds are ignored" {
    var dirty: DirtyTracker = .{ .full = false };
    dirty.markBounds(.{ .origin = .{}, .size = .{} });
    try std.testing.expect(!dirty.needsRedraw());
}

test "planPartialPresent flag off uses full clear" {
    var dirty: DirtyTracker = .{ .full = false };
    dirty.markBounds(Bounds(Pixels).init(.{ .x = 0, .y = 0 }, .{ .width = 10, .height = 10 }));
    const plan = planPartialPresent(false, &dirty, .{ .width = 800, .height = 600 }, 2.0);
    try std.testing.expect(!plan.use_load);
    try std.testing.expect(plan.scissor == null);
}

test "planPartialPresent full dirty uses full clear" {
    var dirty: DirtyTracker = .{};
    dirty.markBounds(Bounds(Pixels).init(.{ .x = 0, .y = 0 }, .{ .width = 10, .height = 10 }));
    const plan = planPartialPresent(true, &dirty, .{ .width = 800, .height = 600 }, 2.0);
    try std.testing.expect(!plan.use_load);
    try std.testing.expect(plan.scissor == null);
}

test "planPartialPresent partial dirty with load and scissor" {
    var dirty: DirtyTracker = .{ .full = false };
    dirty.markBounds(Bounds(Pixels).init(.{ .x = 10, .y = 20 }, .{ .width = 100, .height = 50 }));
    const plan = planPartialPresent(true, &dirty, .{ .width = 800, .height = 600 }, 2.0);
    try std.testing.expect(plan.use_load);
    const scissor = plan.scissor.?;
    // 10*2=20, 20*2=40, dilate 1 -> origin (19,39); size ceil(200)+2, ceil(100)+2
    try std.testing.expectEqual(@as(u32, 19), scissor.x);
    try std.testing.expectEqual(@as(u32, 39), scissor.y);
    try std.testing.expectEqual(@as(u32, 202), scissor.width);
    try std.testing.expectEqual(@as(u32, 102), scissor.height);
}

test "planPaintClip dilates partial dirty union" {
    var dirty: DirtyTracker = .{ .full = false };
    dirty.markBounds(Bounds(Pixels).init(.{ .x = 10, .y = 20 }, .{ .width = 100, .height = 50 }));
    const clip = planPaintClip(true, &dirty, 8).?;
    try std.testing.expectEqual(@as(Pixels, 2), clip.origin.x);
    try std.testing.expectEqual(@as(Pixels, 12), clip.origin.y);
    try std.testing.expectEqual(@as(Pixels, 116), clip.size.width);
    try std.testing.expectEqual(@as(Pixels, 66), clip.size.height);

    try std.testing.expect(planPaintClip(false, &dirty, 8) == null);
    dirty.markFull();
    try std.testing.expect(planPaintClip(true, &dirty, 8) == null);
}

test "classifyInputDirty prefers regional hover under partial_present" {
    try std.testing.expectEqual(
        InputDirtyKind.regional_hover,
        classifyInputDirty(true, true, false, false, true),
    );
    try std.testing.expectEqual(
        InputDirtyKind.full,
        classifyInputDirty(false, true, false, false, true),
    );
    try std.testing.expectEqual(
        InputDirtyKind.full,
        classifyInputDirty(true, true, false, true, true),
    );
    try std.testing.expectEqual(
        InputDirtyKind.regional_hover,
        classifyInputDirty(true, false, true, false, false),
    );
    try std.testing.expectEqual(
        InputDirtyKind.none,
        classifyInputDirty(true, true, false, false, false),
    );
    try std.testing.expectEqual(
        InputDirtyKind.full,
        classifyInputDirty(true, false, false, false, true),
    );
    try std.testing.expectEqual(
        InputDirtyKind.full,
        classifyInputDirty(false, false, false, false, true),
    );
}
