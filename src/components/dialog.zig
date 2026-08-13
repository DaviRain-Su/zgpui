//! Headless dialog: modal overlay with backdrop, Escape/outside dismiss,
//! and compound parts (title / body / actions).

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const overlay_mod = @import("../overlay.zig");
const color = @import("../color.zig");
const geometry = @import("../geometry.zig");
const animation_mod = @import("../animation.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Rgba = color.Rgba;
const Pixels = geometry.Pixels;

pub const DialogState = struct {
    open: bool = false,
    /// When true, still render overlay while fading out.
    closing: bool = false,

    pub fn openDialog(self: *DialogState) void {
        self.open = true;
        self.closing = false;
    }

    pub fn requestClose(self: *DialogState) void {
        if (!self.open) return;
        self.closing = true;
    }

    pub fn finishClose(self: *DialogState) void {
        self.open = false;
        self.closing = false;
    }

    /// Immediate close (no fade-out).
    pub fn close(self: *DialogState) void {
        self.finishClose();
    }
};

pub const CloseOptions = struct {
    timeline: ?*animation_mod.Timeline = null,
    /// Dialog `id` from Props — builds the fade animation key when set.
    id: []const u8 = "",
    fade_duration_ms: f32 = animation_mod.default_fade_ms,
};

pub const StyleState = struct {
    open: bool = false,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;
pub const BackdropStyleFn = *const fn () style_mod.Style;

pub const Props = struct {
    id: []const u8,
    state: app_mod.Entity(DialogState),
    /// Overlay stack from Window/Harness — required to actually show.
    overlays: *overlay_mod.OverlayStack,
    app: *App,
    z_index: i32 = 100,
    panel_style: ?StyleFn = null,
    backdrop_style: ?BackdropStyleFn = null,
    a11y_label: ?[]const u8 = null,
    /// When set, backdrop and panel fade in on open.
    timeline: ?*animation_mod.Timeline = null,
    fade_duration_ms: f32 = animation_mod.default_fade_ms,
};

const Host = struct {
    app: *App,
    state: app_mod.Entity(DialogState),
    panel_style: ?StyleFn,
    backdrop_style: ?BackdropStyleFn,
    a11y_label: ?[]const u8,
    id: []const u8,
    timeline: ?*animation_mod.Timeline = null,
    fade_duration_ms: f32 = animation_mod.default_fade_ms,
    /// Optional content builder for the panel body.
    content_ctx: ?*anyopaque = null,
    content_fn: ?*const fn (ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!*Div = null,

    fn fadeId(self: *const Host, buf: *[64]u8) animation_mod.AnimationId {
        const name = std.fmt.bufPrint(buf, "dialog-fade-{s}", .{self.id}) catch self.id;
        return animation_mod.animationId(name);
    }

    fn ensureFadeIn(self: *const Host) void {
        const tl = self.timeline orelse return;
        const s = self.app.read(DialogState, self.state);
        if (s.closing) return;
        var buf: [64]u8 = undefined;
        const id = self.fadeId(&buf);
        if (tl.isActive(id)) return;
        if (tl.value(id)) |opacity| {
            if (opacity > 0.001) return;
            tl.startTween(id, .{
                .from = 0,
                .to = 1,
                .duration_ms = self.fade_duration_ms,
                .easing = .ease_out,
            });
            return;
        }
        animation_mod.fadeIn(tl, id, self.fade_duration_ms);
    }

    fn fadeOpacity(self: *const Host) f32 {
        const tl = self.timeline orelse return 1;
        var buf: [64]u8 = undefined;
        return animation_mod.opacityOf(tl, self.fadeId(&buf), 1);
    }

    fn maybeFinishClose(self: *Host) void {
        const s = self.app.read(DialogState, self.state);
        if (!s.closing) return;
        const tl = self.timeline orelse {
            s.finishClose();
            self.app.notify(self.state.id);
            return;
        };
        var buf: [64]u8 = undefined;
        const id = self.fadeId(&buf);
        const opacity = animation_mod.opacityOf(tl, id, 1);
        if (!tl.isActive(id) or opacity <= 0.001) {
            s.finishClose();
            self.app.notify(self.state.id);
        }
    }

    fn beginClose(self: *Host) void {
        const s = self.app.read(DialogState, self.state);
        if (!s.open) return;
        if (self.timeline) |tl| {
            if (s.closing) return;
            s.requestClose();
            var buf: [64]u8 = undefined;
            animation_mod.fadeOut(tl, self.fadeId(&buf), self.fade_duration_ms);
        } else {
            s.finishClose();
        }
        self.app.notify(self.state.id);
    }

    fn styleWithOpacity(style: style_mod.Style, alpha: f32) style_mod.Style {
        var s = style;
        if (s.background) |bg| s.background = animation_mod.scaleAlpha(bg, alpha);
        return s;
    }

    fn dismiss(ctx: ?*anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        self.beginClose();
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!element.Element {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        const is_open = self.app.read(DialogState, self.state).open;
        self.ensureFadeIn();
        const fade_opacity = self.fadeOpacity();
        self.maybeFinishClose();

        var backdrop = div_mod.div(arena)
            .withId(self.id)
            .absolute()
            .wFull()
            .hFull()
            .interactive();
        if (self.backdrop_style) |style_fn| {
            backdrop = backdrop.withStyle(Host.styleWithOpacity(style_fn(), fade_opacity));
        } else {
            backdrop = backdrop.bg(Rgba.init(0, 0, 0, 0.45 * fade_opacity));
        }
        // Clicking the backdrop dismisses.
        backdrop = backdrop.onClick(self, struct {
            fn onClick(c: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
                dismiss(c);
            }
        }.onClick);

        if (!is_open) return backdrop.any();

        var panel = div_mod.div(arena)
            .withId("dialog-panel")
            .interactive()
            .role(.dialog)
            .focusable(element.elementId("dialog-panel"), null);
        if (self.a11y_label) |label| panel = panel.a11yName(label);
        if (self.panel_style) |style_fn| {
            panel = panel.withStyle(Host.styleWithOpacity(style_fn(.{ .open = true }), fade_opacity));
        } else {
            var s = style_mod.Style{};
            s.width = .{ .px = 320 };
            s.min_height = .{ .px = 120 };
            s.background = Rgba.fromHex(0xffffff);
            s.corner_radii = geometry.Corners(Pixels).all(8);
            s.padding = .{
                .top = .{ .px = 16 },
                .right = .{ .px = 16 },
                .bottom = .{ .px = 16 },
                .left = .{ .px = 16 },
            };
            panel = panel.withStyle(Host.styleWithOpacity(s, fade_opacity));
        }
        // Stop backdrop click when interacting with the panel.
        panel = panel.onClick(null, struct {
            fn swallow(_: ?*anyopaque, _: *const platform.MouseButtonEvent) void {}
        }.swallow);

        if (self.content_fn) |content_fn| {
            const body = try content_fn(self.content_ctx, arena);
            panel = panel.childDiv(body);
        }

        // Center the panel with a flex container filling the backdrop.
        const center = div_mod.div(arena)
            .wFull()
            .hFull()
            .flexCol()
            .itemsCenter()
            .justifyCenter()
            .childDiv(panel);

        return backdrop.childDiv(center).any();
    }
};

/// Register the dialog overlay for this frame when `state.open`.
/// Returns a zero-size placeholder for the main tree (dialog renders in overlay).
pub fn dialog(arena: std.mem.Allocator, props: Props) !*Div {
    const is_open = props.app.read(DialogState, props.state).open;
    if (is_open) {
        const host = arena.create(Host) catch @panic("frame arena OOM");
        host.* = .{
            .app = props.app,
            .state = props.state,
            .panel_style = props.panel_style,
            .backdrop_style = props.backdrop_style,
            .a11y_label = props.a11y_label,
            .id = props.id,
            .timeline = props.timeline,
            .fade_duration_ms = props.fade_duration_ms,
        };
        try props.overlays.push(.{
            .id = overlay_mod.overlayId(props.id),
            .z_index = props.z_index,
            .trap_focus = true,
            .modal = true,
            .ctx = host,
            .render = Host.render,
            .on_dismiss = Host.dismiss,
        });
    }
    // Placeholder in the main tree.
    return div_mod.div(arena).sizePx(0, 0);
}

/// Like `dialog`, but attaches a content builder for the panel body.
pub fn dialogWithContent(
    arena: std.mem.Allocator,
    props: Props,
    content_ctx: ?*anyopaque,
    content_fn: *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!*Div,
) !*Div {
    const is_open = props.app.read(DialogState, props.state).open;
    if (is_open) {
        const host = arena.create(Host) catch @panic("frame arena OOM");
        host.* = .{
            .app = props.app,
            .state = props.state,
            .panel_style = props.panel_style,
            .backdrop_style = props.backdrop_style,
            .a11y_label = props.a11y_label,
            .id = props.id,
            .timeline = props.timeline,
            .fade_duration_ms = props.fade_duration_ms,
            .content_ctx = content_ctx,
            .content_fn = content_fn,
        };
        try props.overlays.push(.{
            .id = overlay_mod.overlayId(props.id),
            .z_index = props.z_index,
            .trap_focus = true,
            .modal = true,
            .ctx = host,
            .render = Host.render,
            .on_dismiss = Host.dismiss,
        });
    }
    return div_mod.div(arena).sizePx(0, 0);
}

pub fn open(app: *App, state: app_mod.Entity(DialogState)) void {
    app.read(DialogState, state).openDialog();
    app.notify(state.id);
}

pub fn close(app: *App, state: app_mod.Entity(DialogState), options: CloseOptions) void {
    const s = app.read(DialogState, state);
    if (!s.open) return;
    if (options.timeline) |tl| {
        if (options.id.len == 0) {
            s.finishClose();
            app.notify(state.id);
            return;
        }
        if (s.closing) return;
        s.requestClose();
        var buf: [64]u8 = undefined;
        const fade_name = std.fmt.bufPrint(&buf, "dialog-fade-{s}", .{options.id}) catch options.id;
        animation_mod.fadeOut(tl, animation_mod.animationId(fade_name), options.fade_duration_ms);
    } else {
        s.finishClose();
    }
    app.notify(state.id);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

const DialogFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(DialogState) = undefined,

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *DialogFixture = @ptrCast(@alignCast(ctx.?));
        _ = try dialogWithContent(arena, .{
            .id = "confirm",
            .state = self.state,
            .overlays = &harness.overlays,
            .app = &harness.app,
            .a11y_label = "Confirmation",
        }, self, body);

        const open_btn = div_mod.div(arena)
            .withId("open-btn")
            .sizePx(80, 30)
            .bg(Rgba.fromHex(0x336699))
            .onClick(self, openClick);

        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(open_btn).any();
    }

    fn body(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!*Div {
        const self: *DialogFixture = @ptrCast(@alignCast(ctx.?));
        return div_mod.div(arena)
            .flexCol()
            .gapPx(8)
            .childDiv(div_mod.div(arena).withId("dialog-title").sizePx(200, 20).bg(Rgba.fromHex(0xeeeeee)))
            .childDiv(div_mod.div(arena)
            .withId("dialog-ok")
            .sizePx(60, 28)
            .bg(Rgba.fromHex(0x22c55e))
            .role(.button)
            .a11yName("OK")
            .onClick(self, okClick));
    }

    fn openClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *DialogFixture = @ptrCast(@alignCast(ctx.?));
        open(&self.harness.app, self.state);
    }

    fn okClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *DialogFixture = @ptrCast(@alignCast(ctx.?));
        close(&self.harness.app, self.state, .{});
    }
};

test "dialog opens via trigger and closes via Escape" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = DialogFixture{ .harness = &harness };
    fixture.state = try harness.app.new(DialogState, .{});
    try harness.setRoot(&fixture, DialogFixture.render);

    try std.testing.expect(!harness.app.read(DialogState, fixture.state).open);
    try std.testing.expect(harness.overlays.layers.items.len == 0);

    try harness.clickOn("open-btn");
    try std.testing.expect(harness.app.read(DialogState, fixture.state).open);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);
    try std.testing.expect(harness.overlays.topFrame().?.hitboxes.items.len >= 1);
    try std.testing.expectEqual(@import("../a11y.zig").Role.dialog, harness.a11yRole("dialog-panel").?);
    try std.testing.expectEqualStrings("Confirmation", harness.a11yName("dialog-panel").?);

    try harness.keyDown(.escape);
    try std.testing.expect(!harness.app.read(DialogState, fixture.state).open);
}

test "dialog closes via backdrop click" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = DialogFixture{ .harness = &harness };
    fixture.state = try harness.app.new(DialogState, .{});
    try harness.setRoot(&fixture, DialogFixture.render);

    try harness.clickOn("open-btn");
    try std.testing.expect(harness.app.read(DialogState, fixture.state).open);

    // Click near corner — backdrop, outside centered panel.
    try harness.click(5, 5);
    try std.testing.expect(!harness.app.read(DialogState, fixture.state).open);
}

test "dialog ok button closes" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = DialogFixture{ .harness = &harness };
    fixture.state = try harness.app.new(DialogState, .{});
    try harness.setRoot(&fixture, DialogFixture.render);

    try harness.clickOn("open-btn");
    try harness.clickOn("dialog-ok");
    try std.testing.expect(!harness.app.read(DialogState, fixture.state).open);
}

test "dialog button activates through accessibility press" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = DialogFixture{ .harness = &harness };
    fixture.state = try harness.app.new(DialogState, .{});
    try harness.setRoot(&fixture, DialogFixture.render);

    try harness.clickOn("open-btn");
    try harness.a11yPressOn("dialog-ok");
    try std.testing.expect(!harness.app.read(DialogState, fixture.state).open);
}

test "dialog fade-in scales backdrop alpha via timeline" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var timeline = animation_mod.Timeline.init();
    var fade_buf: [64]u8 = undefined;
    const fade_name = try std.fmt.bufPrint(&fade_buf, "dialog-fade-{s}", .{"fade-dialog"});
    const fade_id = animation_mod.animationId(fade_name);

    const FadeFixture = struct {
        harness: *testing_mod.Harness = undefined,
        state: app_mod.Entity(DialogState) = undefined,
        timeline: *animation_mod.Timeline = undefined,

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, h: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = try dialog(arena, .{
                .id = "fade-dialog",
                .state = self.state,
                .overlays = &h.overlays,
                .app = &h.app,
                .timeline = self.timeline,
            });
            return div_mod.div(arena).sizePx(400, 300).any();
        }
    };

    var fixture = FadeFixture{ .harness = &harness, .timeline = &timeline };
    fixture.state = try harness.app.new(DialogState, .{});
    try harness.setRoot(&fixture, FadeFixture.render);

    open(&harness.app, fixture.state);
    try harness.renderFrame();
    try std.testing.expectApproxEqAbs(@as(f32, 0), animation_mod.opacityOf(&timeline, fade_id, 1), 0.001);

    _ = timeline.tick(150);
    try harness.renderFrame();
    try std.testing.expectApproxEqAbs(@as(f32, 1), animation_mod.opacityOf(&timeline, fade_id, 1), 0.05);

    const backdrop_alpha = findBackdropAlpha(&harness);
    try std.testing.expect(backdrop_alpha != null);
    try std.testing.expectApproxEqAbs(@as(f32, 0.45), backdrop_alpha.?, 0.05);
}

test "dialog fade-out keeps overlay until animation completes" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var timeline = animation_mod.Timeline.init();
    var fade_buf: [64]u8 = undefined;
    const fade_name = try std.fmt.bufPrint(&fade_buf, "dialog-fade-{s}", .{"fade-out-dialog"});
    const fade_id = animation_mod.animationId(fade_name);

    const FadeOutFixture = struct {
        harness: *testing_mod.Harness = undefined,
        state: app_mod.Entity(DialogState) = undefined,
        timeline: *animation_mod.Timeline = undefined,

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, h: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = try dialog(arena, .{
                .id = "fade-out-dialog",
                .state = self.state,
                .overlays = &h.overlays,
                .app = &h.app,
                .timeline = self.timeline,
            });
            return div_mod.div(arena).sizePx(400, 300).any();
        }
    };

    var fixture = FadeOutFixture{ .harness = &harness, .timeline = &timeline };
    fixture.state = try harness.app.new(DialogState, .{});
    try harness.setRoot(&fixture, FadeOutFixture.render);

    open(&harness.app, fixture.state);
    try harness.renderFrame();
    _ = timeline.tick(150);
    try harness.renderFrame();
    try std.testing.expectApproxEqAbs(@as(f32, 1), animation_mod.opacityOf(&timeline, fade_id, 1), 0.05);

    try harness.keyDown(.escape);
    const dialog_state = harness.app.read(DialogState, fixture.state);
    try std.testing.expect(dialog_state.open);
    try std.testing.expect(dialog_state.closing);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);

    _ = timeline.tick(75);
    try harness.renderFrame();
    const mid_opacity = animation_mod.opacityOf(&timeline, fade_id, 1);
    try std.testing.expect(mid_opacity < 0.99);
    try std.testing.expect(mid_opacity > 0.01);
    try std.testing.expect(harness.app.read(DialogState, fixture.state).open);

    _ = timeline.tick(75);
    try harness.renderFrame();
    try std.testing.expect(!harness.app.read(DialogState, fixture.state).open);
    try std.testing.expect(!harness.app.read(DialogState, fixture.state).closing);

    try harness.renderFrame();
    try std.testing.expectEqual(@as(usize, 0), harness.overlays.layers.items.len);
}

fn findBackdropAlpha(harness: *testing_mod.Harness) ?f32 {
    for (harness.scene.quads.items) |quad| {
        if (quad.bounds.size_w >= 399 and quad.bounds.size_h >= 299) {
            return quad.background.a;
        }
    }
    return null;
}
