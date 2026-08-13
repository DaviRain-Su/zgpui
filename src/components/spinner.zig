//! Headless decorative loading spinner. `active` is a style-state flag only
//! (no built-in animation); callers style the indicator via `style_fn`.

const std = @import("std");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const element = @import("../element.zig");

const Div = div_mod.Div;

pub const StyleState = struct {
    active: bool = true,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    width: ?style_mod.Length = null,
    height: ?style_mod.Length = null,
    /// When true, fills the parent on both axes (overrides width/height).
    full: bool = false,
    active: bool = true,
    style_fn: ?StyleFn = null,
};

/// Build a non-interactive spinner div.
pub fn spinner(arena: std.mem.Allocator, props: Props) *Div {
    const state = StyleState{ .active = props.active };

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
        if (styled.border_widths.top > 0 or styled.border_widths.right > 0 or
            styled.border_widths.bottom > 0 or styled.border_widths.left > 0)
        {
            s.border_widths = styled.border_widths;
        }
        if (styled.corner_radii.top_left > 0) s.corner_radii = styled.corner_radii;
        d.style = s;
    }
    return d
        .role(.progressbar)
        .a11yName("Loading")
        .a11yBusy(props.active);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const SpinnerFixture = struct {
    active: bool = true,
    full: bool = false,

    fn spinnerStyle(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.background = if (state.active)
            color.Rgba.fromHex(0x3b82f6)
        else
            color.Rgba.fromHex(0x64748b);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
        const self: *SpinnerFixture = @ptrCast(@alignCast(ctx.?));
        const sp = if (self.full)
            spinner(arena, .{
                .id = "the-spinner",
                .full = true,
                .active = self.active,
                .style_fn = spinnerStyle,
            })
        else
            spinner(arena, .{
                .id = "the-spinner",
                .width = .{ .px = 24 },
                .height = .{ .px = 24 },
                .active = self.active,
                .style_fn = spinnerStyle,
            });
        const root = div_mod.div(arena)
            .sizePx(100, 100)
            .padPx(10)
            .childDiv(sp);
        return root.any();
    }
};

test "spinner fixed dimensions" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer harness.deinit();

    var fixture = SpinnerFixture{};
    try harness.setRoot(&fixture, SpinnerFixture.render);

    try std.testing.expectEqual(@as(usize, 1), harness.scene.quads.items.len);
    const quad = harness.scene.quads.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 24), quad.bounds.size_w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 24), quad.bounds.size_h, 0.5);
}

test "spinner full fills parent content area" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer harness.deinit();

    var fixture = SpinnerFixture{ .full = true };
    try harness.setRoot(&fixture, SpinnerFixture.render);

    const quad = harness.scene.quads.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 80), quad.bounds.size_w, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 80), quad.bounds.size_h, 1.0);
}

test "spinner active flag affects style state" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer harness.deinit();

    var fixture = SpinnerFixture{ .active = false };
    try harness.setRoot(&fixture, SpinnerFixture.render);

    const quad = harness.scene.quads.items[0];
    const expected = color.Rgba.fromHex(0x64748b);
    try std.testing.expectApproxEqAbs(expected.r, quad.background.r, 0.001);
}
