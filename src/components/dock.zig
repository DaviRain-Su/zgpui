//! Headless dock strip: fixed left / right / bottom panel with open state and
//! size (gpui-component Dock placement contract, without panel registry).

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Pixels = geometry.Pixels;
const Size = geometry.Size;
const Rgba = color.Rgba;

pub const Placement = enum { left, right, bottom };

pub const default_size: Pixels = 200;
pub const min_size: Pixels = 80;

pub const State = struct {
    placement: Placement = .left,
    size: Pixels = default_size,
    open: bool = true,
    collapsible: bool = true,

    pub fn setOpen(self: *State, open: bool) void {
        if (!self.collapsible and !open) return;
        self.open = open;
    }

    pub fn toggle(self: *State) void {
        if (!self.collapsible) return;
        self.open = !self.open;
    }

    pub fn setSize(self: *State, next: Pixels) void {
        self.size = @max(min_size, next);
    }
};

/// Resolved dock thickness along its primary axis (0 when closed).
pub fn resolvedSize(state: *const State) Pixels {
    if (!state.open) return 0;
    return @max(min_size, state.size);
}

pub const AreaInsets = struct {
    left: Pixels = 0,
    right: Pixels = 0,
    bottom: Pixels = 0,

    pub fn centerSize(self: AreaInsets, viewport: Size(Pixels)) Size(Pixels) {
        return .{
            .width = @max(0, viewport.width - self.left - self.right),
            .height = @max(0, viewport.height - self.bottom),
        };
    }
};

/// Combine left/right/bottom dock states into center content insets.
pub fn areaInsets(left: ?*const State, right: ?*const State, bottom: ?*const State) AreaInsets {
    var insets: AreaInsets = .{};
    if (left) |d| {
        if (d.placement == .left) insets.left = resolvedSize(d);
    }
    if (right) |d| {
        if (d.placement == .right) insets.right = resolvedSize(d);
    }
    if (bottom) |d| {
        if (d.placement == .bottom) insets.bottom = resolvedSize(d);
    }
    return insets;
}

pub const StyleState = struct {
    placement: Placement = .left,
    open: bool = true,
    size: Pixels = default_size,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    state: app_mod.Entity(State),
    app: *App,
    style_fn: ?StyleFn = null,
    content_id: ?[]const u8 = null,
};

pub const Parts = struct {
    root: *Div,
    content: ?*Div,
};

pub fn dock(arena: std.mem.Allocator, props: Props) Parts {
    const st = props.app.read(State, props.state);
    const thickness = resolvedSize(st);
    const style_state = StyleState{
        .placement = st.placement,
        .open = st.open,
        .size = thickness,
    };

    if (thickness <= 0) {
        return .{
            .root = div_mod.div(arena).withId(props.id).sizePx(0, 0).interactive(),
            .content = null,
        };
    }

    var root = div_mod.div(arena).withId(props.id).interactive();
    switch (st.placement) {
        .left, .right => root = root.wPx(thickness).hFull().flexCol(),
        .bottom => root = root.hPx(thickness).wFull().flexRow(),
    }

    if (props.style_fn) |style_fn| {
        var s = style_fn(style_state);
        switch (st.placement) {
            .left, .right => {
                s.width = .{ .px = thickness };
                s.height = .{ .percent = 100 };
            },
            .bottom => {
                s.height = .{ .px = thickness };
                s.width = .{ .percent = 100 };
            },
        }
        root = root.withStyle(s);
    } else {
        var s = style_mod.Style{};
        s.background = Rgba.fromHex(0xf1f5f9);
        switch (st.placement) {
            .left, .right => {
                s.width = .{ .px = thickness };
                s.height = .{ .percent = 100 };
            },
            .bottom => {
                s.height = .{ .px = thickness };
                s.width = .{ .percent = 100 };
            },
        }
        root = root.withStyle(s);
    }

    var content: ?*Div = null;
    if (props.content_id) |cid| {
        const body = div_mod.div(arena).withId(cid).wFull().hFull();
        root = root.childDiv(body);
        content = body;
    }
    return .{ .root = root, .content = content };
}

pub const ToggleProps = struct {
    id: []const u8,
    state: app_mod.Entity(State),
    app: *App,
};

const ToggleClick = struct {
    app: *App,
    state: app_mod.Entity(State),
    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *ToggleClick = @ptrCast(@alignCast(ctx.?));
        self.app.read(State, self.state).toggle();
        self.app.notify(self.state.id);
    }
};

pub fn toggleButton(arena: std.mem.Allocator, props: ToggleProps) *Div {
    const st = props.app.read(State, props.state);
    var btn = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.button)
        .a11yName(if (st.open) "Close dock" else "Open dock")
        .sizePx(28, 28);
    const click = arena.create(ToggleClick) catch @panic("frame arena OOM");
    click.* = .{ .app = props.app, .state = props.state };
    return btn.onClick(click, ToggleClick.onClick);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

test "areaInsets shrinks center for open docks" {
    var left = State{ .placement = .left, .size = 180, .open = true };
    var right = State{ .placement = .right, .size = 120, .open = true };
    var bottom = State{ .placement = .bottom, .size = 100, .open = false };

    const insets = areaInsets(&left, &right, &bottom);
    try std.testing.expectEqual(@as(Pixels, 180), insets.left);
    try std.testing.expectEqual(@as(Pixels, 120), insets.right);
    try std.testing.expectEqual(@as(Pixels, 0), insets.bottom);

    const center = insets.centerSize(.{ .width = 800, .height = 600 });
    try std.testing.expectEqual(@as(Pixels, 500), center.width);
    try std.testing.expectEqual(@as(Pixels, 600), center.height);
}

test "dock toggle closes and opens" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 600, .height = 400 });
    defer harness.deinit();

    const Fixture = struct {
        state: app_mod.Entity(State) = undefined,

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, h: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const parts = dock(arena, .{
                .id = "left-dock",
                .state = self.state,
                .app = &h.app,
                .content_id = "dock-body",
            });
            const toggle = toggleButton(arena, .{
                .id = "dock-toggle",
                .state = self.state,
                .app = &h.app,
            });
            return div_mod.div(arena)
                .sizePx(600, 400)
                .flexRow()
                .childDiv(parts.root)
                .childDiv(toggle)
                .any();
        }
    };

    var fixture: Fixture = .{
        .state = try harness.app.new(State, .{ .placement = .left, .size = 160 }),
    };
    try harness.setRoot(&fixture, Fixture.render);

    const bounds = harness.hitboxBounds(element.elementId("left-dock")).?;
    try std.testing.expectEqual(@as(Pixels, 160), bounds.size.width);

    try harness.clickOn("dock-toggle");
    try harness.renderFrame();
    try std.testing.expect(!harness.app.read(State, fixture.state).open);
    try std.testing.expectEqual(@as(Pixels, 0), resolvedSize(harness.app.read(State, fixture.state)));
}
