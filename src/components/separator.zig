//! Headless decorative separator: horizontal or vertical divider with
//! caller-defined visuals via `style_fn`. Registers `role(.separator)` and
//! AppKit `accessibilityOrientation`.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const a11y_mod = @import("../a11y.zig");

const Div = div_mod.Div;

pub const Orientation = enum {
    horizontal,
    vertical,

    fn toA11y(self: Orientation) a11y_mod.Orientation {
        return switch (self) {
            .horizontal => .horizontal,
            .vertical => .vertical,
        };
    }
};

pub const StyleState = struct {
    orientation: Orientation = .horizontal,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    orientation: Orientation = .horizontal,
    style_fn: ?StyleFn = null,
};

/// Build a non-interactive separator div.
pub fn separator(arena: std.mem.Allocator, props: Props) *Div {
    const state = StyleState{ .orientation = props.orientation };

    var d = div_mod.div(arena)
        .withId(props.id)
        .role(.separator)
        .a11yOrientation(props.orientation.toA11y());
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    }
    return d;
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const SeparatorFixture = struct {
    orientation: Orientation = .horizontal,

    fn styleFor(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        switch (state.orientation) {
            .horizontal => {
                s.width = .{ .percent = 100 };
                s.height = .{ .px = 1 };
            },
            .vertical => {
                s.width = .{ .px = 1 };
                s.height = .{ .px = 100 };
            },
        }
        s.background = color.Rgba.fromHex(0x888888);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
        const self: *SeparatorFixture = @ptrCast(@alignCast(ctx.?));
        const root = div_mod.div(arena)
            .sizePx(200, 120)
            .flexRow()
            .itemsCenter()
            .childDiv(separator(arena, .{
                .id = "the-separator",
                .orientation = self.orientation,
                .style_fn = styleFor,
            }));
        return root.any();
    }
};

test "horizontal separator renders with expected bounds" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 120 });
    defer harness.deinit();

    var fixture = SeparatorFixture{};
    try harness.setRoot(&fixture, SeparatorFixture.render);

    try std.testing.expectEqual(@as(usize, 1), harness.scene.quads.items.len);
    const quad = harness.scene.quads.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 200), quad.bounds.size_w, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1), quad.bounds.size_h, 0.5);
}

test "vertical separator renders with expected bounds" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 120 });
    defer harness.deinit();

    var fixture = SeparatorFixture{ .orientation = .vertical };
    try harness.setRoot(&fixture, SeparatorFixture.render);

    try std.testing.expectEqual(@as(usize, 1), harness.scene.quads.items.len);
    const quad = harness.scene.quads.items[0];
    try std.testing.expectApproxEqAbs(@as(f32, 1), quad.bounds.size_w, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 100), quad.bounds.size_h, 0.5);
}

test "separator exposes role and orientation" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 120 });
    defer harness.deinit();

    var fixture = SeparatorFixture{ .orientation = .vertical };
    try harness.setRoot(&fixture, SeparatorFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.separator, harness.a11yRole("the-separator").?);
    try std.testing.expectEqual(a11y_mod.Orientation.vertical, harness.a11yNode("the-separator").?.orientation.?);
}
