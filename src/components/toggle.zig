//! base-gpui catalog alias: `toggle` is the binary switch component.

const std = @import("std");
const switch_ = @import("switch.zig");
const testing_mod = @import("../testing.zig");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const color = @import("../color.zig");
const a11y_mod = @import("../a11y.zig");

pub const ToggleState = switch_.SwitchState;
pub const Value = switch_.Value;
pub const ChangeHandler = switch_.ChangeHandler;
pub const StyleState = switch_.StyleState;
pub const StyleFn = switch_.StyleFn;
pub const Props = switch_.Props;

pub const toggle = switch_.switchEl;
pub const isOn = switch_.isOn;

test "toggle alias shares switch entrypoint" {
    try std.testing.expectEqual(@intFromPtr(&switch_.switchEl), @intFromPtr(&toggle));
}

test "toggle alias exposes switch_control a11y" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer harness.deinit();

    const Fixture = struct {
        state: @import("../app.zig").Entity(ToggleState) = undefined,

        fn styleFor(_: StyleState) style_mod.Style {
            var s = style_mod.Style{};
            s.width = .{ .px = 40 };
            s.height = .{ .px = 24 };
            s.background = color.Rgba.fromHex(0xdddddd);
            return s;
        }

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, h: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const root = div_mod.div(arena)
                .sizePx(100, 100)
                .padPx(10)
                .childDiv(toggle(arena, &h.app, &h.input, .{
                    .id = "alias-toggle",
                    .value = .{ .uncontrolled = self.state },
                    .style_fn = styleFor,
                }));
            return root.any();
        }
    };

    var fixture: Fixture = .{};
    fixture.state = try harness.app.new(ToggleState, .{});
    try harness.setRoot(&fixture, Fixture.render);
    try std.testing.expectEqual(a11y_mod.Role.switch_control, harness.a11yRole("alias-toggle").?);
}
