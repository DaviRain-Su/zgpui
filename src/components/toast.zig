//! Headless toast: non-modal overlay stack with queued messages, manual
//! dismiss, and frame-counted auto-dismiss for tests.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const app_mod = @import("../app.zig");
const overlay_mod = @import("../overlay.zig");
const color = @import("../color.zig");
const geometry = @import("../geometry.zig");
const animation_mod = @import("../animation.zig");
const a11y_mod = @import("../a11y.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Rgba = color.Rgba;
const Pixels = geometry.Pixels;

pub const max_toasts = 8;
pub const message_cap = 128;

pub const ToastId = u64;

pub const ToastEntry = struct {
    id: ToastId = 0,
    message_len: u16 = 0,
    message: [message_cap]u8 = [_]u8{0} ** message_cap,
    /// Frames the toast stays visible (`0` = no auto-dismiss).
    ttl_frames: u32 = 0,
    age_frames: u32 = 0,
    live_priority: a11y_mod.LivePriority = .polite,
};

pub const ToastHostState = struct {
    toasts: [max_toasts]ToastEntry = [_]ToastEntry{.{}} ** max_toasts,
    len: u8 = 0,
    next_id: ToastId = 1,
};

pub const ToastPayload = struct {
    id: ToastId = 0,
    message: []const u8,
    ttl_frames: u32 = 0,
    live_priority: a11y_mod.LivePriority = .polite,
};

pub const StyleState = struct {
    id: ToastId,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    host: app_mod.Entity(ToastHostState),
    overlays: *overlay_mod.OverlayStack,
    app: *App,
    z_index: i32 = 70,
    toast_style: ?StyleFn = null,
    timeline: ?*animation_mod.Timeline = null,
    fade_duration_ms: f32 = animation_mod.default_fade_ms,
    /// Frames before TTL expiry to start fade-out (0 = disabled).
    fade_out_frames: u32 = 8,
};

const Host = struct {
    app: *App,
    host: app_mod.Entity(ToastHostState),
    toast_style: ?StyleFn,
    overlay_id: []const u8,
    timeline: ?*animation_mod.Timeline = null,
    fade_duration_ms: f32 = animation_mod.default_fade_ms,
    fade_out_frames: u32 = 8,

    fn toastFadeId(toast_id: ToastId, buf: *[32]u8) animation_mod.AnimationId {
        const name = std.fmt.bufPrint(buf, "toast-fade-{d}", .{toast_id}) catch "toast-fade";
        return animation_mod.animationId(name);
    }

    fn toastOpacity(self: *const Host, toast: *const ToastEntry) f32 {
        const tl = self.timeline orelse return 1;
        var buf: [32]u8 = undefined;
        const fade_id = toastFadeId(toast.id, &buf);

        animation_mod.fadeIn(tl, fade_id, self.fade_duration_ms);

        if (toast.ttl_frames > 0 and self.fade_out_frames > 0 and
            toast.age_frames + self.fade_out_frames >= toast.ttl_frames)
        {
            animation_mod.fadeOut(tl, fade_id, self.fade_duration_ms);
        }

        return animation_mod.opacityOf(tl, fade_id, 1);
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!element.Element {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        const state = self.app.read(ToastHostState, self.host);
        if (state.len == 0) return div_mod.div(arena).sizePx(0, 0).any();

        var stack = div_mod.div(arena)
            .withId(self.overlay_id)
            .absolute()
            .wFull()
            .hFull()
            .flexCol()
            .gapPx(8)
            .padPx(16);
        {
            var s = stack.style;
            s.align_items = .flex_end;
            s.justify_content = .flex_end;
            stack.style = s;
        }

        var i: usize = 0;
        while (i < state.len) : (i += 1) {
            const toast = &state.toasts[i];
            const msg = toast.message[0..toast.message_len];

            var id_buf: [32]u8 = undefined;
            const toast_id_name = try std.fmt.bufPrint(&id_buf, "toast-{d}", .{toast.id});
            const opacity = self.toastOpacity(toast);

            var toast_div = div_mod.div(arena)
                .withId(toast_id_name)
                .interactive()
                .sizePx(240, 40)
                .rounded(6)
                .role(.tooltip)
                .a11yName(msg)
                .a11yLive(toast.live_priority);
            if (self.toast_style) |style_fn| {
                var s = style_fn(.{ .id = toast.id });
                if (s.background) |bg| s.background = animation_mod.scaleAlpha(bg, opacity);
                toast_div = toast_div.withStyle(s);
            } else {
                toast_div = toast_div.bg(animation_mod.scaleAlpha(Rgba.fromHex(0x1e1e2e), opacity));
            }

            stack = stack.childDiv(toast_div);
        }

        return stack.any();
    }
};

fn removeAt(state: *ToastHostState, index: usize) void {
    var j = index;
    while (j + 1 < state.len) : (j += 1) {
        state.toasts[j] = state.toasts[j + 1];
    }
    state.len -= 1;
}

fn tickTtl(app: *App, entity: app_mod.Entity(ToastHostState)) void {
    var changed = false;
    const state = app.read(ToastHostState, entity);
    var i: usize = 0;
    while (i < state.len) {
        const entry = &state.toasts[i];
        if (entry.ttl_frames == 0) {
            i += 1;
            continue;
        }
        entry.age_frames += 1;
        if (entry.age_frames >= entry.ttl_frames) {
            removeAt(state, i);
            changed = true;
        } else {
            i += 1;
        }
    }
    if (changed) app.notify(entity.id);
}

pub fn push(app: *App, entity: app_mod.Entity(ToastHostState), payload: ToastPayload) !ToastId {
    const state = app.read(ToastHostState, entity);
    const id = if (payload.id != 0) payload.id else blk: {
        const next = state.next_id;
        state.next_id += 1;
        break :blk next;
    };

    const copy_len = @min(payload.message.len, message_cap);
    if (state.len >= max_toasts) {
        removeAt(state, 0);
    }

    const slot = &state.toasts[state.len];
    slot.* = .{
        .id = id,
        .message_len = @intCast(copy_len),
        .ttl_frames = payload.ttl_frames,
        .age_frames = 0,
        .live_priority = payload.live_priority,
    };
    @memcpy(slot.message[0..copy_len], payload.message[0..copy_len]);
    state.len += 1;

    app.notify(entity.id);
    return id;
}

pub fn dismiss(app: *App, entity: app_mod.Entity(ToastHostState), id: ToastId) void {
    const state = app.read(ToastHostState, entity);
    var i: usize = 0;
    while (i < state.len) : (i += 1) {
        if (state.toasts[i].id == id) {
            removeAt(state, i);
            app.notify(entity.id);
            return;
        }
    }
}

pub fn count(app: *App, entity: app_mod.Entity(ToastHostState)) u8 {
    return app.read(ToastHostState, entity).len;
}

/// Zero-size main-tree placeholder; registers a single non-modal overlay
/// stacking toast panels when the host queue is non-empty.
pub fn toastHost(arena: std.mem.Allocator, props: Props) !*Div {
    tickTtl(props.app, props.host);

    const state = props.app.read(ToastHostState, props.host);
    if (state.len == 0) return div_mod.div(arena).sizePx(0, 0);

    const host = arena.create(Host) catch @panic("frame arena OOM");
    host.* = .{
        .app = props.app,
        .host = props.host,
        .toast_style = props.toast_style,
        .overlay_id = props.id,
        .timeline = props.timeline,
        .fade_duration_ms = props.fade_duration_ms,
        .fade_out_frames = props.fade_out_frames,
    };
    try props.overlays.push(.{
        .id = overlay_mod.overlayId(props.id),
        .z_index = props.z_index,
        .trap_focus = false,
        .modal = false,
        .ctx = host,
        .render = Host.render,
    });
    return div_mod.div(arena).sizePx(0, 0);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

const ToastFixture = struct {
    harness: *testing_mod.Harness = undefined,
    host: app_mod.Entity(ToastHostState) = undefined,

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *ToastFixture = @ptrCast(@alignCast(ctx.?));

        _ = try toastHost(arena, .{
            .id = "toast-host",
            .host = self.host,
            .overlays = &harness.overlays,
            .app = &harness.app,
        });

        const push_btn = div_mod.div(arena)
            .withId("push-toast")
            .sizePx(100, 30)
            .bg(Rgba.fromHex(0x336699))
            .onClick(self, pushClick);

        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(push_btn).any();
    }

    fn pushClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *ToastFixture = @ptrCast(@alignCast(ctx.?));
        _ = push(&self.harness.app, self.host, .{
            .id = 42,
            .message = "Saved",
            .ttl_frames = 0,
        }) catch {};
    }
};

const platform = @import("../platform.zig");

test "toast push shows in overlay" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = ToastFixture{ .harness = &harness };
    fixture.host = try harness.app.new(ToastHostState, .{});
    try harness.setRoot(&fixture, ToastFixture.render);

    try std.testing.expectEqual(@as(u8, 0), count(&harness.app, fixture.host));
    try std.testing.expectEqual(@as(usize, 0), harness.overlays.layers.items.len);

    try harness.clickOn("push-toast");
    try std.testing.expectEqual(@as(u8, 1), count(&harness.app, fixture.host));
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);

    var buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "toast-{d}", .{@as(ToastId, 42)});
    try std.testing.expect(harness.hitboxBounds(element.elementId(name)) != null);
    const node = harness.a11yNode(name).?;
    try std.testing.expectEqual(a11y_mod.Role.tooltip, node.role);
    try std.testing.expectEqual(a11y_mod.LivePriority.polite, node.live.?);
    try std.testing.expectEqualStrings("Saved", harness.a11yName(name).?);
}

test "toast dismiss removes entry" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = ToastFixture{ .harness = &harness };
    fixture.host = try harness.app.new(ToastHostState, .{});
    try harness.setRoot(&fixture, ToastFixture.render);

    _ = try push(&harness.app, fixture.host, .{
        .id = 7,
        .message = "Hello",
        .ttl_frames = 0,
        .live_priority = .assertive,
    });
    try harness.renderFrame();

    var buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "toast-{d}", .{@as(ToastId, 7)});
    try std.testing.expect(harness.hitboxBounds(element.elementId(name)) != null);
    try std.testing.expectEqual(a11y_mod.LivePriority.assertive, harness.a11yNode(name).?.live.?);

    dismiss(&harness.app, fixture.host, 7);
    try harness.renderFrame();

    try std.testing.expectEqual(@as(u8, 0), count(&harness.app, fixture.host));
    try std.testing.expectEqual(@as(usize, 0), harness.overlays.layers.items.len);
    try std.testing.expect(harness.hitboxBounds(element.elementId(name)) == null);
}

test "toast ttl expires after N renderFrames" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    const host = try harness.app.new(ToastHostState, .{});
    const ToastOnly = struct {
        host_entity: app_mod.Entity(ToastHostState),

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, h: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = try toastHost(arena, .{
                .id = "toast-host",
                .host = self.host_entity,
                .overlays = &h.overlays,
                .app = &h.app,
            });
            return div_mod.div(arena).sizePx(400, 300).any();
        }
    };

    var fixture = ToastOnly{ .host_entity = host };
    try harness.setRoot(&fixture, ToastOnly.render);

    const ttl: u32 = 2;
    _ = try push(&harness.app, host, .{
        .id = 99,
        .message = "Temporary",
        .ttl_frames = ttl,
    });
    try harness.renderFrame();

    var buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "toast-{d}", .{@as(ToastId, 99)});
    try std.testing.expect(harness.hitboxBounds(element.elementId(name)) != null);

    var extra: u32 = 0;
    while (count(&harness.app, host) > 0 and extra < ttl + 2) : (extra += 1) {
        try harness.renderFrame();
    }
    try std.testing.expectEqual(@as(u8, 0), count(&harness.app, host));
    try std.testing.expect(harness.hitboxBounds(element.elementId(name)) == null);
}
