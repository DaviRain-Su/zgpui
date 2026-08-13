//! Headless loading skeleton placeholder. Size via explicit dimensions or
//! `full`; `animated` is a style-state flag only (no built-in animation).

const std = @import("std");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const element = @import("../element.zig");

const Div = div_mod.Div;

pub const StyleState = struct {
    animated: bool = false,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    width: ?style_mod.Length = null,
    height: ?style_mod.Length = null,
    /// When true, fills the parent on both axes (overrides width/height).
    full: bool = false,
    animated: bool = false,
    style_fn: ?StyleFn = null,
};

/// Build a non-interactive skeleton div.
pub fn skeleton(arena: std.mem.Allocator, props: Props) *Div {
    const state = StyleState{ .animated = props.animated };

    var d = div_mod.div(arena).withId(props.id);
    if (props.full) {
        d = d.wFull().hFull();
    } else {
        if (props.width) |width| {
            switch (width) {
                .px => |v| d = d.wPx(v),
                .percent => |v| d = d.withStyle(.{ .width = .{ .percent = v } }),
                .auto => {},
            }
        }
        if (props.height) |height| {
            switch (height) {
                .px => |v| d = d.hPx(v),
                .percent => |v| d = d.withStyle(.{ .height = .{ .percent = v } }),
                .auto => {},
            }
        }
    }
    if (props.style_fn) |style_fn| {
        var s = d.style;
        const styled = style_fn(state);
        if (styled.background) |bg| s.background = bg;
        if (styled.border_color) |bc| s.border_color = bc;
        d.style = s;
    }
    return d;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const SkeletonFixture = struct {
    full: bool = false,
    animated: bool = false,

    fn skeletonStyle(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.background = if (state.animated)
            color.Rgba.fromHex(0x444444)
        else
            color.Rgba.fromHex(0x333333);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
        const self: *SkeletonFixture = @ptrCast(@alignCast(ctx.?));
        const sk = if (self.full)
            skeleton(arena, .{
                .id = "the-skeleton",
                .full = true,
                .animated = self.animated,
                .style_fn = skeletonStyle,
            })
        else
            skeleton(arena, .{
                .id = "the-skeleton",
                .width = .{ .px = 160 },
                .height = .{ .px = 12 },
                .animated = self.animated,
                .style_fn = skeletonStyle,
            });
        const root = div_mod.div(arena)
            .sizePx(200, 40)
            .padPx(10)
            .childDiv(sk);
        return root.any();
    }
};

test "skeleton fixed dimensions" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 40 });
    defer harness.deinit();

    var fixture = SkeletonFixture{};
    try harness.setRoot(&fixture, SkeletonFixture.render);

    try std.testing.expectEqual(@as(usize, 1), harness.scene.quads.items.len);
    const quad = harness.scene.quads.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 160), quad.bounds.size_w, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 12), quad.bounds.size_h, 0.5);
}

test "skeleton full fills parent content area" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 40 });
    defer harness.deinit();

    var fixture = SkeletonFixture{ .full = true };
    try harness.setRoot(&fixture, SkeletonFixture.render);

    const quad = harness.scene.quads.items[0];
    // Parent is 200x40 with 10px padding → 180x20 content.
    try std.testing.expectApproxEqAbs(@as(f32, 180), quad.bounds.size_w, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 20), quad.bounds.size_h, 0.5);
}

test "skeleton animated flag affects style state" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 40 });
    defer harness.deinit();

    var fixture = SkeletonFixture{ .animated = true };
    try harness.setRoot(&fixture, SkeletonFixture.render);

    const quad = harness.scene.quads.items[0];
    const expected = color.Rgba.fromHex(0x444444);
    try std.testing.expectApproxEqAbs(expected.r, quad.background.r, 0.001);
}
