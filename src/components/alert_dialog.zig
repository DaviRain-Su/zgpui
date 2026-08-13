//! Alert dialog: thin confirm/cancel wrapper over `dialog`.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const overlay_mod = @import("../overlay.zig");
const color = @import("../color.zig");
const dialog_mod = @import("dialog.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Rgba = color.Rgba;

pub const AlertDialogState = dialog_mod.DialogState;

pub const ActionHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque) void,
};

pub const Props = struct {
    id: []const u8,
    state: app_mod.Entity(AlertDialogState),
    overlays: *overlay_mod.OverlayStack,
    app: *App,
    z_index: i32 = 110,
    on_confirm: ?ActionHandler = null,
    on_cancel: ?ActionHandler = null,
    panel_style: ?dialog_mod.StyleFn = null,
    backdrop_style: ?dialog_mod.BackdropStyleFn = null,
};

const Actions = struct {
    app: *App,
    state: app_mod.Entity(AlertDialogState),
    on_confirm: ?ActionHandler,
    on_cancel: ?ActionHandler,

    fn confirm(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *Actions = @ptrCast(@alignCast(ctx.?));
        if (self.on_confirm) |h| h.func(h.ctx);
        dialog_mod.close(self.app, self.state, .{});
    }

    fn cancel(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *Actions = @ptrCast(@alignCast(ctx.?));
        if (self.on_cancel) |h| h.func(h.ctx);
        dialog_mod.close(self.app, self.state, .{});
    }

    fn build(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!*Div {
        const self: *Actions = @ptrCast(@alignCast(ctx.?));
        const confirm_btn = div_mod.div(arena)
            .withId("alert-confirm")
            .sizePx(72, 28)
            .bg(Rgba.fromHex(0x22c55e))
            .role(.button)
            .a11yName("Confirm")
            .onClick(self, confirm);
        const cancel_btn = div_mod.div(arena)
            .withId("alert-cancel")
            .sizePx(72, 28)
            .bg(Rgba.fromHex(0xef4444))
            .role(.button)
            .a11yName("Cancel")
            .onClick(self, cancel);
        return div_mod.div(arena)
            .flexCol()
            .gapPx(12)
            .childDiv(div_mod.div(arena).withId("alert-body").sizePx(240, 40).bg(Rgba.fromHex(0xf3f4f6)))
            .childDiv(div_mod.div(arena).flexCol().gapPx(8).childDiv(confirm_btn).childDiv(cancel_btn));
    }
};

/// Register a modal alert with Confirm / Cancel actions when open.
pub fn alertDialog(arena: std.mem.Allocator, props: Props) !*Div {
    const actions = arena.create(Actions) catch @panic("frame arena OOM");
    actions.* = .{
        .app = props.app,
        .state = props.state,
        .on_confirm = props.on_confirm,
        .on_cancel = props.on_cancel,
    };
    return dialog_mod.dialogWithContent(arena, .{
        .id = props.id,
        .state = props.state,
        .overlays = props.overlays,
        .app = props.app,
        .z_index = props.z_index,
        .panel_style = props.panel_style,
        .backdrop_style = props.backdrop_style,
    }, actions, Actions.build);
}

pub const open = dialog_mod.open;
pub const close = dialog_mod.close;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const a11y_mod = @import("../a11y.zig");

const AlertFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(AlertDialogState) = undefined,
    confirmed: u32 = 0,
    cancelled: u32 = 0,

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *AlertFixture = @ptrCast(@alignCast(ctx.?));
        _ = try alertDialog(arena, .{
            .id = "alert",
            .state = self.state,
            .overlays = &harness.overlays,
            .app = &harness.app,
            .on_confirm = .{ .ctx = self, .func = onConfirm },
            .on_cancel = .{ .ctx = self, .func = onCancel },
        });
        const open_btn = div_mod.div(arena)
            .withId("open-alert")
            .sizePx(80, 30)
            .bg(Rgba.fromHex(0x336699))
            .onClick(self, openClick);
        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(open_btn).any();
    }

    fn openClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *AlertFixture = @ptrCast(@alignCast(ctx.?));
        open(&self.harness.app, self.state);
    }

    fn onConfirm(ctx: ?*anyopaque) void {
        const self: *AlertFixture = @ptrCast(@alignCast(ctx.?));
        self.confirmed += 1;
    }

    fn onCancel(ctx: ?*anyopaque) void {
        const self: *AlertFixture = @ptrCast(@alignCast(ctx.?));
        self.cancelled += 1;
    }
};

test "alert dialog exposes confirm and cancel button a11y" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = AlertFixture{ .harness = &harness };
    fixture.state = try harness.app.new(AlertDialogState, .{});
    try harness.setRoot(&fixture, AlertFixture.render);

    try harness.clickOn("open-alert");
    try std.testing.expectEqual(a11y_mod.Role.button, harness.a11yRole("alert-confirm").?);
    try std.testing.expectEqualStrings("Confirm", harness.a11yName("alert-confirm").?);
    try std.testing.expectEqual(a11y_mod.Role.button, harness.a11yRole("alert-cancel").?);
    try std.testing.expectEqualStrings("Cancel", harness.a11yName("alert-cancel").?);
}

test "alert dialog confirm fires and closes" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = AlertFixture{ .harness = &harness };
    fixture.state = try harness.app.new(AlertDialogState, .{});
    try harness.setRoot(&fixture, AlertFixture.render);

    try harness.clickOn("open-alert");
    try std.testing.expect(harness.app.read(AlertDialogState, fixture.state).open);
    try harness.clickOn("alert-confirm");
    try std.testing.expect(!harness.app.read(AlertDialogState, fixture.state).open);
    try std.testing.expectEqual(@as(u32, 1), fixture.confirmed);
}

test "alert dialog cancel fires and closes" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = AlertFixture{ .harness = &harness };
    fixture.state = try harness.app.new(AlertDialogState, .{});
    try harness.setRoot(&fixture, AlertFixture.render);

    try harness.clickOn("open-alert");
    try harness.clickOn("alert-cancel");
    try std.testing.expect(!harness.app.read(AlertDialogState, fixture.state).open);
    try std.testing.expectEqual(@as(u32, 1), fixture.cancelled);
}
