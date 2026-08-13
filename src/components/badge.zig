//! Headless decorative status badge (chip). Variants drive styling via
//! `style_fn`; comptime default styles are available for each variant.

const std = @import("std");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const color = @import("../color.zig");

const Div = div_mod.Div;

pub const Variant = enum {
    default,
    success,
    warning,
    danger,
};

pub const StyleState = struct {
    variant: Variant = .default,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    variant: Variant = .default,
    style_fn: ?StyleFn = null,
};

/// Default background per variant (callers may use in custom style_fn).
pub fn defaultStyleFor(variant: Variant) style_mod.Style {
    var s = style_mod.Style{};
    s.padding = .{
        .top = .{ .px = 2 },
        .right = .{ .px = 8 },
        .bottom = .{ .px = 2 },
        .left = .{ .px = 8 },
    };
    s.background = switch (variant) {
        .default => color.Rgba.fromHex(0x6b7280),
        .success => color.Rgba.fromHex(0x16a34a),
        .warning => color.Rgba.fromHex(0xd97706),
        .danger => color.Rgba.fromHex(0xdc2626),
    };
    return s;
}

/// Build a non-interactive badge div. Callers add label text as children.
pub fn badge(arena: std.mem.Allocator, props: Props) *Div {
    const state = StyleState{ .variant = props.variant };

    var d = div_mod.div(arena).withId(props.id);
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    } else {
        d = d.withStyle(defaultStyleFor(props.variant));
    }
    return d;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const element = @import("../element.zig");

const BadgeFixture = struct {
    variant: Variant = .success,

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
        const self: *BadgeFixture = @ptrCast(@alignCast(ctx.?));
        const root = div_mod.div(arena)
            .sizePx(120, 60)
            .padPx(10)
            .childDiv(badge(arena, .{
                .id = "the-badge",
                .variant = self.variant,
            }));
        return root.any();
    }
};

test "badge default styles cover all variants" {
    inline for (@typeInfo(Variant).@"enum".fields) |field| {
        const variant: Variant = @field(Variant, field.name);
        const s = defaultStyleFor(variant);
        try std.testing.expect(s.background.?.a > 0);
    }
}

test "badge renders with variant background" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 120, .height = 60 });
    defer harness.deinit();

    var fixture = BadgeFixture{ .variant = .danger };
    try harness.setRoot(&fixture, BadgeFixture.render);

    try std.testing.expectEqual(@as(usize, 1), harness.scene.quads.items.len);
    const quad = harness.scene.quads.items[0];
    const expected = color.Rgba.fromHex(0xdc2626);
    try std.testing.expectApproxEqAbs(expected.r, quad.background.r, 0.001);
    try std.testing.expectApproxEqAbs(expected.g, quad.background.g, 0.001);
}

test "badge accepts custom style_fn" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 120, .height = 60 });
    defer harness.deinit();

    const CustomFixture = struct {
        fn render(_: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
            const root = div_mod.div(arena)
                .sizePx(120, 60)
                .childDiv(badge(arena, .{
                    .id = "custom-badge",
                    .variant = .default,
                    .style_fn = struct {
                        fn style(state: StyleState) style_mod.Style {
                            var s = style_mod.Style{};
                            s.width = .{ .px = 80 };
                            s.height = .{ .px = 20 };
                            s.background = if (state.variant == .default)
                                color.Rgba.fromHex(0x111111)
                            else
                                color.Rgba.fromHex(0xffffff);
                            return s;
                        }
                    }.style,
                }));
            return root.any();
        }
    };

    try harness.setRoot(null, CustomFixture.render);

    const quad = harness.scene.quads.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 80), quad.bounds.size_w, 0.5);
}
