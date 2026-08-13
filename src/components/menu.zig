//! Headless menu: compound list + items, modal overlay with keyboard
//! navigation (Up/Down, Enter/Space, Escape) and click-to-select.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const overlay_mod = @import("../overlay.zig");
const color = @import("../color.zig");
const geometry = @import("../geometry.zig");

const positioner = @import("positioner.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Rgba = color.Rgba;
const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Bounds = geometry.Bounds;
const Size = geometry.Size;

pub const CloseCallback = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque) void,
};

pub const MenuState = struct {
    open: bool = false,
    highlighted_index: i32 = -1,
    /// When set, the panel is positioned at this point (context menu).
    /// Otherwise it anchors near the menu trigger.
    anchor: ?Point(Pixels) = null,
    /// Optional hook invoked whenever the menu closes.
    close_listener: ?CloseCallback = null,

    pub fn openMenu(self: *MenuState) void {
        self.open = true;
        self.highlighted_index = 0;
    }

    pub fn openAt(self: *MenuState, point: Point(Pixels)) void {
        self.open = true;
        self.highlighted_index = 0;
        self.anchor = point;
    }

    pub fn close(self: *MenuState) void {
        if (self.close_listener) |cb| cb.func(cb.ctx);
        self.open = false;
        self.highlighted_index = -1;
        self.anchor = null;
    }
};

pub const SelectHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque) void,
};

pub const ItemStyleState = struct {
    highlighted: bool = false,
    hovered: bool = false,
    disabled: bool = false,
};

pub const ItemStyleFn = *const fn (state: ItemStyleState) style_mod.Style;
pub const StyleFn = *const fn (open: bool) style_mod.Style;
pub const ContentFn = *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator, registry: *MenuRegistry) anyerror!*Div;

pub const MenuRegistry = struct {
    entries: std.ArrayList(Entry),

    pub const Entry = struct {
        index: usize,
        disabled: bool,
        on_select: SelectHandler,
    };

    pub fn init() MenuRegistry {
        return .{ .entries = .empty };
    }

    pub fn register(self: *MenuRegistry, arena: std.mem.Allocator, entry: Entry) !void {
        try self.entries.append(arena, entry);
    }

    pub fn activate(self: *const MenuRegistry, index: usize) void {
        for (self.entries.items) |entry| {
            if (entry.index == index and !entry.disabled) {
                entry.on_select.func(entry.on_select.ctx);
                return;
            }
        }
    }
};

pub fn highlightedIndex(app: *App, state: app_mod.Entity(MenuState)) i32 {
    return app.read(MenuState, state).highlighted_index;
}

pub fn isHighlighted(app: *App, state: app_mod.Entity(MenuState), index: usize) bool {
    return highlightedIndex(app, state) == @as(i32, @intCast(index));
}

fn setHighlighted(app: *App, state: app_mod.Entity(MenuState), index: i32) void {
    app.read(MenuState, state).highlighted_index = index;
    app.notify(state.id);
}

fn moveHighlight(app: *App, state: app_mod.Entity(MenuState), registry: *const MenuRegistry, item_count: usize, delta: i32) void {
    if (item_count == 0) return;
    var idx = highlightedIndex(app, state);
    if (idx < 0) idx = 0;

    var attempts: usize = 0;
    while (attempts < item_count) : (attempts += 1) {
        var next = idx + delta;
        while (next < 0) next += @as(i32, @intCast(item_count));
        while (next >= @as(i32, @intCast(item_count))) next -= @as(i32, @intCast(item_count));
        idx = next;

        var disabled = false;
        for (registry.entries.items) |entry| {
            if (entry.index == @as(usize, @intCast(idx))) {
                disabled = entry.disabled;
                break;
            }
        }
        if (!disabled) {
            setHighlighted(app, state, idx);
            return;
        }
    }
}

pub fn close(app: *App, state: app_mod.Entity(MenuState)) void {
    const menu_state = app.read(MenuState, state);
    menu_state.close();
    menu_state.close_listener = null;
    app.notify(state.id);
}

pub fn open(app: *App, state: app_mod.Entity(MenuState)) void {
    app.read(MenuState, state).openMenu();
    app.notify(state.id);
}

pub fn openAt(app: *App, state: app_mod.Entity(MenuState), point: Point(Pixels)) void {
    app.read(MenuState, state).openAt(point);
    app.notify(state.id);
}

pub fn toggle(app: *App, state: app_mod.Entity(MenuState)) void {
    const s = app.read(MenuState, state);
    if (s.open) s.close() else s.openMenu();
    app.notify(state.id);
}

// ---------------------------------------------------------------------------
// List (keyboard navigation)
// ---------------------------------------------------------------------------

pub const ListProps = struct {
    id: []const u8,
    state: app_mod.Entity(MenuState),
    app: *App,
    item_count: usize,
    registry: *MenuRegistry,
};

const ListNav = struct {
    app: *App,
    state: app_mod.Entity(MenuState),
    item_count: usize,
    registry: *MenuRegistry,

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *ListNav = @ptrCast(@alignCast(ctx.?));
        if (self.item_count == 0) return false;

        switch (event.key) {
            .down => {
                moveHighlight(self.app, self.state, self.registry, self.item_count, 1);
                return true;
            },
            .up => {
                moveHighlight(self.app, self.state, self.registry, self.item_count, -1);
                return true;
            },
            .enter, .space => {
                const idx = highlightedIndex(self.app, self.state);
                if (idx < 0) return false;
                self.registry.activate(@intCast(idx));
                close(self.app, self.state);
                return true;
            },
            else => return false,
        }
    }
};

/// Focusable menu list container; handles Up/Down and Enter/Space.
pub fn menuList(arena: std.mem.Allocator, props: ListProps) *Div {
    const focus_id: element.FocusId = element.elementId(props.id);

    const nav = arena.create(ListNav) catch @panic("frame arena OOM");
    nav.* = .{
        .app = props.app,
        .state = props.state,
        .item_count = props.item_count,
        .registry = props.registry,
    };

    return div_mod.div(arena)
        .withId(props.id)
        .flexCol()
        .role(.menu)
        .focusable(focus_id, .{ .ctx = nav, .func = ListNav.onKey });
}

// ---------------------------------------------------------------------------
// Item
// ---------------------------------------------------------------------------

pub const ItemProps = struct {
    id: []const u8,
    state: app_mod.Entity(MenuState),
    app: *App,
    index: usize,
    disabled: bool = false,
    on_select: SelectHandler,
    style_fn: ?ItemStyleFn = null,
    registry: *MenuRegistry,
};

const ItemSelect = struct {
    app: *App,
    state: app_mod.Entity(MenuState),
    index: usize,
    on_select: SelectHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *ItemSelect = @ptrCast(@alignCast(ctx.?));
        setHighlighted(self.app, self.state, @intCast(self.index));
        self.on_select.func(self.on_select.ctx);
        close(self.app, self.state);
    }
};

pub fn menuItem(arena: std.mem.Allocator, input: *const element.InputState, props: ItemProps) !*Div {
    const id = element.elementId(props.id);

    props.registry.register(arena, .{
        .index = props.index,
        .disabled = props.disabled,
        .on_select = props.on_select,
    }) catch @panic("frame arena OOM");

    const item_state = ItemStyleState{
        .highlighted = isHighlighted(props.app, props.state, props.index),
        .hovered = input.isHovered(id),
        .disabled = props.disabled,
    };

    var d = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.menu_item)
        .a11ySelected(item_state.highlighted);
    if (props.disabled) {
        d = d.a11yDisabled(true);
    }
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(item_state));
    } else {
        var s = style_mod.Style{};
        s.width = .{ .px = 160 };
        s.height = .{ .px = 28 };
        s.padding = .{
            .top = .{ .px = 6 },
            .right = .{ .px = 10 },
            .bottom = .{ .px = 6 },
            .left = .{ .px = 10 },
        };
        s.background = if (item_state.highlighted)
            Rgba.fromHex(0xe5e7eb)
        else if (item_state.hovered)
            Rgba.fromHex(0xf3f4f6)
        else
            Rgba.fromHex(0xffffff);
        d = d.withStyle(s);
    }

    if (!props.disabled) {
        const select = arena.create(ItemSelect) catch @panic("frame arena OOM");
        select.* = .{
            .app = props.app,
            .state = props.state,
            .index = props.index,
            .on_select = props.on_select,
        };
        d = d.onClick(select, ItemSelect.onClick);
    }

    return d;
}

// ---------------------------------------------------------------------------
// Overlay host
// ---------------------------------------------------------------------------

pub const Props = struct {
    id: []const u8,
    /// Element id of the click trigger (dropdown positioning).
    trigger_id: []const u8 = "",
    state: app_mod.Entity(MenuState),
    overlays: *overlay_mod.OverlayStack,
    app: *App,
    frame: *const element.FrameState,
    input: *element.InputState,
    viewport: Size(Pixels),
    list_id: []const u8,
    z_index: i32 = 70,
    trap_focus: bool = true,
    modal: bool = true,
    panel_style: ?StyleFn = null,
    content_ctx: ?*anyopaque = null,
    content_fn: ?ContentFn = null,
    /// Invoked when the menu closes (Escape, outside click, item select).
    on_close: ?CloseCallback = null,
    placement: positioner.Placement = .bottom,
    alignment: positioner.Align = .center,
    offset: Pixels = 4,
    margin: Pixels = 8,
    panel_size: Size(Pixels) = .{ .width = 180, .height = 80 },
};

const Host = struct {
    app: *App,
    state: app_mod.Entity(MenuState),
    frame: *const element.FrameState,
    viewport: Size(Pixels),
    trigger_id: []const u8,
    panel_style: ?StyleFn,
    panel_id: []const u8,
    content_ctx: ?*anyopaque,
    content_fn: ?ContentFn,
    on_close: ?CloseCallback = null,
    placement: positioner.Placement = .bottom,
    alignment: positioner.Align = .center,
    offset: Pixels = 4,
    margin: Pixels = 8,
    panel_size: Size(Pixels) = .{ .width = 180, .height = 80 },

    fn dismiss(ctx: ?*anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        if (self.on_close) |cb| cb.func(cb.ctx);
        close(self.app, self.state);
    }

    fn dismissMouseDown(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        dismiss(ctx);
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!element.Element {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        const menu_state = self.app.read(MenuState, self.state);
        if (!menu_state.open) return div_mod.div(arena).sizePx(0, 0).any();

        var backdrop = div_mod.div(arena)
            .withId("menu-backdrop")
            .absolute()
            .wFull()
            .hFull()
            .interactive()
            .onMouseDown(self, dismissMouseDown);

        var panel = div_mod.div(arena)
            .withId(self.panel_id)
            .absolute()
            .interactive();
        if (self.panel_style) |style_fn| {
            panel = panel.withStyle(style_fn(true));
        } else {
            var s = style_mod.Style{};
            s.width = .{ .px = 180 };
            s.min_height = .{ .px = 40 };
            s.background = Rgba.fromHex(0xffffff);
            s.corner_radii = geometry.Corners(Pixels).all(6);
            s.padding = .{
                .top = .{ .px = 4 },
                .right = .{ .px = 4 },
                .bottom = .{ .px = 4 },
                .left = .{ .px = 4 },
            };
            panel = panel.withStyle(s);
        }
        panel = panel.onClick(null, struct {
            fn swallow(_: ?*anyopaque, _: *const platform.MouseButtonEvent) void {}
        }.swallow);

        if (self.content_fn) |content_fn| {
            const registry = arena.create(MenuRegistry) catch @panic("frame arena OOM");
            registry.* = MenuRegistry.init();
            const body = try content_fn(self.content_ctx, arena, registry);
            panel = panel.childDiv(body);
        }

        const origin: Point(Pixels) = if (menu_state.anchor) |point|
            positioner.resolveCorner(point, self.panel_size, self.viewport, self.margin)
        else if (triggerBounds(self.frame, self.trigger_id)) |bounds|
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

        return backdrop.childDiv(panel).any();
    }
};

const TriggerHost = struct {
    app: *App,
    state: app_mod.Entity(MenuState),
    input: *element.InputState,
    list_id: []const u8,

    fn toggle(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *TriggerHost = @ptrCast(@alignCast(ctx.?));
        const s = self.app.read(MenuState, self.state);
        if (s.open) {
            s.close();
        } else {
            s.openMenu();
            self.input.focus(element.elementId(self.list_id));
        }
        self.app.notify(self.state.id);
    }
};

fn triggerBounds(frame: *const element.FrameState, trigger_id: []const u8) ?Bounds(Pixels) {
    if (trigger_id.len == 0) return null;
    const id = element.elementId(trigger_id);
    for (frame.hitboxes.items) |hitbox| {
        if (hitbox.id != null and hitbox.id.? == id) return hitbox.bounds;
    }
    return null;
}

fn registerOverlay(arena: std.mem.Allocator, props: Props) !void {
    const is_open = props.app.read(MenuState, props.state).open;
    if (!is_open) return;

    const menu_state = props.app.read(MenuState, props.state);
    menu_state.close_listener = props.on_close;

    const host = arena.create(Host) catch @panic("frame arena OOM");
    host.* = .{
        .app = props.app,
        .state = props.state,
        .frame = props.frame,
        .viewport = props.viewport,
        .trigger_id = props.trigger_id,
        .panel_style = props.panel_style,
        .panel_id = props.id,
        .content_ctx = props.content_ctx,
        .content_fn = props.content_fn,
        .on_close = props.on_close,
        .placement = props.placement,
        .alignment = props.alignment,
        .offset = props.offset,
        .margin = props.margin,
        .panel_size = props.panel_size,
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

/// Zero-size main-tree placeholder; registers the menu overlay when open.
pub fn menu(arena: std.mem.Allocator, props: Props) !*Div {
    try registerOverlay(arena, props);
    return div_mod.div(arena).sizePx(0, 0);
}

/// Wire a click-to-toggle trigger and register the overlay when open.
pub fn menuWithTrigger(
    arena: std.mem.Allocator,
    props: Props,
    trigger: *Div,
) !*Div {
    const trigger_host = arena.create(TriggerHost) catch @panic("frame arena OOM");
    trigger_host.* = .{
        .app = props.app,
        .state = props.state,
        .input = props.input,
        .list_id = props.list_id,
    };
    _ = trigger.onClick(trigger_host, TriggerHost.toggle);

    try registerOverlay(arena, props);
    return trigger;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

const MenuFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(MenuState) = undefined,
    selected: i32 = -1,

    const item_count = 3;

    fn itemStyle(state: ItemStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 160 };
        s.height = .{ .px = 28 };
        s.background = if (state.highlighted) Rgba.fromHex(0xbfdbfe) else Rgba.fromHex(0xffffff);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *MenuFixture = @ptrCast(@alignCast(ctx.?));

        var trigger = div_mod.div(arena)
            .withId("menu-trigger")
            .sizePx(80, 30)
            .bg(Rgba.fromHex(0x336699));
        trigger = try menuWithTrigger(arena, .{
            .id = "actions-menu",
            .trigger_id = "menu-trigger",
            .state = self.state,
            .overlays = &harness.overlays,
            .app = &harness.app,
            .frame = &harness.frame,
            .input = &harness.input,
            .viewport = harness.viewport,
            .list_id = "menu-list",
            .content_ctx = self,
            .content_fn = buildMenu,
        }, trigger);

        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(trigger).any();
    }

    fn buildMenu(ctx: ?*anyopaque, arena: std.mem.Allocator, registry: *MenuRegistry) !*Div {
        const self: *MenuFixture = @ptrCast(@alignCast(ctx.?));
        const app = &self.harness.app;

        var list = menuList(arena, .{
            .id = "menu-list",
            .state = self.state,
            .app = app,
            .item_count = item_count,
            .registry = registry,
        });

        const names = [_][]const u8{ "menu-item-0", "menu-item-1", "menu-item-2" };
        for (names, 0..) |name, i| {
            list = list.childDiv(try menuItem(arena, &self.harness.input, .{
                .id = name,
                .state = self.state,
                .app = app,
                .index = i,
                .on_select = .{ .ctx = self, .func = onSelect },
                .style_fn = itemStyle,
                .registry = registry,
            }));
        }
        return list;
    }

    fn onSelect(ctx: ?*anyopaque) void {
        const self: *MenuFixture = @ptrCast(@alignCast(ctx.?));
        self.selected = highlightedIndex(&self.harness.app, self.state);
    }
};

test "menu near viewport edge stays fully inside" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    const EdgeFixture = struct {
        harness: *testing_mod.Harness = undefined,
        state: app_mod.Entity(MenuState) = undefined,

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, h: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));

            var trigger = div_mod.div(arena)
                .withId("menu-trigger")
                .absolute()
                .sizePx(80, 30)
                .bg(Rgba.fromHex(0x336699));
            var ts = trigger.style;
            ts.inset.top = .{ .px = 250 };
            ts.inset.left = .{ .px = 300 };
            trigger.style = ts;
            trigger = try menuWithTrigger(arena, .{
                .id = "actions-menu",
                .trigger_id = "menu-trigger",
                .state = self.state,
                .overlays = &h.overlays,
                .app = &h.app,
                .frame = &h.frame,
                .input = &h.input,
                .viewport = h.viewport,
                .list_id = "menu-list",
            }, trigger);

            return div_mod.div(arena).sizePx(400, 300).childDiv(trigger).any();
        }
    };

    var fixture = EdgeFixture{ .harness = &harness };
    fixture.state = try harness.app.new(MenuState, .{});
    try harness.setRoot(&fixture, EdgeFixture.render);

    try harness.clickOn("menu-trigger");
    const panel = harness.hitboxBounds(element.elementId("actions-menu")).?;
    try std.testing.expect(panel.origin.x >= 8 - 0.01);
    try std.testing.expect(panel.origin.y >= 8 - 0.01);
    try std.testing.expect(panel.right() <= 400 - 8 + 0.01);
    try std.testing.expect(panel.bottom() <= 300 - 8 + 0.01);
}

test "menu corner anchor clamps inside viewport" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    const CornerFixture = struct {
        harness: *testing_mod.Harness = undefined,
        state: app_mod.Entity(MenuState) = undefined,

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, h: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = try menu(arena, .{
                .id = "actions-menu",
                .state = self.state,
                .overlays = &h.overlays,
                .app = &h.app,
                .frame = &h.frame,
                .input = &h.input,
                .viewport = h.viewport,
                .list_id = "menu-list",
            });
            return div_mod.div(arena).sizePx(400, 300).any();
        }
    };

    var fixture = CornerFixture{ .harness = &harness };
    fixture.state = try harness.app.new(MenuState, .{});
    try harness.setRoot(&fixture, CornerFixture.render);

    harness.app.read(MenuState, fixture.state).openAt(.{ .x = 380, .y = 280 });
    harness.app.notify(fixture.state.id);
    try harness.renderFrame();

    const panel = harness.hitboxBounds(element.elementId("actions-menu")).?;
    try std.testing.expect(panel.origin.x >= 8 - 0.01);
    try std.testing.expect(panel.origin.y >= 8 - 0.01);
    try std.testing.expect(panel.right() <= 400 - 8 + 0.01);
    try std.testing.expect(panel.bottom() <= 300 - 8 + 0.01);
}

test "menu opens via trigger and closes via Escape" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = MenuFixture{ .harness = &harness };
    fixture.state = try harness.app.new(MenuState, .{});
    try harness.setRoot(&fixture, MenuFixture.render);

    try std.testing.expect(!harness.app.read(MenuState, fixture.state).open);
    try harness.clickOn("menu-trigger");
    try std.testing.expect(harness.app.read(MenuState, fixture.state).open);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);

    try harness.keyDown(.escape);
    try std.testing.expect(!harness.app.read(MenuState, fixture.state).open);
}

test "menu arrow keys move highlight and Enter selects" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = MenuFixture{ .harness = &harness };
    fixture.state = try harness.app.new(MenuState, .{});
    try harness.setRoot(&fixture, MenuFixture.render);

    try harness.clickOn("menu-trigger");
    try harness.focusById(element.elementId("menu-list"));

    try std.testing.expectEqual(@as(i32, 0), highlightedIndex(&harness.app, fixture.state));
    try harness.keyDown(.down);
    try std.testing.expectEqual(@as(i32, 1), highlightedIndex(&harness.app, fixture.state));
    try harness.keyDown(.down);
    try std.testing.expectEqual(@as(i32, 2), highlightedIndex(&harness.app, fixture.state));
    try harness.keyDown(.enter);
    try std.testing.expect(!harness.app.read(MenuState, fixture.state).open);
    try std.testing.expectEqual(@as(i32, 2), fixture.selected);
}

test "menu item click selects and closes" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = MenuFixture{ .harness = &harness };
    fixture.state = try harness.app.new(MenuState, .{});
    try harness.setRoot(&fixture, MenuFixture.render);

    try harness.clickOn("menu-trigger");
    try harness.clickOn("menu-item-1");
    try std.testing.expect(!harness.app.read(MenuState, fixture.state).open);
    try std.testing.expectEqual(@as(i32, 1), fixture.selected);
}
