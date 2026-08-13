//! Headless keyboard key chrome. Renders a styled div; callers add label text
//! as children or use the `label` prop for a single key caption.

const std = @import("std");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const element = @import("../element.zig");
const text_mod = @import("../elements/text.zig");
const color = @import("../color.zig");

const Div = div_mod.Div;
const a11y_mod = @import("../a11y.zig");

pub const StyleState = struct {};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    /// Key caption (e.g. "⌘", "K", "Enter"). Optional when adding text children.
    label: ?[]const u8 = null,
    style_fn: ?StyleFn = null,
};

/// Default chrome for a keyboard key badge.
pub fn defaultStyle() style_mod.Style {
    var s = style_mod.Style{};
    s.padding = .{
        .top = .{ .px = 2 },
        .right = .{ .px = 6 },
        .bottom = .{ .px = 2 },
        .left = .{ .px = 6 },
    };
    s.corner_radii = .{
        .top_left = 4,
        .top_right = 4,
        .bottom_right = 4,
        .bottom_left = 4,
    };
    s.background = color.Rgba.fromHex(0x374151);
    s.border_widths = .{
        .top = 1,
        .right = 1,
        .bottom = 2,
        .left = 1,
    };
    s.border_color = color.Rgba.fromHex(0x1f2937);
    s.align_items = .center;
    s.justify_content = .center;
    return s;
}

/// Build a non-interactive kbd div. When `label` is set, allocates text via
/// the frame arena and adds it as a child.
pub fn kbd(arena: std.mem.Allocator, props: Props, text_resources: ?*text_mod.TextResources) *Div {
    const state = StyleState{};

    var d = div_mod.div(arena)
        .withId(props.id)
        .role(.label);
    if (props.label) |caption| {
        d = d.a11yName(caption);
    }
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    } else {
        d = d.withStyle(defaultStyle());
    }

    if (props.label) |label| {
        if (text_resources) |resources| {
            const text_el = text_mod.textEl(arena, resources, label)
                .size(12)
                .withColor(color.Rgba.fromHex(0xf9fafb));
            d = d.child(text_el.any());
        }
    }

    return d;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

const KbdFixture = struct {
    fn kbdStyle(_: StyleState) style_mod.Style {
        var s = defaultStyle();
        s.width = .{ .px = 32 };
        s.height = .{ .px = 24 };
        return s;
    }

    fn render(_: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
        const root = div_mod.div(arena)
            .sizePx(120, 60)
            .padPx(10)
            .childDiv(kbd(arena, .{
                .id = "the-kbd",
                .label = "⌘",
                .style_fn = kbdStyle,
            }, null));
        return root.any();
    }
};

test "kbd default style has chrome" {
    const s = defaultStyle();
    try std.testing.expect(s.background != null);
    try std.testing.expect(s.border_color != null);
    try std.testing.expect(s.border_widths.bottom > 0);
}

test "kbd renders with custom style_fn dimensions" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 120, .height = 60 });
    defer harness.deinit();

    try harness.setRoot(null, KbdFixture.render);

    try std.testing.expectEqual(@as(usize, 1), harness.scene.quads.items.len);
    const quad = harness.scene.quads.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 32), quad.bounds.size_w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 24), quad.bounds.size_h, 0.5);
}

test "kbd accepts custom style_fn" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 120, .height = 60 });
    defer harness.deinit();

    const CustomFixture = struct {
        fn render(_: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
            const root = div_mod.div(arena)
                .sizePx(120, 60)
                .childDiv(kbd(arena, .{
                    .id = "custom-kbd",
                    .style_fn = struct {
                        fn style(_: StyleState) style_mod.Style {
                            var s = style_mod.Style{};
                            s.width = .{ .px = 48 };
                            s.height = .{ .px = 28 };
                            s.background = color.Rgba.fromHex(0x111111);
                            return s;
                        }
                    }.style,
                }, null));
            return root.any();
        }
    };

    try harness.setRoot(null, CustomFixture.render);

    const quad = harness.scene.quads.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 48), quad.bounds.size_w, 0.5);
}

test "kbd exposes label role from caption" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 120, .height = 60 });
    defer harness.deinit();

    try harness.setRoot(null, KbdFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.label, harness.a11yRole("the-kbd").?);
    try std.testing.expectEqualStrings("⌘", a11y_mod.resolveName(harness.a11yNode("the-kbd").?).?);
}
