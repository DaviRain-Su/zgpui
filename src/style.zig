//! Style: layout + paint properties for elements, modeled on gpui's
//! `style.rs` (subset). Layout fields map onto the flexbox engine in
//! `layout/layout.zig`; paint fields drive scene primitive generation.

const std = @import("std");
const geometry = @import("geometry.zig");
const color = @import("color.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Edges = geometry.Edges;
const Corners = geometry.Corners;
const Rgba = color.Rgba;

pub const Display = enum { flex, none };

pub const Position = enum { relative, absolute };

pub const FlexDirection = enum { row, column, row_reverse, column_reverse };

pub const FlexWrap = enum { no_wrap, wrap, wrap_reverse };

pub const AlignItems = enum { flex_start, flex_end, center, stretch, baseline };

pub const AlignContent = enum { flex_start, flex_end, center, stretch, space_between, space_around };

pub const JustifyContent = enum { flex_start, flex_end, center, space_between, space_around, space_evenly };

pub const Overflow = enum { visible, hidden, scroll };

/// A layout length: automatic, absolute pixels, or percent of the parent.
pub const Length = union(enum) {
    auto,
    px: f32,
    percent: f32,

    pub const zero: Length = .{ .px = 0 };
};

pub const BoxShadow = struct {
    color: Rgba,
    offset: Point(Pixels) = .{},
    blur_radius: Pixels = 0,
    /// Extra outline beyond the box (gpui `spread_radius`).
    spread_radius: Pixels = 0,
    /// When true, the shadow is an inset edge ring (selection outlines).
    inset: bool = false,
};

pub const Style = struct {
    // ------------------------------------------------------------------
    // Layout
    // ------------------------------------------------------------------
    display: Display = .flex,
    position: Position = .relative,
    inset: Edges(Length) = .{
        .top = .auto,
        .right = .auto,
        .bottom = .auto,
        .left = .auto,
    },

    width: Length = .auto,
    height: Length = .auto,
    min_width: Length = .auto,
    min_height: Length = .auto,
    max_width: Length = .auto,
    max_height: Length = .auto,

    margin: Edges(Length) = .{
        .top = Length.zero,
        .right = Length.zero,
        .bottom = Length.zero,
        .left = Length.zero,
    },
    padding: Edges(Length) = .{
        .top = Length.zero,
        .right = Length.zero,
        .bottom = Length.zero,
        .left = Length.zero,
    },
    gap: Pixels = 0,

    flex_direction: FlexDirection = .row,
    flex_wrap: FlexWrap = .no_wrap,
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    flex_basis: Length = .auto,

    align_items: ?AlignItems = null,
    align_self: ?AlignItems = null,
    align_content: ?AlignContent = null,
    justify_content: ?JustifyContent = null,

    overflow_x: Overflow = .visible,
    overflow_y: Overflow = .visible,

    // ------------------------------------------------------------------
    // Paint
    // ------------------------------------------------------------------
    background: ?Rgba = null,
    border_color: ?Rgba = null,
    border_widths: Edges(Pixels) = Edges(Pixels).zero,
    corner_radii: Corners(Pixels) = Corners(Pixels).zero,
    box_shadow: ?BoxShadow = null,

    text_color: ?Rgba = null,
    font_size: ?Pixels = null,

    pub fn hasBorder(self: *const Style) bool {
        const b = self.border_widths;
        return b.top > 0 or b.right > 0 or b.bottom > 0 or b.left > 0;
    }

    pub fn hasBackground(self: *const Style) bool {
        if (self.background) |bg| return bg.a > 0;
        return false;
    }
};

test "default style" {
    const s = Style{};
    try std.testing.expect(!s.hasBorder());
    try std.testing.expect(!s.hasBackground());
    try std.testing.expectEqual(Display.flex, s.display);
}

test "style with paint" {
    var s = Style{};
    s.background = Rgba.fromHex(0x336699);
    s.border_widths = Edges(Pixels).all(1);
    try std.testing.expect(s.hasBorder());
    try std.testing.expect(s.hasBackground());
}
