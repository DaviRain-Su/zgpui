//! Headless aspect-ratio wrapper. Maintains width:height = `ratio` using a
//! padding-top percentage box; child content fills the inner slot absolutely.

const std = @import("std");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const element = @import("../element.zig");

const Div = div_mod.Div;

pub const StyleState = struct {
    ratio: f32 = 1,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    /// Width divided by height (e.g. 16/9 ≈ 1.778).
    ratio: f32 = 1,
    style_fn: ?StyleFn = null,
};

/// Padding-top percentage for the aspect-ratio box (relative to width).
pub fn paddingTopPercent(ratio: f32) f32 {
    if (ratio <= 0) return 0;
    return 100.0 / ratio;
}

/// Build a wrapper div with the given aspect ratio. Pass child content via
/// `childDiv` on the returned outer div, or use `withChild`.
pub fn aspectRatio(arena: std.mem.Allocator, props: Props) *Div {
    const state = StyleState{ .ratio = props.ratio };
    const pad_percent = paddingTopPercent(props.ratio);

    var outer = div_mod.div(arena)
        .withId(props.id)
        .wFull()
        .withStyle(.{
            .position = .relative,
            .height = .{ .px = 0 },
            .padding = .{
                .top = .{ .percent = pad_percent },
                .right = .{ .px = 0 },
                .bottom = .{ .px = 0 },
                .left = .{ .px = 0 },
            },
            .overflow_x = .hidden,
            .overflow_y = .hidden,
        });

    if (props.style_fn) |style_fn| {
        const styled = style_fn(state);
        if (styled.background) |bg| outer.style.background = bg;
        if (styled.border_color) |bc| outer.style.border_color = bc;
        if (styled.border_widths.top > 0 or styled.border_widths.right > 0 or
            styled.border_widths.bottom > 0 or styled.border_widths.left > 0)
        {
            outer.style.border_widths = styled.border_widths;
        }
        if (styled.corner_radii.top_left > 0) outer.style.corner_radii = styled.corner_radii;
    }

    return outer;
}

/// Attach a child to the aspect-ratio inner slot (absolute fill).
pub fn withChild(outer: *Div, arena: std.mem.Allocator, child: *Div) *Div {
    const inner = div_mod.div(arena)
        .absolute()
        .withStyle(.{
            .inset = .{
                .top = .{ .px = 0 },
                .right = .{ .px = 0 },
                .bottom = .{ .px = 0 },
                .left = .{ .px = 0 },
            },
            .width = .{ .percent = 100 },
            .height = .{ .percent = 100 },
        })
        .childDiv(child);
    return outer.childDiv(inner);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const AspectRatioFixture = struct {
    ratio: f32 = 16.0 / 9.0,

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
        const self: *AspectRatioFixture = @ptrCast(@alignCast(ctx.?));

        const content = div_mod.div(arena)
            .withId("inner-content")
            .wFull()
            .hFull()
            .bg(color.Rgba.fromHex(0xff0000));

        const ar = withChild(aspectRatio(arena, .{
            .id = "the-aspect-ratio",
            .ratio = self.ratio,
        }), arena, content);

        const root = div_mod.div(arena)
            .sizePx(320, 400)
            .padPx(10)
            .childDiv(ar);
        return root.any();
    }
};

test "paddingTopPercent inverts ratio" {
    try std.testing.expectApproxEqAbs(@as(f32, 56.25), paddingTopPercent(16.0 / 9.0), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), paddingTopPercent(1), 0.01);
    try std.testing.expectEqual(@as(f32, 0), paddingTopPercent(0));
}

test "aspect ratio wrapper renders content at full width" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 320, .height = 400 });
    defer harness.deinit();

    var fixture = AspectRatioFixture{};
    try harness.setRoot(&fixture, AspectRatioFixture.render);

    try std.testing.expectEqual(@as(usize, 1), harness.scene.quads.items.len);
    const content_quad = harness.scene.quads.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 300), content_quad.bounds.size_w, 2.0);
}

test "aspect ratio accepts style_fn" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 200 });
    defer harness.deinit();

    const StyledFixture = struct {
        fn render(_: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
            const content = div_mod.div(arena).wFull().hFull();
            const ar = withChild(aspectRatio(arena, .{
                .id = "styled-ar",
                .ratio = 2,
                .style_fn = struct {
                    fn style(_: StyleState) style_mod.Style {
                        var s = style_mod.Style{};
                        s.background = color.Rgba.fromHex(0x222222);
                        return s;
                    }
                }.style,
            }), arena, content);
            const root = div_mod.div(arena)
                .sizePx(200, 200)
                .childDiv(ar);
            return root.any();
        }
    };

    try harness.setRoot(null, StyledFixture.render);

    const ar_quad = harness.scene.quads.items[0];
    const expected = color.Rgba.fromHex(0x222222);
    try std.testing.expectApproxEqAbs(expected.r, ar_quad.background.r, 0.001);
}
