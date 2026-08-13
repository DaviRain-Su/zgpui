//! Headless sheet: modal side/bottom panel overlay with backdrop dismiss,
//! Escape close, and optional focus trapping.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const overlay_mod = @import("../overlay.zig");
const value_mod = @import("../value.zig");
const color = @import("../color.zig");
const geometry = @import("../geometry.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Rgba = color.Rgba;
const Pixels = geometry.Pixels;

pub const OpenValue = value_mod.Value(bool);

pub const Side = enum {
    bottom,
    left,
    right,
    top,
};

pub fn defaultPanelStyle(side: Side) style_mod.Style {
    var s = style_mod.Style{};
    s.background = Rgba.fromHex(0xffffff);
    s.corner_radii = geometry.Corners(Pixels).all(8);
    s.padding = .{
        .top = .{ .px = 16 },
        .right = .{ .px = 16 },
        .bottom = .{ .px = 16 },
        .left = .{ .px = 16 },
    };
    s.position = .absolute;
    switch (side) {
        .bottom => {
            s.width = .{ .percent = 100 };
            s.height = .{ .px = 240 };
            s.inset.bottom = .{ .px = 0 };
            s.inset.left = .{ .px = 0 };
            s.inset.right = .{ .px = 0 };
        },
        .top => {
            s.width = .{ .percent = 100 };
            s.height = .{ .px = 240 };
            s.inset.top = .{ .px = 0 };
            s.inset.left = .{ .px = 0 };
            s.inset.right = .{ .px = 0 };
        },
        .left => {
            s.width = .{ .px = 280 };
            s.height = .{ .percent = 100 };
            s.inset.top = .{ .px = 0 };
            s.inset.bottom = .{ .px = 0 };
            s.inset.left = .{ .px = 0 };
        },
        .right => {
            s.width = .{ .px = 280 };
            s.height = .{ .percent = 100 };
            s.inset.top = .{ .px = 0 };
            s.inset.bottom = .{ .px = 0 };
            s.inset.right = .{ .px = 0 };
        },
    }
    return s;
}

pub const StyleState = struct {
    open: bool = false,
    side: Side = .bottom,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;
pub const BackdropStyleFn = *const fn () style_mod.Style;
pub const ContentFn = *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!*Div;

pub const Props = struct {
    id: []const u8,
    open: OpenValue,
    side: Side = .bottom,
    overlays: *overlay_mod.OverlayStack,
    app: *App,
    z_index: i32 = 95,
    trap_focus: bool = true,
    panel_style: ?StyleFn = null,
    backdrop_style: ?BackdropStyleFn = null,
    a11y_label: ?[]const u8 = null,
    content_ctx: ?*anyopaque = null,
    content_fn: ?ContentFn = null,
};

const Host = struct {
    app: *App,
    open: OpenValue,
    side: Side,
    panel_style: ?StyleFn,
    backdrop_style: ?BackdropStyleFn,
    a11y_label: ?[]const u8,
    content_ctx: ?*anyopaque,
    content_fn: ?ContentFn,
    sheet_id: []const u8,

    fn dismiss(ctx: ?*anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        _ = self.open.setIfUncontrolled(self.app, false);
    }

    fn dismissClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        dismiss(ctx);
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!element.Element {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        const is_open = self.open.get(self.app);
        if (!is_open) return div_mod.div(arena).sizePx(0, 0).any();

        var backdrop = div_mod.div(arena)
            .withId(self.sheet_id)
            .absolute()
            .wFull()
            .hFull()
            .interactive();
        if (self.backdrop_style) |style_fn| {
            backdrop = backdrop.withStyle(style_fn());
        } else {
            backdrop = backdrop.bg(Rgba.init(0, 0, 0, 0.45));
        }
        backdrop = backdrop.onClick(self, dismissClick);

        var panel = div_mod.div(arena)
            .withId("sheet-panel")
            .absolute()
            .interactive()
            .role(.dialog)
            .a11yModal(true)
            .focusable(element.elementId("sheet-panel"), null);
        if (self.a11y_label) |label| panel = panel.a11yName(label);
        if (self.panel_style) |style_fn| {
            panel = panel.withStyle(style_fn(.{ .open = true, .side = self.side }));
        } else {
            panel = panel.withStyle(defaultPanelStyle(self.side));
        }
        panel = panel.onClick(null, struct {
            fn swallow(_: ?*anyopaque, _: *const platform.MouseButtonEvent) void {}
        }.swallow);

        if (self.content_fn) |content_fn| {
            const body = try content_fn(self.content_ctx, arena);
            panel = panel.childDiv(body);
        }

        return backdrop.childDiv(panel).any();
    }
};

pub fn isOpen(app: *App, open: OpenValue) bool {
    return open.get(app);
}

pub fn openSheet(app: *App, open: OpenValue) void {
    open.set(app, true);
}

pub fn close(app: *App, open: OpenValue) void {
    open.set(app, false);
}

/// Zero-size main-tree placeholder; registers the sheet overlay when open.
pub fn sheet(arena: std.mem.Allocator, props: Props) !*Div {
    if (!isOpen(props.app, props.open)) return div_mod.div(arena).sizePx(0, 0);

    const host = arena.create(Host) catch @panic("frame arena OOM");
    host.* = .{
        .app = props.app,
        .open = props.open,
        .side = props.side,
        .panel_style = props.panel_style,
        .backdrop_style = props.backdrop_style,
        .a11y_label = props.a11y_label,
        .content_ctx = props.content_ctx,
        .content_fn = props.content_fn,
        .sheet_id = props.id,
    };
    try props.overlays.push(.{
        .id = overlay_mod.overlayId(props.id),
        .z_index = props.z_index,
        .trap_focus = props.trap_focus,
        .modal = true,
        .ctx = host,
        .render = Host.render,
        .on_dismiss = Host.dismiss,
    });
    return div_mod.div(arena).sizePx(0, 0);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

const SheetFixture = struct {
    harness: *testing_mod.Harness = undefined,
    open_state: app_mod.Entity(OpenValue.Store) = undefined,

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *SheetFixture = @ptrCast(@alignCast(ctx.?));
        const open: OpenValue = .{ .uncontrolled = self.open_state };

        _ = try sheet(arena, .{
            .id = "settings-sheet",
            .open = open,
            .side = .bottom,
            .overlays = &harness.overlays,
            .app = &harness.app,
            .a11y_label = "Settings",
        });

        const open_btn = div_mod.div(arena)
            .withId("open-sheet")
            .sizePx(100, 30)
            .bg(Rgba.fromHex(0x336699))
            .onClick(self, openClick);

        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(open_btn).any();
    }

    fn openClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *SheetFixture = @ptrCast(@alignCast(ctx.?));
        openSheet(&self.harness.app, .{ .uncontrolled = self.open_state });
    }
};

test "sheet opens and closes via Escape" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = SheetFixture{ .harness = &harness };
    fixture.open_state = try harness.app.new(OpenValue.Store, .{ .value = false });
    try harness.setRoot(&fixture, SheetFixture.render);

    try std.testing.expect(!isOpen(&harness.app, .{ .uncontrolled = fixture.open_state }));
    try std.testing.expectEqual(@as(usize, 0), harness.overlays.layers.items.len);

    try harness.clickOn("open-sheet");
    try std.testing.expect(isOpen(&harness.app, .{ .uncontrolled = fixture.open_state }));
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);
    try std.testing.expect(harness.hitboxBounds(element.elementId("sheet-panel")) != null);
    try std.testing.expectEqual(@import("../a11y.zig").Role.dialog, harness.a11yRole("sheet-panel").?);
    try std.testing.expectEqualStrings("Settings", harness.a11yName("sheet-panel").?);
    try std.testing.expect(harness.a11yNode("sheet-panel").?.modal);

    try harness.keyDown(.escape);
    try std.testing.expect(!isOpen(&harness.app, .{ .uncontrolled = fixture.open_state }));
}

test "sheet closes via backdrop click" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = SheetFixture{ .harness = &harness };
    fixture.open_state = try harness.app.new(OpenValue.Store, .{ .value = false });
    try harness.setRoot(&fixture, SheetFixture.render);

    try harness.clickOn("open-sheet");
    try std.testing.expect(isOpen(&harness.app, .{ .uncontrolled = fixture.open_state }));

    try harness.click(5, 5);
    try std.testing.expect(!isOpen(&harness.app, .{ .uncontrolled = fixture.open_state }));
}
