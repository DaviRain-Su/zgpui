//! Headless hover card: non-modal overlay shown after trigger hover delay,
//! stays open while the pointer is over the trigger or card, dismissed on
//! leave (optional delay) or Escape. Supports interactive card content.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const app_mod = @import("../app.zig");
const overlay_mod = @import("../overlay.zig");
const color = @import("../color.zig");
const geometry = @import("../geometry.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Rgba = color.Rgba;
const Pixels = geometry.Pixels;
const Bounds = geometry.Bounds;
const Size = geometry.Size;
const Point = geometry.Point;

pub const HoverCardState = struct {
    visible: bool = false,
    trigger_hovered: bool = false,
    card_hovered: bool = false,
    hover_frames: u32 = 0,
    /// Approximate card bounds from the last overlay render (for pointer sync).
    card_bounds: ?Bounds(Pixels) = null,
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
    state: app_mod.Entity(HoverCardState),
    overlays: *overlay_mod.OverlayStack,
    app: *App,
    /// Main-tree frame (hitboxes available when the overlay renders).
    frame: *const element.FrameState,
    /// Optional input state for card hover hit-testing between frames.
    input: ?*const element.InputState = null,
    viewport: Size(Pixels),
    z_index: i32 = 55,
    /// Frames to wait after hover before showing (0 = immediate).
    show_delay_frames: u32 = 0,
    /// Frames to wait after both trigger and card are unhovered before hiding (0 = immediate).
    hide_delay_frames: u32 = 0,
    panel_style: ?StyleFn = null,
    content_ctx: ?*anyopaque = null,
    content_fn: ?ContentFn = null,
};

const Host = struct {
    app: *App,
    state: app_mod.Entity(HoverCardState),
    frame: *const element.FrameState,
    viewport: Size(Pixels),
    trigger_id: []const u8,
    panel_style: ?StyleFn,
    content_ctx: ?*anyopaque,
    content_fn: ?ContentFn,
    card_id: []const u8,

    fn dismiss(ctx: ?*anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        hide(self.app, self.state);
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!element.Element {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        const visible = self.app.read(HoverCardState, self.state).visible;
        if (!visible) {
            return div_mod.div(arena).sizePx(0, 0).any();
        }

        const anchor = triggerBounds(self.frame, self.trigger_id);

        var panel = div_mod.div(arena)
            .withId(self.card_id)
            .absolute()
            .interactive();
        if (self.panel_style) |style_fn| {
            panel = panel.withStyle(style_fn(.{ .visible = true }));
        } else {
            var s = style_mod.Style{};
            s.width = .{ .px = 200 };
            s.min_height = .{ .px = 60 };
            s.background = Rgba.fromHex(0x1e1e2e);
            s.corner_radii = geometry.Corners(Pixels).all(6);
            s.padding = .{
                .top = .{ .px = 10 },
                .right = .{ .px = 12 },
                .bottom = .{ .px = 10 },
                .left = .{ .px = 12 },
            };
            panel = panel.withStyle(s);
        }

        if (self.content_fn) |content_fn| {
            const body = try content_fn(self.content_ctx, arena);
            panel = panel.childDiv(body);
        }

        const card_host = arena.create(CardHoverHost) catch @panic("frame arena OOM");
        card_host.* = .{
            .app = self.app,
            .state = self.state,
        };
        _ = panel.onHover(card_host, CardHoverHost.onHover);

        if (anchor) |bounds| {
            var s = panel.style;
            s.position = .absolute;
            s.inset.top = .{ .px = bounds.origin.y + bounds.size.height + 4 };
            s.inset.left = .{ .px = bounds.origin.x };
            panel.style = s;
            storeCardBounds(self.app, self.state, panel, bounds);
        } else {
            var s = panel.style;
            s.position = .absolute;
            s.inset.top = .{ .px = self.viewport.height / 2 - 30 };
            s.inset.left = .{ .px = self.viewport.width / 2 - 100 };
            panel.style = s;
            const s_state = self.app.read(HoverCardState, self.state);
            s_state.card_bounds = null;
        }

        const root = div_mod.div(arena).absolute().wFull().hFull();
        return root.childDiv(panel).any();
    }
};

const TriggerHoverHost = struct {
    app: *App,
    state: app_mod.Entity(HoverCardState),
    show_delay_frames: u32,

    fn onHover(ctx: ?*anyopaque, hovered: bool) void {
        const self: *TriggerHoverHost = @ptrCast(@alignCast(ctx.?));
        const s = self.app.read(HoverCardState, self.state);
        s.trigger_hovered = hovered;
        if (hovered) {
            s.hover_frames = 0;
            if (self.show_delay_frames == 0) {
                s.visible = true;
            }
        } else if (!s.visible) {
            s.hover_frames = 0;
        }
        self.app.notify(self.state.id);
    }
};

const CardHoverHost = struct {
    app: *App,
    state: app_mod.Entity(HoverCardState),

    fn onHover(ctx: ?*anyopaque, hovered: bool) void {
        const self: *CardHoverHost = @ptrCast(@alignCast(ctx.?));
        const s = self.app.read(HoverCardState, self.state);
        if (s.card_hovered == hovered) return;
        s.card_hovered = hovered;
        if (hovered) s.hover_frames = 0;
        self.app.notify(self.state.id);
    }
};

fn lengthPx(len: style_mod.Length, fallback: Pixels) Pixels {
    return switch (len) {
        .px => |v| v,
        else => fallback,
    };
}

fn storeCardBounds(app: *App, state: app_mod.Entity(HoverCardState), panel: *const Div, anchor: Bounds(Pixels)) void {
    const s = app.read(HoverCardState, state);
    const width = lengthPx(panel.style.width, 200);
    const height = lengthPx(panel.style.min_height, 60);
    s.card_bounds = .{
        .origin = .{
            .x = anchor.origin.x,
            .y = anchor.origin.y + anchor.size.height + 4,
        },
        .size = .{ .width = width, .height = height },
    };
}

fn triggerBounds(frame: *const element.FrameState, trigger_id: []const u8) ?Bounds(Pixels) {
    const id = element.elementId(trigger_id);
    for (frame.hitboxes.items) |hitbox| {
        if (hitbox.id != null and hitbox.id.? == id) return hitbox.bounds;
    }
    return null;
}

fn pointerOverCard(props: Props) bool {
    const input = props.input orelse return false;
    const s = props.app.read(HoverCardState, props.state);
    if (s.card_bounds) |bounds| {
        if (bounds.contains(input.mouse_position)) return true;
    }
    return cardHitTest(props.overlays, props.id, input.mouse_position);
}

fn cardHitTest(overlays: *const overlay_mod.OverlayStack, card_id: []const u8, point: Point(Pixels)) bool {
    const id = element.elementId(card_id);
    var i = overlays.layers.items.len;
    while (i > 0) {
        i -= 1;
        for (overlays.layers.items[i].frame.hitboxes.items) |hitbox| {
            if (hitbox.id != null and hitbox.id.? == id) {
                return hitbox.bounds.contains(point);
            }
        }
    }
    return false;
}

fn syncCardHover(props: Props) void {
    const s = props.app.read(HoverCardState, props.state);
    if (!s.visible) {
        if (s.card_hovered) {
            s.card_hovered = false;
            props.app.notify(props.state.id);
        }
        return;
    }
    const hovered = pointerOverCard(props);
    if (s.card_hovered != hovered) {
        s.card_hovered = hovered;
        if (hovered) s.hover_frames = 0;
        props.app.notify(props.state.id);
    }
}

fn tickShowDelay(props: Props) void {
    const s = props.app.read(HoverCardState, props.state);
    if (!s.trigger_hovered or s.visible or props.show_delay_frames == 0) return;
    s.hover_frames += 1;
    if (s.hover_frames > props.show_delay_frames) {
        s.visible = true;
        s.hover_frames = 0;
        props.app.notify(props.state.id);
    }
}

fn tickHideDelay(props: Props) void {
    const s = props.app.read(HoverCardState, props.state);
    if (!s.visible) return;

    if (s.trigger_hovered or s.card_hovered) {
        s.hover_frames = 0;
        return;
    }

    if (props.hide_delay_frames == 0) {
        s.visible = false;
        s.hover_frames = 0;
        s.card_bounds = null;
        props.app.notify(props.state.id);
        return;
    }

    s.hover_frames += 1;
    if (s.hover_frames > props.hide_delay_frames) {
        s.visible = false;
        s.hover_frames = 0;
        s.card_bounds = null;
        props.app.notify(props.state.id);
    }
}

fn registerOverlay(arena: std.mem.Allocator, props: Props) !void {
    const visible = props.app.read(HoverCardState, props.state).visible;
    if (!visible) return;

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
        .card_id = props.id,
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

/// Attach hover handlers and register the hover-card overlay when visible.
/// Returns the same `trigger` div (with `onHover` wired).
pub fn hoverCardWithTrigger(
    arena: std.mem.Allocator,
    props: Props,
    trigger: *Div,
) !*Div {
    syncCardHover(props);
    tickShowDelay(props);
    tickHideDelay(props);

    const hover_host = arena.create(TriggerHoverHost) catch @panic("frame arena OOM");
    hover_host.* = .{
        .app = props.app,
        .state = props.state,
        .show_delay_frames = props.show_delay_frames,
    };
    _ = trigger.onHover(hover_host, TriggerHoverHost.onHover);

    try registerOverlay(arena, props);
    return trigger;
}

pub fn hide(app: *App, state: app_mod.Entity(HoverCardState)) void {
    const s = app.read(HoverCardState, state);
    s.visible = false;
    s.trigger_hovered = false;
    s.card_hovered = false;
    s.hover_frames = 0;
    s.card_bounds = null;
    app.notify(state.id);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

const HoverCardFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(HoverCardState) = undefined,

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *HoverCardFixture = @ptrCast(@alignCast(ctx.?));

        var trigger = div_mod.div(arena)
            .withId("hover-card-trigger")
            .sizePx(80, 30)
            .bg(Rgba.fromHex(0x336699));
        trigger = try hoverCardWithTrigger(arena, .{
            .id = "profile-hover-card",
            .trigger_id = "hover-card-trigger",
            .state = self.state,
            .overlays = &harness.overlays,
            .app = &harness.app,
            .frame = &harness.frame,
            .input = &harness.input,
            .viewport = harness.viewport,
            .show_delay_frames = 2,
        }, trigger);

        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(trigger).any();
    }
};

test "hover card shows after delay on trigger hover" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = HoverCardFixture{ .harness = &harness };
    fixture.state = try harness.app.new(HoverCardState, .{});
    try harness.setRoot(&fixture, HoverCardFixture.render);

    try std.testing.expect(!harness.app.read(HoverCardState, fixture.state).visible);
    try std.testing.expectEqual(@as(usize, 0), harness.overlays.layers.items.len);

    try harness.hoverOver("hover-card-trigger");
    try std.testing.expect(!harness.app.read(HoverCardState, fixture.state).visible);

    try harness.renderFrame();
    try std.testing.expect(!harness.app.read(HoverCardState, fixture.state).visible);

    try harness.renderFrame();
    try std.testing.expect(harness.app.read(HoverCardState, fixture.state).visible);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);
    try std.testing.expect(harness.hitboxBounds(element.elementId("profile-hover-card")) != null);
}

test "hover card hides when pointer leaves trigger and card" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = HoverCardFixture{ .harness = &harness };
    fixture.state = try harness.app.new(HoverCardState, .{});
    try harness.setRoot(&fixture, HoverCardFixture.render);

    try harness.hoverOver("hover-card-trigger");
    try harness.renderFrame();
    try harness.renderFrame();
    try std.testing.expect(harness.app.read(HoverCardState, fixture.state).visible);

    try harness.moveMouse(5, 5);
    try std.testing.expect(!harness.app.read(HoverCardState, fixture.state).visible);
    try std.testing.expectEqual(@as(usize, 0), harness.overlays.layers.items.len);
}

test "hover card hides on Escape" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = HoverCardFixture{ .harness = &harness };
    fixture.state = try harness.app.new(HoverCardState, .{});
    try harness.setRoot(&fixture, HoverCardFixture.render);

    try harness.hoverOver("hover-card-trigger");
    try harness.renderFrame();
    try harness.renderFrame();
    try std.testing.expect(harness.app.read(HoverCardState, fixture.state).visible);

    try harness.keyDown(.escape);
    try std.testing.expect(!harness.app.read(HoverCardState, fixture.state).visible);
}

const CardStayOpenFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(HoverCardState) = undefined,

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *CardStayOpenFixture = @ptrCast(@alignCast(ctx.?));

        var trigger = div_mod.div(arena)
            .withId("stay-trigger")
            .sizePx(80, 30)
            .bg(Rgba.fromHex(0x336699));
        trigger = try hoverCardWithTrigger(arena, .{
            .id = "stay-hover-card",
            .trigger_id = "stay-trigger",
            .state = self.state,
            .overlays = &harness.overlays,
            .app = &harness.app,
            .frame = &harness.frame,
            .input = &harness.input,
            .viewport = harness.viewport,
            .show_delay_frames = 0,
        }, trigger);

        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(trigger).any();
    }
};

test "hover card stays open when pointer moves onto card" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = CardStayOpenFixture{ .harness = &harness };
    fixture.state = try harness.app.new(HoverCardState, .{});
    try harness.setRoot(&fixture, CardStayOpenFixture.render);

    try harness.hoverOver("stay-trigger");
    try std.testing.expect(harness.app.read(HoverCardState, fixture.state).visible);

    const center = harness.centerOf(element.elementId("stay-hover-card")) orelse return error.ElementNotFound;
    try harness.moveMouse(center.x, center.y);
    try std.testing.expect(harness.app.read(HoverCardState, fixture.state).visible);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);
}
