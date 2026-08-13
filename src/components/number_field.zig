//! base-gpui catalog alias: `number_field` wraps `number_input`.

const std = @import("std");
const number_input = @import("number_input.zig");
const testing_mod = @import("../testing.zig");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const color = @import("../color.zig");
const a11y_mod = @import("../a11y.zig");

pub const Value = number_input.Value;
pub const ChangeHandler = number_input.ChangeHandler;
pub const StyleState = number_input.StyleState;
pub const StyleFn = number_input.StyleFn;
pub const Props = number_input.Props;

pub const clampValue = number_input.clampValue;
pub const readValue = number_input.readValue;
pub const numberField = number_input.numberInput;

test "number_field alias shares numberInput entrypoint" {
    try std.testing.expectEqual(@intFromPtr(&number_input.numberInput), @intFromPtr(&numberField));
}

test "number_field alias exposes slider a11y" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 100 });
    defer harness.deinit();

    const Fixture = struct {
        state: @import("../app.zig").Entity(Value.Store) = undefined,

        fn styleFor(_: StyleState) style_mod.Style {
            var s = style_mod.Style{};
            s.width = .{ .px = 80 };
            s.height = .{ .px = 32 };
            s.background = color.Rgba.fromHex(0x333333);
            return s;
        }

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, h: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const root = div_mod.div(arena)
                .sizePx(200, 100)
                .padPx(20)
                .childDiv(numberField(arena, &h.app, &h.input, .{
                    .id = "alias-number",
                    .value = .{ .uncontrolled = self.state },
                    .min = 0,
                    .max = 100,
                    .style_fn = styleFor,
                }));
            return root.any();
        }
    };

    var fixture: Fixture = .{};
    fixture.state = try harness.app.new(Value.Store, .{ .value = 7 });
    try harness.setRoot(&fixture, Fixture.render);
    try std.testing.expectEqual(a11y_mod.Role.slider, harness.a11yRole("alias-number").?);
    try std.testing.expectEqual(@as(f64, 7), harness.a11yNode("alias-number").?.numeric_value.?);
}
