//! Headless status tag / chip. Variants drive styling via `style_fn`
//! (decorative; not interactive by default).

const std = @import("std");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const color = @import("../color.zig");

const Div = div_mod.Div;
const a11y_mod = @import("../a11y.zig");

pub const Variant = enum {
    primary,
    secondary,
    success,
    warning,
    danger,
    info,
};

pub const StyleState = struct {
    variant: Variant = .secondary,
    outline: bool = false,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    variant: Variant = .secondary,
    outline: bool = false,
    a11y_label: ?[]const u8 = null,
    style_fn: ?StyleFn = null,
};

pub fn defaultStyleFor(state: StyleState) style_mod.Style {
    var s = style_mod.Style{};
    s.padding = .{
        .top = .{ .px = 2 },
        .right = .{ .px = 8 },
        .bottom = .{ .px = 2 },
        .left = .{ .px = 8 },
    };
    const fill = switch (state.variant) {
        .primary => color.Rgba.fromHex(0x2563eb),
        .secondary => color.Rgba.fromHex(0x6b7280),
        .success => color.Rgba.fromHex(0x16a34a),
        .warning => color.Rgba.fromHex(0xd97706),
        .danger => color.Rgba.fromHex(0xdc2626),
        .info => color.Rgba.fromHex(0x0891b2),
    };
    if (!state.outline) s.background = fill;
    return s;
}

pub fn tag(arena: std.mem.Allocator, props: Props) *Div {
    const state = StyleState{ .variant = props.variant, .outline = props.outline };
    var d = div_mod.div(arena)
        .withId(props.id)
        .role(.label);
    if (props.a11y_label) |label| d = d.a11yName(label);
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    } else {
        d = d.withStyle(defaultStyleFor(state));
    }
    return d;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const element = @import("../element.zig");

test "tag renders with sized bounds" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 120, .height = 40 });
    defer harness.deinit();

    const Fixture = struct {
        fn style(state: StyleState) style_mod.Style {
            var s = defaultStyleFor(state);
            s.width = .{ .px = 64 };
            s.height = .{ .px = 20 };
            return s;
        }

        fn render(_: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
            return div_mod.div(arena).sizePx(120, 40).padPx(8).childDiv(tag(arena, .{
                .id = "status-tag",
                .variant = .success,
                .style_fn = style,
            }).interactive()).any();
        }
    };

    var fixture: Fixture = .{};
    try harness.setRoot(&fixture, Fixture.render);
    const bounds = harness.hitboxBounds(element.elementId("status-tag")).?;
    try std.testing.expectEqual(@as(f32, 64), bounds.size.width);
    try std.testing.expectEqual(@as(f32, 20), bounds.size.height);
}

test "tag exposes label role and accessible name" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 120, .height = 40 });
    defer harness.deinit();

    const Fixture = struct {
        fn render(_: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
            return div_mod.div(arena).sizePx(120, 40).childDiv(tag(arena, .{
                .id = "status-tag",
                .a11y_label = "Beta",
            })).any();
        }
    };

    try harness.setRoot(null, Fixture.render);
    try std.testing.expectEqual(a11y_mod.Role.label, harness.a11yRole("status-tag").?);
    try std.testing.expectEqualStrings("Beta", a11y_mod.resolveName(harness.a11yNode("status-tag").?).?);
}
