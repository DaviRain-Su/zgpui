//! Cross-component harness smoke test: instantiates key widgets in one tree
//! and asserts basic accessibility roles without GPU.

const std = @import("std");
const testing_mod = @import("../testing.zig");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const app_mod = @import("../app.zig");
const a11y_mod = @import("../a11y.zig");
const button_mod = @import("button.zig");
const checkbox_mod = @import("checkbox.zig");
const dialog_mod = @import("dialog.zig");
const plot_mod = @import("plot.zig");
const markdown_mod = @import("markdown.zig");
const code_input_mod = @import("code_input.zig");

fn sizedButtonStyle(_: button_mod.StyleState) style_mod.Style {
    var s = style_mod.Style{};
    s.width = .{ .px = 120 };
    s.height = .{ .px = 32 };
    return s;
}

fn sizedCheckboxStyle(_: checkbox_mod.StyleState) style_mod.Style {
    var s = style_mod.Style{};
    s.width = .{ .px = 22 };
    s.height = .{ .px = 22 };
    return s;
}

const CatalogFixture = struct {
    harness: *testing_mod.Harness = undefined,
    dialog_state: app_mod.Entity(dialog_mod.DialogState) = undefined,
    checkbox_state: app_mod.Entity(checkbox_mod.CheckboxState) = undefined,

    fn onOpenDialog(ctx: ?*anyopaque) void {
        const self: *CatalogFixture = @ptrCast(@alignCast(ctx.?));
        dialog_mod.open(&self.harness.app, self.dialog_state);
    }

    fn onDialogOk(ctx: ?*anyopaque) void {
        const self: *CatalogFixture = @ptrCast(@alignCast(ctx.?));
        dialog_mod.close(&self.harness.app, self.dialog_state, .{});
    }

    fn dialogBody(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!*div_mod.Div {
        const self: *CatalogFixture = @ptrCast(@alignCast(ctx.?));
        return div_mod.div(arena)
            .sizePx(200, 80)
            .childDiv(button_mod.button(arena, &self.harness.input, .{
                .id = "dialog-ok",
                .label = "OK",
                .on_press = .{ .ctx = self, .func = onDialogOk },
                .style_fn = sizedButtonStyle,
            }));
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *CatalogFixture = @ptrCast(@alignCast(ctx.?));
        const app = &harness.app;

        _ = try dialog_mod.dialogWithContent(arena, .{
            .id = "smoke-dialog",
            .state = self.dialog_state,
            .overlays = &harness.overlays,
            .app = app,
        }, self, dialogBody);

        const root = div_mod.div(arena)
            .flexCol()
            .gapPx(12)
            .padPx(16)
            .sizePx(480, 360)
            .childDiv(button_mod.button(arena, &harness.input, .{
                .id = "smoke-button",
                .label = "Open dialog",
                .on_press = .{ .ctx = self, .func = onOpenDialog },
                .style_fn = sizedButtonStyle,
            }))
            .childDiv(checkbox_mod.checkbox(arena, app, &harness.input, .{
                .id = "smoke-checkbox",
                .value = .{ .uncontrolled = self.checkbox_state },
                .style_fn = sizedCheckboxStyle,
            }))
            .childDiv(plot_mod.barChart(arena, .{
                .id = "smoke-chart",
                .values = &[_]f32{ 2, 5, 3 },
                .width = 200,
                .height = 80,
            }))
            .childDiv(blk: {
                const blocks = markdown_mod.parseBlocks(arena, "# Smoke\n\nhello") catch @panic("oom");
                break :blk markdown_mod.textView(arena, .{ .id = "smoke-md", .blocks = blocks });
            })
            .childDiv(blk: {
                const code_state = code_input_mod.State{
                    .text = "a\nb\n",
                    .options = .{ .line_number = true },
                };
                break :blk code_input_mod.codeInput(arena, .{
                    .id = "smoke-code",
                    .state = &code_state,
                });
            });

        return root.any();
    }
};

test "catalog smoke: button and checkbox expose a11y roles" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 480, .height = 360 });
    defer harness.deinit();

    var fixture = CatalogFixture{ .harness = &harness };
    fixture.dialog_state = try harness.app.new(dialog_mod.DialogState, .{});
    fixture.checkbox_state = try harness.app.new(checkbox_mod.CheckboxState, .{});
    try harness.setRoot(&fixture, CatalogFixture.render);

    try std.testing.expectEqual(@as(?a11y_mod.Role, .button), harness.a11yRole("smoke-button"));
    try std.testing.expectEqual(@as(?a11y_mod.Role, .checkbox), harness.a11yRole("smoke-checkbox"));
    try std.testing.expect(harness.hitboxBounds(element.elementId("smoke-chart-bar-1")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("smoke-md-block-0")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("smoke-code-line-0")) != null);
}

test "catalog smoke: dialog open path registers overlay" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 320, .height = 200 });
    defer harness.deinit();

    var fixture = CatalogFixture{ .harness = &harness };
    fixture.dialog_state = try harness.app.new(dialog_mod.DialogState, .{});
    fixture.checkbox_state = try harness.app.new(checkbox_mod.CheckboxState, .{});
    try harness.setRoot(&fixture, CatalogFixture.render);

    try std.testing.expectEqual(@as(usize, 0), harness.overlays.layers.items.len);
    try harness.clickOn("smoke-button");
    try std.testing.expect(harness.app.read(dialog_mod.DialogState, fixture.dialog_state).open);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);
}

test "catalog smoke: a11y press opens dialog like a click" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 320, .height = 200 });
    defer harness.deinit();

    var fixture = CatalogFixture{ .harness = &harness };
    fixture.dialog_state = try harness.app.new(dialog_mod.DialogState, .{});
    fixture.checkbox_state = try harness.app.new(checkbox_mod.CheckboxState, .{});
    try harness.setRoot(&fixture, CatalogFixture.render);

    try harness.a11yPressOn("smoke-button");
    try std.testing.expect(harness.app.read(dialog_mod.DialogState, fixture.dialog_state).open);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);
}
