//! Headless sidebar: collapsible navigation chrome (gpui-component Sidebar).
//!
//! Ports layout contracts: Icon / Offcanvas / None collapse modes, left/right
//! side, and resolved wrapper width — not theme chrome or list virtualization.

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
const Rgba = color.Rgba;

pub const default_width: Pixels = 255;
pub const collapsed_width: Pixels = 48;

pub const Side = enum { left, right };

/// How the sidebar behaves when collapsed (shadcn / gpui-component modes).
pub const Collapsible = enum {
    /// Collapse to icon rail width.
    icon,
    /// Collapse out of layout (width → 0).
    offcanvas,
    /// Ignore collapsed state.
    none,
};

pub const Layout = struct {
    icon_collapsed: bool,
    offcanvas_collapsed: bool,
    /// Resolved layout width reserved for the sidebar wrapper.
    wrapper_width: Pixels,
    /// When false, callers should omit sidebar content (offcanvas fully hidden).
    render_content: bool,
};

pub fn resolveLayout(
    mode: Collapsible,
    collapsed: bool,
    expanded_width: Pixels,
    side: Side,
) Layout {
    _ = side;
    const effective = collapsed and mode != .none;
    return switch (mode) {
        .none => .{
            .icon_collapsed = false,
            .offcanvas_collapsed = false,
            .wrapper_width = expanded_width,
            .render_content = true,
        },
        .icon => .{
            .icon_collapsed = effective,
            .offcanvas_collapsed = false,
            .wrapper_width = if (effective) collapsed_width else expanded_width,
            .render_content = true,
        },
        .offcanvas => .{
            .icon_collapsed = false,
            .offcanvas_collapsed = effective,
            .wrapper_width = if (effective) 0 else expanded_width,
            .render_content = !effective,
        },
    };
}

pub const State = struct {
    collapsed: bool = false,
    collapsible: Collapsible = .icon,
    side: Side = .left,
    expanded_width: Pixels = default_width,

    pub fn toggle(self: *State) void {
        if (self.collapsible == .none) return;
        self.collapsed = !self.collapsed;
    }

    pub fn layout(self: *const State) Layout {
        return resolveLayout(self.collapsible, self.collapsed, self.expanded_width, self.side);
    }
};

pub const StyleState = struct {
    collapsed: bool = false,
    icon_collapsed: bool = false,
    side: Side = .left,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;
pub const ToggleHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque) void,
};

pub const Props = struct {
    id: []const u8,
    state: app_mod.Entity(State),
    app: *App,
    style_fn: ?StyleFn = null,
    /// Optional header / footer / body content ids for composition tests.
    header_id: ?[]const u8 = null,
    footer_id: ?[]const u8 = null,
    content_id: ?[]const u8 = null,
};

pub const Parts = struct {
    root: *Div,
    content: ?*Div,
};

/// Build a sidebar column sized by `State.layout()`.
pub fn sidebar(arena: std.mem.Allocator, props: Props) Parts {
    const st = props.app.read(State, props.state);
    const layout = st.layout();
    const style_state = StyleState{
        .collapsed = st.collapsed,
        .icon_collapsed = layout.icon_collapsed,
        .side = st.side,
    };

    if (!layout.render_content) {
        var root = div_mod.div(arena).withId(props.id).sizePx(0, 0).interactive();
        if (props.style_fn) |style_fn| root = root.withStyle(style_fn(style_state));
        return .{ .root = root, .content = null };
    }

    var root = div_mod.div(arena)
        .withId(props.id)
        .flexCol()
        .hFull()
        .wPx(layout.wrapper_width)
        .interactive();
    if (props.style_fn) |style_fn| {
        var s = style_fn(style_state);
        s.width = .{ .px = layout.wrapper_width };
        root = root.withStyle(s);
    } else {
        var s = style_mod.Style{};
        s.width = .{ .px = layout.wrapper_width };
        s.height = .{ .percent = 100 };
        s.background = Rgba.fromHex(0xf8fafc);
        root = root.withStyle(s);
    }

    if (props.header_id) |hid| {
        root = root.childDiv(div_mod.div(arena).withId(hid).wFull());
    }

    var content: ?*Div = null;
    if (props.content_id) |cid| {
        const body = div_mod.div(arena).withId(cid).flexCol().wFull();
        root = root.childDiv(body);
        content = body;
    }

    if (props.footer_id) |fid| {
        root = root.childDiv(div_mod.div(arena).withId(fid).wFull());
    }

    return .{ .root = root, .content = content };
}

pub const ToggleProps = struct {
    id: []const u8,
    state: app_mod.Entity(State),
    app: *App,
    on_toggle: ?ToggleHandler = null,
    style_fn: ?StyleFn = null,
};

const ToggleClick = struct {
    app: *App,
    state: app_mod.Entity(State),
    on_toggle: ?ToggleHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *ToggleClick = @ptrCast(@alignCast(ctx.?));
        const st = self.app.read(State, self.state);
        st.toggle();
        self.app.notify(self.state.id);
        if (self.on_toggle) |handler| handler.func(handler.ctx);
    }
};

pub fn toggleButton(arena: std.mem.Allocator, props: ToggleProps) *Div {
    const st = props.app.read(State, props.state);
    const layout = st.layout();
    const style_state = StyleState{
        .collapsed = st.collapsed,
        .icon_collapsed = layout.icon_collapsed,
        .side = st.side,
    };

    var btn = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.button)
        .a11yName(if (st.collapsed) "Expand sidebar" else "Collapse sidebar");
    if (props.style_fn) |style_fn| {
        btn = btn.withStyle(style_fn(style_state));
    } else {
        var s = style_mod.Style{};
        s.width = .{ .px = 32 };
        s.height = .{ .px = 32 };
        s.background = Rgba.fromHex(0xe2e8f0);
        btn = btn.withStyle(s);
    }

    const click = arena.create(ToggleClick) catch @panic("frame arena OOM");
    click.* = .{ .app = props.app, .state = props.state, .on_toggle = props.on_toggle };
    return btn.onClick(click, ToggleClick.onClick);
}

// ---------------------------------------------------------------------------
// Menu item (active navigation row)
// ---------------------------------------------------------------------------

pub const ItemStyleState = struct {
    active: bool = false,
    hovered: bool = false,
    collapsed: bool = false,
};

pub const ItemStyleFn = *const fn (state: ItemStyleState) style_mod.Style;
pub const ItemHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque) void,
};

pub const ItemProps = struct {
    id: []const u8,
    active: bool = false,
    collapsed: bool = false,
    on_click: ?ItemHandler = null,
    style_fn: ?ItemStyleFn = null,
};

const ItemClick = struct {
    on_click: ItemHandler,
    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *ItemClick = @ptrCast(@alignCast(ctx.?));
        self.on_click.func(self.on_click.ctx);
    }
};

pub fn menuItem(arena: std.mem.Allocator, input: *const element.InputState, props: ItemProps) *Div {
    const state = ItemStyleState{
        .active = props.active,
        .hovered = input.isHovered(element.elementId(props.id)),
        .collapsed = props.collapsed,
    };
    var d = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.button)
        .a11ySelected(props.active);
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    } else {
        var s = style_mod.Style{};
        s.width = .{ .percent = 100 };
        s.height = .{ .px = 32 };
        s.background = if (props.active) Rgba.fromHex(0xdbeafe) else Rgba.fromHex(0xffffff);
        d = d.withStyle(s);
    }
    if (props.on_click) |handler| {
        const click = arena.create(ItemClick) catch @panic("frame arena OOM");
        click.* = .{ .on_click = handler };
        d = d.onClick(click, ItemClick.onClick);
    }
    return d;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

test "resolveLayout icon and offcanvas modes" {
    const icon_c = resolveLayout(.icon, true, 240, .left);
    try std.testing.expect(icon_c.icon_collapsed);
    try std.testing.expectEqual(collapsed_width, icon_c.wrapper_width);
    try std.testing.expect(icon_c.render_content);

    const icon_e = resolveLayout(.icon, false, 240, .left);
    try std.testing.expectEqual(@as(Pixels, 240), icon_e.wrapper_width);

    const off_c = resolveLayout(.offcanvas, true, 240, .left);
    try std.testing.expect(off_c.offcanvas_collapsed);
    try std.testing.expectEqual(@as(Pixels, 0), off_c.wrapper_width);
    try std.testing.expect(!off_c.render_content);

    const none_c = resolveLayout(.none, true, 240, .right);
    try std.testing.expectEqual(@as(Pixels, 240), none_c.wrapper_width);
    try std.testing.expect(none_c.render_content);
}

test "sidebar toggle collapses to icon width" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    const Fixture = struct {
        state: app_mod.Entity(State) = undefined,

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, h: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const parts = sidebar(arena, .{
                .id = "nav",
                .state = self.state,
                .app = &h.app,
                .content_id = "nav-body",
            });
            const toggle = toggleButton(arena, .{
                .id = "nav-toggle",
                .state = self.state,
                .app = &h.app,
            });
            return div_mod.div(arena)
                .sizePx(400, 300)
                .flexRow()
                .childDiv(parts.root)
                .childDiv(toggle)
                .any();
        }
    };

    var fixture: Fixture = .{
        .state = try harness.app.new(State, .{ .expanded_width = 240 }),
    };
    try harness.setRoot(&fixture, Fixture.render);

    var bounds = harness.hitboxBounds(element.elementId("nav")).?;
    try std.testing.expectEqual(@as(Pixels, 240), bounds.size.width);

    try harness.clickOn("nav-toggle");
    try harness.renderFrame();
    bounds = harness.hitboxBounds(element.elementId("nav")).?;
    try std.testing.expectEqual(collapsed_width, bounds.size.width);
    try std.testing.expect(harness.app.read(State, fixture.state).collapsed);
}
