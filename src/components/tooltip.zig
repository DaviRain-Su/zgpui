//! Headless tooltip: non-modal overlay shown on trigger hover, dismissed on
//! mouse leave or Escape.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const app_mod = @import("../app.zig");
const overlay_mod = @import("../overlay.zig");
const color = @import("../color.zig");
const geometry = @import("../geometry.zig");
const animation_mod = @import("../animation.zig");

const positioner = @import("positioner.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Rgba = color.Rgba;
const Pixels = geometry.Pixels;
const Bounds = geometry.Bounds;
const Size = geometry.Size;
const Point = geometry.Point;

pub const TooltipState = struct {
    visible: bool = false,
    /// When true, still render overlay while fading out (`visible` stays true).
    closing: bool = false,
    trigger_hovered: bool = false,
    hover_frames: u32 = 0,

    pub fn show(self: *TooltipState) void {
        self.visible = true;
        self.closing = false;
    }

    pub fn requestHide(self: *TooltipState) void {
        if (!self.visible) return;
        self.closing = true;
    }

    pub fn finishHide(self: *TooltipState) void {
        self.visible = false;
        self.closing = false;
        self.trigger_hovered = false;
        self.hover_frames = 0;
    }

    /// Immediate hide (no fade-out).
    pub fn hide(self: *TooltipState) void {
        self.finishHide();
    }
};

pub const HideOptions = struct {
    timeline: ?*animation_mod.Timeline = null,
    /// Tooltip `id` from Props — builds the fade animation key when set.
    id: []const u8 = "",
    fade_duration_ms: f32 = animation_mod.default_fade_ms,
};

pub const StyleState = struct {
    visible: bool = false,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;
pub const ContentFn = *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!*Div;

pub const Props = struct {
    id: []const u8,
    /// Element id of the hover trigger (used for anchor positioning).
    trigger_id: []const u8,
    state: app_mod.Entity(TooltipState),
    overlays: *overlay_mod.OverlayStack,
    app: *App,
    /// Main-tree frame (hitboxes available when the overlay renders).
    frame: *const element.FrameState,
    viewport: Size(Pixels),
    z_index: i32 = 50,
    /// Frames to wait after hover before showing (0 = immediate).
    show_delay_frames: u32 = 0,
    panel_style: ?StyleFn = null,
    a11y_label: ?[]const u8 = null,
    content_ctx: ?*anyopaque = null,
    content_fn: ?ContentFn = null,
    timeline: ?*animation_mod.Timeline = null,
    fade_duration_ms: f32 = animation_mod.default_fade_ms,
    placement: positioner.Placement = .bottom,
    alignment: positioner.Align = .center,
    offset: Pixels = 4,
    margin: Pixels = 8,
    panel_size: Size(Pixels) = .{ .width = 120, .height = 28 },
};

const Host = struct {
    app: *App,
    state: app_mod.Entity(TooltipState),
    frame: *const element.FrameState,
    viewport: Size(Pixels),
    trigger_id: []const u8,
    panel_style: ?StyleFn,
    a11y_label: ?[]const u8,
    content_ctx: ?*anyopaque,
    content_fn: ?ContentFn,
    tooltip_id: []const u8,
    timeline: ?*animation_mod.Timeline = null,
    fade_duration_ms: f32 = animation_mod.default_fade_ms,
    placement: positioner.Placement = .bottom,
    alignment: positioner.Align = .center,
    offset: Pixels = 4,
    margin: Pixels = 8,
    panel_size: Size(Pixels) = .{ .width = 120, .height = 28 },

    fn fadeId(self: *const Host, buf: *[64]u8) animation_mod.AnimationId {
        const name = std.fmt.bufPrint(buf, "tooltip-fade-{s}", .{self.tooltip_id}) catch self.tooltip_id;
        return animation_mod.animationId(name);
    }

    fn ensureFadeIn(self: *const Host) void {
        const tl = self.timeline orelse return;
        const s = self.app.read(TooltipState, self.state);
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

    fn maybeFinishHide(self: *Host) void {
        const s = self.app.read(TooltipState, self.state);
        if (!s.closing) return;
        const tl = self.timeline orelse {
            s.finishHide();
            self.app.notify(self.state.id);
            return;
        };
        var buf: [64]u8 = undefined;
        const id = self.fadeId(&buf);
        const opacity = animation_mod.opacityOf(tl, id, 1);
        if (!tl.isActive(id) or opacity <= 0.001) {
            s.finishHide();
            self.app.notify(self.state.id);
        }
    }

    fn beginHide(self: *Host) void {
        const s = self.app.read(TooltipState, self.state);
        if (!s.visible) return;
        if (self.timeline) |tl| {
            if (s.closing) return;
            s.requestHide();
            var buf: [64]u8 = undefined;
            animation_mod.fadeOut(tl, self.fadeId(&buf), self.fade_duration_ms);
        } else {
            s.finishHide();
        }
        self.app.notify(self.state.id);
    }

    fn dismiss(ctx: ?*anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        self.beginHide();
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!element.Element {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        const visible = self.app.read(TooltipState, self.state).visible;
        if (!visible) {
            return div_mod.div(arena).sizePx(0, 0).any();
        }

        self.ensureFadeIn();
        const fade_opacity = self.fadeOpacity();
        self.maybeFinishHide();

        const anchor = triggerBounds(self.frame, self.trigger_id);

        var panel = div_mod.div(arena)
            .withId(self.tooltip_id)
            .absolute()
            .interactive()
            .role(.tooltip);
        if (self.a11y_label) |label| panel = panel.a11yName(label);
        if (self.panel_style) |style_fn| {
            var s = style_fn(.{ .visible = true });
            if (s.background) |bg| s.background = animation_mod.scaleAlpha(bg, fade_opacity);
            panel = panel.withStyle(s);
        } else {
            var s = style_mod.Style{};
            s.width = .{ .px = 120 };
            s.min_height = .{ .px = 28 };
            s.background = animation_mod.scaleAlpha(Rgba.fromHex(0x1e1e2e), fade_opacity);
            s.corner_radii = geometry.Corners(Pixels).all(4);
            s.padding = .{
                .top = .{ .px = 6 },
                .right = .{ .px = 8 },
                .bottom = .{ .px = 6 },
                .left = .{ .px = 8 },
            };
            panel = panel.withStyle(s);
        }

        if (self.content_fn) |content_fn| {
            const body = try content_fn(self.content_ctx, arena);
            panel = panel.childDiv(body);
        }

        const origin: Point(Pixels) = if (anchor) |bounds|
            positioner.resolveSide(.{
                .trigger = bounds,
                .popup_size = self.panel_size,
                .viewport = self.viewport,
                .preferred = self.placement,
                .alignment = self.alignment,
                .offset = self.offset,
                .margin = self.margin,
            }).origin
        else
            .{
                .x = self.viewport.width / 2 - self.panel_size.width / 2,
                .y = self.viewport.height / 2 - self.panel_size.height / 2,
            };
        var s = panel.style;
        s.position = .absolute;
        s.inset.top = .{ .px = origin.y };
        s.inset.left = .{ .px = origin.x };
        panel.style = s;

        const root = div_mod.div(arena).absolute().wFull().hFull();
        return root.childDiv(panel).any();
    }
};

const HoverHost = struct {
    app: *App,
    state: app_mod.Entity(TooltipState),
    show_delay_frames: u32,
    timeline: ?*animation_mod.Timeline = null,
    fade_duration_ms: f32 = animation_mod.default_fade_ms,
    tooltip_id: []const u8 = "",

    fn onHover(ctx: ?*anyopaque, hovered: bool) void {
        const self: *HoverHost = @ptrCast(@alignCast(ctx.?));
        const s = self.app.read(TooltipState, self.state);
        s.trigger_hovered = hovered;
        if (hovered) {
            if (self.show_delay_frames == 0) {
                s.show();
            }
        } else {
            hide(self.app, self.state, .{
                .timeline = self.timeline,
                .id = self.tooltip_id,
                .fade_duration_ms = self.fade_duration_ms,
            });
            return;
        }
        self.app.notify(self.state.id);
    }
};

fn triggerBounds(frame: *const element.FrameState, trigger_id: []const u8) ?Bounds(Pixels) {
    const id = element.elementId(trigger_id);
    for (frame.hitboxes.items) |hitbox| {
        if (hitbox.id != null and hitbox.id.? == id) return hitbox.bounds;
    }
    return null;
}

fn tickShowDelay(props: Props) void {
    const s = props.app.read(TooltipState, props.state);
    if (!s.trigger_hovered or s.visible or props.show_delay_frames == 0) return;
    s.hover_frames += 1;
    if (s.hover_frames > props.show_delay_frames) {
        s.show();
        props.app.notify(props.state.id);
    }
}

fn registerOverlay(arena: std.mem.Allocator, props: Props) !void {
    const visible = props.app.read(TooltipState, props.state).visible;
    if (!visible) return;

    const host = arena.create(Host) catch @panic("frame arena OOM");
    host.* = .{
        .app = props.app,
        .state = props.state,
        .frame = props.frame,
        .viewport = props.viewport,
        .trigger_id = props.trigger_id,
        .panel_style = props.panel_style,
        .a11y_label = props.a11y_label,
        .content_ctx = props.content_ctx,
        .content_fn = props.content_fn,
        .tooltip_id = props.id,
        .timeline = props.timeline,
        .fade_duration_ms = props.fade_duration_ms,
        .placement = props.placement,
        .alignment = props.alignment,
        .offset = props.offset,
        .margin = props.margin,
        .panel_size = props.panel_size,
    };
    try props.overlays.push(.{
        .id = overlay_mod.overlayId(props.id),
        .z_index = props.z_index,
        .trap_focus = false,
        .modal = false,
        .ctx = host,
        .render = Host.render,
        .on_dismiss = Host.dismiss,
    });
}

/// Attach hover handlers and register the tooltip overlay when visible.
/// Returns the same `trigger` div (with `onHover` wired).
pub fn tooltipWithTrigger(
    arena: std.mem.Allocator,
    props: Props,
    trigger: *Div,
) !*Div {
    tickShowDelay(props);

    const hover_host = arena.create(HoverHost) catch @panic("frame arena OOM");
    hover_host.* = .{
        .app = props.app,
        .state = props.state,
        .show_delay_frames = props.show_delay_frames,
        .timeline = props.timeline,
        .fade_duration_ms = props.fade_duration_ms,
        .tooltip_id = props.id,
    };
    _ = trigger.onHover(hover_host, HoverHost.onHover);

    try registerOverlay(arena, props);
    return trigger;
}

pub fn hide(app: *App, state: app_mod.Entity(TooltipState), options: HideOptions) void {
    const s = app.read(TooltipState, state);
    if (!s.visible) return;
    if (options.timeline) |tl| {
        if (options.id.len == 0) {
            s.finishHide();
            app.notify(state.id);
            return;
        }
        if (s.closing) return;
        s.requestHide();
        var buf: [64]u8 = undefined;
        const fade_name = std.fmt.bufPrint(&buf, "tooltip-fade-{s}", .{options.id}) catch options.id;
        animation_mod.fadeOut(tl, animation_mod.animationId(fade_name), options.fade_duration_ms);
    } else {
        s.finishHide();
    }
    app.notify(state.id);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const platform = @import("../platform.zig");

const TooltipFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(TooltipState) = undefined,

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *TooltipFixture = @ptrCast(@alignCast(ctx.?));

        var trigger = div_mod.div(arena)
            .withId("tooltip-trigger")
            .sizePx(80, 30)
            .bg(Rgba.fromHex(0x336699));
        trigger = try tooltipWithTrigger(arena, .{
            .id = "help-tooltip",
            .trigger_id = "tooltip-trigger",
            .state = self.state,
            .overlays = &harness.overlays,
            .app = &harness.app,
            .frame = &harness.frame,
            .viewport = harness.viewport,
            .a11y_label = "Helpful information",
        }, trigger);

        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(trigger).any();
    }
};

test "tooltip near viewport edge stays fully inside" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    const EdgeFixture = struct {
        harness: *testing_mod.Harness = undefined,
        state: app_mod.Entity(TooltipState) = undefined,

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, h: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));

            var trigger = div_mod.div(arena)
                .withId("tooltip-trigger")
                .absolute()
                .sizePx(80, 30)
                .bg(Rgba.fromHex(0x336699));
            var ts = trigger.style;
            ts.inset.top = .{ .px = 250 };
            ts.inset.left = .{ .px = 300 };
            trigger.style = ts;
            trigger = try tooltipWithTrigger(arena, .{
                .id = "help-tooltip",
                .trigger_id = "tooltip-trigger",
                .state = self.state,
                .overlays = &h.overlays,
                .app = &h.app,
                .frame = &h.frame,
                .viewport = h.viewport,
            }, trigger);

            return div_mod.div(arena).sizePx(400, 300).childDiv(trigger).any();
        }
    };

    var fixture = EdgeFixture{ .harness = &harness };
    fixture.state = try harness.app.new(TooltipState, .{});
    try harness.setRoot(&fixture, EdgeFixture.render);

    try harness.hoverOver("tooltip-trigger");
    const panel = harness.hitboxBounds(element.elementId("help-tooltip")).?;
    try std.testing.expect(panel.origin.x >= 8 - 0.01);
    try std.testing.expect(panel.origin.y >= 8 - 0.01);
    try std.testing.expect(panel.right() <= 400 - 8 + 0.01);
    try std.testing.expect(panel.bottom() <= 300 - 8 + 0.01);
}

test "tooltip shows on hover and hides on mouse leave" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = TooltipFixture{ .harness = &harness };
    fixture.state = try harness.app.new(TooltipState, .{});
    try harness.setRoot(&fixture, TooltipFixture.render);

    try std.testing.expect(!harness.app.read(TooltipState, fixture.state).visible);
    try std.testing.expectEqual(@as(usize, 0), harness.overlays.layers.items.len);

    try harness.hoverOver("tooltip-trigger");
    try std.testing.expect(harness.app.read(TooltipState, fixture.state).visible);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);
    try std.testing.expect(harness.hitboxBounds(element.elementId("help-tooltip")) != null);
    try std.testing.expectEqual(@import("../a11y.zig").Role.tooltip, harness.a11yRole("help-tooltip").?);
    try std.testing.expectEqualStrings("Helpful information", harness.a11yName("help-tooltip").?);

    try harness.moveMouse(5, 5);
    try std.testing.expect(!harness.app.read(TooltipState, fixture.state).visible);
    try std.testing.expectEqual(@as(usize, 0), harness.overlays.layers.items.len);
}

test "tooltip hides on Escape" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = TooltipFixture{ .harness = &harness };
    fixture.state = try harness.app.new(TooltipState, .{});
    try harness.setRoot(&fixture, TooltipFixture.render);

    try harness.hoverOver("tooltip-trigger");
    try std.testing.expect(harness.app.read(TooltipState, fixture.state).visible);

    try harness.keyDown(.escape);
    try std.testing.expect(!harness.app.read(TooltipState, fixture.state).visible);
}

const DelayFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(TooltipState) = undefined,

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *DelayFixture = @ptrCast(@alignCast(ctx.?));

        var trigger = div_mod.div(arena)
            .withId("delay-trigger")
            .sizePx(80, 30)
            .bg(Rgba.fromHex(0x336699));
        trigger = try tooltipWithTrigger(arena, .{
            .id = "delay-tooltip",
            .trigger_id = "delay-trigger",
            .state = self.state,
            .overlays = &harness.overlays,
            .app = &harness.app,
            .frame = &harness.frame,
            .viewport = harness.viewport,
            .show_delay_frames = 2,
        }, trigger);

        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(trigger).any();
    }
};

test "tooltip respects show_delay_frames" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = DelayFixture{ .harness = &harness };
    fixture.state = try harness.app.new(TooltipState, .{});
    try harness.setRoot(&fixture, DelayFixture.render);

    try harness.hoverOver("delay-trigger");
    try std.testing.expect(!harness.app.read(TooltipState, fixture.state).visible);

    try harness.renderFrame();
    try std.testing.expect(!harness.app.read(TooltipState, fixture.state).visible);

    try harness.renderFrame();
    try std.testing.expect(harness.app.read(TooltipState, fixture.state).visible);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);
}

test "tooltip fade-out keeps overlay until animation completes" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var timeline = animation_mod.Timeline.init();
    var fade_buf: [64]u8 = undefined;
    const fade_name = try std.fmt.bufPrint(&fade_buf, "tooltip-fade-{s}", .{"help-tooltip"});
    const fade_id = animation_mod.animationId(fade_name);

    const FadeOutFixture = struct {
        harness: *testing_mod.Harness = undefined,
        state: app_mod.Entity(TooltipState) = undefined,
        timeline: *animation_mod.Timeline = undefined,

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, h: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));

            var trigger = div_mod.div(arena)
                .withId("tooltip-trigger")
                .sizePx(80, 30)
                .bg(Rgba.fromHex(0x336699));
            trigger = try tooltipWithTrigger(arena, .{
                .id = "help-tooltip",
                .trigger_id = "tooltip-trigger",
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
    fixture.state = try harness.app.new(TooltipState, .{});
    try harness.setRoot(&fixture, FadeOutFixture.render);

    try harness.hoverOver("tooltip-trigger");
    try harness.renderFrame();
    _ = timeline.tick(150);
    try harness.renderFrame();
    try std.testing.expectApproxEqAbs(@as(f32, 1), animation_mod.opacityOf(&timeline, fade_id, 1), 0.05);

    try harness.moveMouse(5, 5);
    const tooltip_state = harness.app.read(TooltipState, fixture.state);
    try std.testing.expect(tooltip_state.visible);
    try std.testing.expect(tooltip_state.closing);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);

    _ = timeline.tick(75);
    try harness.renderFrame();
    const mid_opacity = animation_mod.opacityOf(&timeline, fade_id, 1);
    try std.testing.expect(mid_opacity < 0.99);
    try std.testing.expect(mid_opacity > 0.01);
    try std.testing.expect(harness.app.read(TooltipState, fixture.state).visible);

    _ = timeline.tick(75);
    try harness.renderFrame();
    try std.testing.expect(!harness.app.read(TooltipState, fixture.state).visible);
    try std.testing.expect(!harness.app.read(TooltipState, fixture.state).closing);

    try harness.renderFrame();
    try std.testing.expectEqual(@as(usize, 0), harness.overlays.layers.items.len);
}
