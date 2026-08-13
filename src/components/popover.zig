//! Headless popover: anchored overlay opened by trigger, dismissed via
//! Escape or outside click.

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
const Bounds = geometry.Bounds;
const Size = geometry.Size;

pub const PopoverState = struct {
    open: bool = false,
    /// When true, still render overlay while fading out.
    closing: bool = false,

    pub fn openPopover(self: *PopoverState) void {
        self.open = true;
        self.closing = false;
    }

    pub fn requestClose(self: *PopoverState) void {
        if (!self.open) return;
        self.closing = true;
    }

    pub fn finishClose(self: *PopoverState) void {
        self.open = false;
        self.closing = false;
    }

    /// Immediate close (no fade-out).
    pub fn close(self: *PopoverState) void {
        self.finishClose();
    }
};

pub const CloseOptions = struct {
    timeline: ?*animation_mod.Timeline = null,
    /// Popover `id` from Props — builds the fade animation key when set.
    id: []const u8 = "",
    fade_duration_ms: f32 = animation_mod.default_fade_ms,
};

pub const StyleState = struct {
    open: bool = false,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;
pub const ContentFn = *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!*Div;

pub const Props = struct {
    id: []const u8,
    /// Element id of the click trigger (used for anchor positioning).
    trigger_id: []const u8,
    state: app_mod.Entity(PopoverState),
    overlays: *overlay_mod.OverlayStack,
    app: *App,
    frame: *const element.FrameState,
    viewport: Size(Pixels),
    z_index: i32 = 60,
    trap_focus: bool = false,
    modal: bool = true,
    panel_style: ?StyleFn = null,
    content_ctx: ?*anyopaque = null,
    content_fn: ?ContentFn = null,
    /// When set, panel and backdrop fade in on open and out on close.
    timeline: ?*animation_mod.Timeline = null,
    fade_duration_ms: f32 = animation_mod.default_fade_ms,
};

const Host = struct {
    app: *App,
    state: app_mod.Entity(PopoverState),
    frame: *const element.FrameState,
    viewport: Size(Pixels),
    trigger_id: []const u8,
    panel_style: ?StyleFn,
    content_ctx: ?*anyopaque,
    content_fn: ?ContentFn,
    panel_id: []const u8,
    timeline: ?*animation_mod.Timeline = null,
    fade_duration_ms: f32 = animation_mod.default_fade_ms,

    fn fadeId(self: *const Host, buf: *[64]u8) animation_mod.AnimationId {
        const name = std.fmt.bufPrint(buf, "popover-fade-{s}", .{self.panel_id}) catch self.panel_id;
        return animation_mod.animationId(name);
    }

    fn ensureFadeIn(self: *const Host) void {
        const tl = self.timeline orelse return;
        const s = self.app.read(PopoverState, self.state);
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
        const s = self.app.read(PopoverState, self.state);
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
        const s = self.app.read(PopoverState, self.state);
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

    fn dismissMouseDown(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        dismiss(ctx);
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!element.Element {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        const is_open = self.app.read(PopoverState, self.state).open;
        if (!is_open) return div_mod.div(arena).sizePx(0, 0).any();

        self.ensureFadeIn();
        const fade_opacity = self.fadeOpacity();
        self.maybeFinishClose();

        var backdrop = div_mod.div(arena)
            .withId("popover-backdrop")
            .absolute()
            .wFull()
            .hFull()
            .interactive()
            .onMouseDown(self, dismissMouseDown);

        const anchor = triggerBounds(self.frame, self.trigger_id);

        var panel = div_mod.div(arena)
            .withId(self.panel_id)
            .absolute()
            .interactive();
        if (self.panel_style) |style_fn| {
            panel = panel.withStyle(Host.styleWithOpacity(style_fn(.{ .open = true }), fade_opacity));
        } else {
            var s = style_mod.Style{};
            s.width = .{ .px = 180 };
            s.min_height = .{ .px = 80 };
            s.background = animation_mod.scaleAlpha(Rgba.fromHex(0xffffff), fade_opacity);
            s.corner_radii = geometry.Corners(Pixels).all(6);
            s.padding = .{
                .top = .{ .px = 12 },
                .right = .{ .px = 12 },
                .bottom = .{ .px = 12 },
                .left = .{ .px = 12 },
            };
            panel = panel.withStyle(s);
        }
        panel = panel.onClick(null, struct {
            fn swallow(_: ?*anyopaque, _: *const platform.MouseButtonEvent) void {}
        }.swallow);

        if (self.content_fn) |content_fn| {
            const body = try content_fn(self.content_ctx, arena);
            panel = panel.childDiv(body);
        }

        if (anchor) |bounds| {
            var s = panel.style;
            s.position = .absolute;
            s.inset.top = .{ .px = bounds.origin.y + bounds.size.height + 4 };
            s.inset.left = .{ .px = bounds.origin.x };
            panel.style = s;
        } else {
            var s = panel.style;
            s.position = .absolute;
            s.inset.top = .{ .px = self.viewport.height / 2 - 40 };
            s.inset.left = .{ .px = self.viewport.width / 2 - 90 };
            panel.style = s;
        }

        return backdrop.childDiv(panel).any();
    }
};

const TriggerHost = struct {
    app: *App,
    state: app_mod.Entity(PopoverState),

    timeline: ?*animation_mod.Timeline = null,
    fade_duration_ms: f32 = animation_mod.default_fade_ms,
    popover_id: []const u8 = "",

    fn toggle(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *TriggerHost = @ptrCast(@alignCast(ctx.?));
        const s = self.app.read(PopoverState, self.state);
        if (s.open) {
            close(self.app, self.state, .{
                .timeline = self.timeline,
                .id = self.popover_id,
                .fade_duration_ms = self.fade_duration_ms,
            });
        } else {
            s.openPopover();
            self.app.notify(self.state.id);
        }
    }
};

fn triggerBounds(frame: *const element.FrameState, trigger_id: []const u8) ?Bounds(Pixels) {
    const id = element.elementId(trigger_id);
    for (frame.hitboxes.items) |hitbox| {
        if (hitbox.id != null and hitbox.id.? == id) return hitbox.bounds;
    }
    return null;
}

fn registerOverlay(arena: std.mem.Allocator, props: Props) !void {
    const is_open = props.app.read(PopoverState, props.state).open;
    if (!is_open) return;

    const host = arena.create(Host) catch @panic("frame arena OOM");
    host.* = .{
        .app = props.app,
        .state = props.state,
        .frame = props.frame,
        .viewport = props.viewport,
        .trigger_id = props.trigger_id,
        .panel_style = props.panel_style,
        .content_ctx = props.content_ctx,
        .content_fn = props.content_fn,
        .panel_id = props.id,
        .timeline = props.timeline,
        .fade_duration_ms = props.fade_duration_ms,
    };
    try props.overlays.push(.{
        .id = overlay_mod.overlayId(props.id),
        .z_index = props.z_index,
        .trap_focus = props.trap_focus,
        .modal = props.modal,
        .ctx = host,
        .render = Host.render,
        .on_dismiss = Host.dismiss,
    });
}

/// Zero-size main-tree placeholder; registers the popover overlay when open.
pub fn popover(arena: std.mem.Allocator, props: Props) !*Div {
    try registerOverlay(arena, props);
    return div_mod.div(arena).sizePx(0, 0);
}

/// Wire a click-to-toggle trigger and register the overlay when open.
pub fn popoverWithTrigger(
    arena: std.mem.Allocator,
    props: Props,
    trigger: *Div,
) !*Div {
    const trigger_host = arena.create(TriggerHost) catch @panic("frame arena OOM");
    trigger_host.* = .{
        .app = props.app,
        .state = props.state,
        .timeline = props.timeline,
        .fade_duration_ms = props.fade_duration_ms,
        .popover_id = props.id,
    };
    _ = trigger.onClick(trigger_host, TriggerHost.toggle);

    try registerOverlay(arena, props);
    return trigger;
}

pub fn open(app: *App, state: app_mod.Entity(PopoverState)) void {
    app.read(PopoverState, state).openPopover();
    app.notify(state.id);
}

pub fn close(app: *App, state: app_mod.Entity(PopoverState), options: CloseOptions) void {
    const s = app.read(PopoverState, state);
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
        const fade_name = std.fmt.bufPrint(&buf, "popover-fade-{s}", .{options.id}) catch options.id;
        animation_mod.fadeOut(tl, animation_mod.animationId(fade_name), options.fade_duration_ms);
    } else {
        s.finishClose();
    }
    app.notify(state.id);
}

pub fn toggle(app: *App, state: app_mod.Entity(PopoverState), options: CloseOptions) void {
    const s = app.read(PopoverState, state);
    if (s.open) {
        close(app, state, options);
    } else {
        s.openPopover();
        app.notify(state.id);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

const PopoverFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(PopoverState) = undefined,

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *PopoverFixture = @ptrCast(@alignCast(ctx.?));

        var trigger = div_mod.div(arena)
            .withId("popover-trigger")
            .sizePx(80, 30)
            .bg(Rgba.fromHex(0x336699));
        trigger = try popoverWithTrigger(arena, .{
            .id = "actions-popover",
            .trigger_id = "popover-trigger",
            .state = self.state,
            .overlays = &harness.overlays,
            .app = &harness.app,
            .frame = &harness.frame,
            .viewport = harness.viewport,
        }, trigger);

        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(trigger).any();
    }
};

const PopoverContentFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(PopoverState) = undefined,

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *PopoverContentFixture = @ptrCast(@alignCast(ctx.?));

        var trigger = div_mod.div(arena)
            .withId("popover-trigger")
            .sizePx(80, 30)
            .bg(Rgba.fromHex(0x336699));
        trigger = try popoverWithTrigger(arena, .{
            .id = "actions-popover",
            .trigger_id = "popover-trigger",
            .state = self.state,
            .overlays = &harness.overlays,
            .app = &harness.app,
            .frame = &harness.frame,
            .viewport = harness.viewport,
            .content_ctx = self,
            .content_fn = body,
        }, trigger);

        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(trigger).any();
    }

    fn body(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!*Div {
        const self: *PopoverContentFixture = @ptrCast(@alignCast(ctx.?));
        return div_mod.div(arena)
            .withId("popover-action")
            .sizePx(100, 24)
            .bg(Rgba.fromHex(0x22c55e))
            .onClick(self, actionClick);
    }

    fn actionClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *PopoverContentFixture = @ptrCast(@alignCast(ctx.?));
        close(&self.harness.app, self.state, .{});
    }
};

test "popover opens via trigger and closes via Escape" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = PopoverFixture{ .harness = &harness };
    fixture.state = try harness.app.new(PopoverState, .{});
    try harness.setRoot(&fixture, PopoverFixture.render);

    try std.testing.expect(!harness.app.read(PopoverState, fixture.state).open);
    try std.testing.expectEqual(@as(usize, 0), harness.overlays.layers.items.len);

    try harness.clickOn("popover-trigger");
    try std.testing.expect(harness.app.read(PopoverState, fixture.state).open);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);
    try std.testing.expect(harness.hitboxBounds(element.elementId("actions-popover")) != null);

    try harness.keyDown(.escape);
    try std.testing.expect(!harness.app.read(PopoverState, fixture.state).open);
}

test "popover closes via outside click" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = PopoverFixture{ .harness = &harness };
    fixture.state = try harness.app.new(PopoverState, .{});
    try harness.setRoot(&fixture, PopoverFixture.render);

    try harness.clickOn("popover-trigger");
    try std.testing.expect(harness.app.read(PopoverState, fixture.state).open);

    try harness.click(5, 5);
    try std.testing.expect(!harness.app.read(PopoverState, fixture.state).open);
}

test "popover action inside panel closes" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = PopoverContentFixture{ .harness = &harness };
    fixture.state = try harness.app.new(PopoverState, .{});
    try harness.setRoot(&fixture, PopoverContentFixture.render);

    try harness.clickOn("popover-trigger");
    try harness.clickOn("popover-action");
    try std.testing.expect(!harness.app.read(PopoverState, fixture.state).open);
}

test "popover fade-out keeps overlay until animation completes" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var timeline = animation_mod.Timeline.init();
    var fade_buf: [64]u8 = undefined;
    const fade_name = try std.fmt.bufPrint(&fade_buf, "popover-fade-{s}", .{"actions-popover"});
    const fade_id = animation_mod.animationId(fade_name);

    const FadeOutFixture = struct {
        harness: *testing_mod.Harness = undefined,
        state: app_mod.Entity(PopoverState) = undefined,
        timeline: *animation_mod.Timeline = undefined,

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, h: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));

            var trigger = div_mod.div(arena)
                .withId("popover-trigger")
                .sizePx(80, 30)
                .bg(Rgba.fromHex(0x336699));
            trigger = try popoverWithTrigger(arena, .{
                .id = "actions-popover",
                .trigger_id = "popover-trigger",
                .state = self.state,
                .overlays = &h.overlays,
                .app = &h.app,
                .frame = &h.frame,
                .viewport = h.viewport,
                .timeline = self.timeline,
            }, trigger);

            return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(trigger).any();
        }
    };

    var fixture = FadeOutFixture{ .harness = &harness, .timeline = &timeline };
    fixture.state = try harness.app.new(PopoverState, .{});
    try harness.setRoot(&fixture, FadeOutFixture.render);

    try harness.clickOn("popover-trigger");
    try harness.renderFrame();
    _ = timeline.tick(150);
    try harness.renderFrame();
    try std.testing.expectApproxEqAbs(@as(f32, 1), animation_mod.opacityOf(&timeline, fade_id, 1), 0.05);

    try harness.keyDown(.escape);
    const popover_state = harness.app.read(PopoverState, fixture.state);
    try std.testing.expect(popover_state.open);
    try std.testing.expect(popover_state.closing);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);

    _ = timeline.tick(75);
    try harness.renderFrame();
    const mid_opacity = animation_mod.opacityOf(&timeline, fade_id, 1);
    try std.testing.expect(mid_opacity < 0.99);
    try std.testing.expect(mid_opacity > 0.01);
    try std.testing.expect(harness.app.read(PopoverState, fixture.state).open);

    _ = timeline.tick(75);
    try harness.renderFrame();
    try std.testing.expect(!harness.app.read(PopoverState, fixture.state).open);
    try std.testing.expect(!harness.app.read(PopoverState, fixture.state).closing);

    try harness.renderFrame();
    try std.testing.expectEqual(@as(usize, 0), harness.overlays.layers.items.len);
}
