//! Simplified navigation menu: horizontal `navMenu` + `navItem` links or
//! triggers. Optional single-level submenu via menu overlay. Optional
//! selected index with Left/Right keyboard navigation among items.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const overlay_mod = @import("../overlay.zig");
const geometry = @import("../geometry.zig");
const value_mod = @import("../value.zig");
const menu_mod = @import("menu.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Pixels = geometry.Pixels;
const Size = geometry.Size;

pub const NavMenuState = struct {
    selected: ?usize = null,
    submenu_open_index: ?usize = null,
    focus_index: usize = 0,
};

pub const SelectedValue = value_mod.FieldValue(NavMenuState, "selected");

pub const MenuState = menu_mod.MenuState;
pub const MenuRegistry = menu_mod.MenuRegistry;
pub const SubmenuContentFn = menu_mod.ContentFn;

pub fn selectedIndex(app: *App, value: SelectedValue) ?usize {
    return value.get(app);
}

pub fn isSelected(app: *App, value: SelectedValue, index: usize) bool {
    return selectedIndex(app, value) == index;
}

pub fn submenuOpenIndex(app: *App, state: app_mod.Entity(NavMenuState)) ?usize {
    return app.read(NavMenuState, state).submenu_open_index;
}

fn notify(app: *App, state: app_mod.Entity(NavMenuState)) void {
    app.notify(state.id);
}

fn select(app: *App, value: SelectedValue, nav_state: app_mod.Entity(NavMenuState), index: usize) void {
    value.set(app, index);
    app.read(NavMenuState, nav_state).focus_index = index;
    notify(app, nav_state);
}

fn closeSubmenu(app: *App, nav_state: app_mod.Entity(NavMenuState), menu_state: app_mod.Entity(MenuState)) void {
    app.read(NavMenuState, nav_state).submenu_open_index = null;
    menu_mod.close(app, menu_state);
    notify(app, nav_state);
}

fn openSubmenu(
    app: *App,
    nav_state: app_mod.Entity(NavMenuState),
    menu_state: app_mod.Entity(MenuState),
    input: *element.InputState,
    index: usize,
    list_id: []const u8,
) void {
    app.read(NavMenuState, nav_state).submenu_open_index = index;
    menu_mod.open(app, menu_state);
    input.focus(element.elementId(list_id));
    notify(app, nav_state);
}

fn moveFocus(app: *App, nav_state: app_mod.Entity(NavMenuState), item_count: usize, delta: i32) void {
    if (item_count == 0) return;
    const ns = app.read(NavMenuState, nav_state);
    const current = ns.focus_index;
    ns.focus_index = switch (delta) {
        -1 => (current + item_count - 1) % item_count,
        else => (current + 1) % item_count,
    };
    notify(app, nav_state);
}

// ---------------------------------------------------------------------------
// Nav menu root
// ---------------------------------------------------------------------------

pub const MenuProps = struct {
    id: []const u8,
    nav_state: app_mod.Entity(NavMenuState),
    app: *App,
    item_count: usize,
};

const MenuNav = struct {
    app: *App,
    nav_state: app_mod.Entity(NavMenuState),
    item_count: usize,

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *MenuNav = @ptrCast(@alignCast(ctx.?));
        if (self.item_count == 0) return false;

        switch (event.key) {
            .left => {
                moveFocus(self.app, self.nav_state, self.item_count, -1);
                return true;
            },
            .right => {
                moveFocus(self.app, self.nav_state, self.item_count, 1);
                return true;
            },
            else => return false,
        }
    }
};

/// Horizontal navigation menu container. Add `navItem` children.
pub fn navMenu(arena: std.mem.Allocator, props: MenuProps) *Div {
    const focus_id: element.FocusId = element.elementId(props.id);

    const nav = arena.create(MenuNav) catch @panic("frame arena OOM");
    nav.* = .{
        .app = props.app,
        .nav_state = props.nav_state,
        .item_count = props.item_count,
    };

    return div_mod.div(arena)
        .withId(props.id)
        .flexRow()
        .role(.list)
        .focusable(focus_id, .{ .ctx = nav, .func = MenuNav.onKey });
}

// ---------------------------------------------------------------------------
// Nav item (link or submenu trigger)
// ---------------------------------------------------------------------------

pub const ItemStyleState = struct {
    selected: bool = false,
    focused: bool = false,
    focus_visible: bool = false,
    submenu_open: bool = false,
    hovered: bool = false,
    disabled: bool = false,
};

pub const ItemStyleFn = *const fn (state: ItemStyleState) style_mod.Style;

pub const PressHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque) void,
};

pub const ItemProps = struct {
    id: []const u8,
    nav_state: app_mod.Entity(NavMenuState),
    selected: SelectedValue,
    app: *App,
    input: *element.InputState,
    index: usize,
    menu_id: []const u8,
    /// When true, click opens a submenu instead of firing `on_press`.
    is_trigger: bool = false,
    menu_state: ?app_mod.Entity(MenuState) = null,
    submenu_list_id: []const u8 = "",
    disabled: bool = false,
    on_press: ?PressHandler = null,
    style_fn: ?ItemStyleFn = null,
};

const LinkActivate = struct {
    app: *App,
    nav_state: app_mod.Entity(NavMenuState),
    selected: SelectedValue,
    index: usize,
    on_press: ?PressHandler,

    fn activate(self: *LinkActivate) void {
        select(self.app, self.selected, self.nav_state, self.index);
        if (self.on_press) |handler| handler.func(handler.ctx);
    }

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *LinkActivate = @ptrCast(@alignCast(ctx.?));
        self.activate();
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        if (event.key != .enter and event.key != .space) return false;
        const self: *LinkActivate = @ptrCast(@alignCast(ctx.?));
        self.activate();
        return true;
    }
};

const TriggerToggle = struct {
    app: *App,
    nav_state: app_mod.Entity(NavMenuState),
    menu_state: app_mod.Entity(MenuState),
    input: *element.InputState,
    index: usize,
    submenu_list_id: []const u8,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *TriggerToggle = @ptrCast(@alignCast(ctx.?));
        const open_idx = submenuOpenIndex(self.app, self.nav_state);
        if (open_idx != null and open_idx.? == self.index) {
            closeSubmenu(self.app, self.nav_state, self.menu_state);
        } else {
            openSubmenu(self.app, self.nav_state, self.menu_state, self.input, self.index, self.submenu_list_id);
        }
        self.app.read(NavMenuState, self.nav_state).focus_index = self.index;
        notify(self.app, self.nav_state);
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        if (event.key != .enter and event.key != .space and event.key != .down) return false;
        const self: *TriggerToggle = @ptrCast(@alignCast(ctx.?));
        openSubmenu(self.app, self.nav_state, self.menu_state, self.input, self.index, self.submenu_list_id);
        self.app.read(NavMenuState, self.nav_state).focus_index = self.index;
        notify(self.app, self.nav_state);
        return true;
    }
};

pub fn navItem(arena: std.mem.Allocator, props: ItemProps) *Div {
    const id = element.elementId(props.id);
    const focus_id: element.FocusId = id;
    const menu_focus_id = element.elementId(props.menu_id);
    const ns = props.app.read(NavMenuState, props.nav_state);

    const submenu_open = props.is_trigger and submenuOpenIndex(props.app, props.nav_state) == props.index;
    const state = ItemStyleState{
        .selected = isSelected(props.app, props.selected, props.index),
        .focused = ns.focus_index == props.index,
        .focus_visible = props.input.focus_visible and
            (props.input.isFocused(menu_focus_id) or props.input.isFocused(focus_id)) and
            ns.focus_index == props.index,
        .submenu_open = submenu_open,
        .hovered = props.input.isHovered(id),
        .disabled = props.disabled,
    };

    var d = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(if (props.is_trigger) .button else .link)
        .a11ySelected(state.selected);
    if (props.disabled) {
        d = d.a11yDisabled(true);
    }
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    } else {
        var s = style_mod.Style{};
        s.width = .{ .px = 64 };
        s.height = .{ .px = 28 };
        s.padding = .{
            .top = .{ .px = 6 },
            .right = .{ .px = 10 },
            .bottom = .{ .px = 6 },
            .left = .{ .px = 10 },
        };
        s.background = if (state.selected)
            @import("../color.zig").Rgba.fromHex(0xbfdbfe)
        else if (state.submenu_open or state.focus_visible)
            @import("../color.zig").Rgba.fromHex(0xf3f4f6)
        else if (state.hovered)
            @import("../color.zig").Rgba.fromHex(0xf9fafb)
        else
            @import("../color.zig").Rgba.fromHex(0xffffff);
        d = d.withStyle(s);
    }

    if (props.disabled) return d;

    if (props.is_trigger) {
        const menu_state = props.menu_state orelse @panic("navItem trigger requires menu_state");
        const toggle = arena.create(TriggerToggle) catch @panic("frame arena OOM");
        toggle.* = .{
            .app = props.app,
            .nav_state = props.nav_state,
            .menu_state = menu_state,
            .input = props.input,
            .index = props.index,
            .submenu_list_id = props.submenu_list_id,
        };
        d = d.onClick(toggle, TriggerToggle.onClick)
            .focusable(focus_id, .{ .ctx = toggle, .func = TriggerToggle.onKey });
    } else {
        const activate = arena.create(LinkActivate) catch @panic("frame arena OOM");
        activate.* = .{
            .app = props.app,
            .nav_state = props.nav_state,
            .selected = props.selected,
            .index = props.index,
            .on_press = props.on_press,
        };
        d = d.onClick(activate, LinkActivate.onClick)
            .focusable(focus_id, .{ .ctx = activate, .func = LinkActivate.onKey });
    }

    return d;
}

// ---------------------------------------------------------------------------
// Submenu overlay
// ---------------------------------------------------------------------------

pub const SubmenuProps = struct {
    id: []const u8,
    nav_state: app_mod.Entity(NavMenuState),
    menu_state: app_mod.Entity(MenuState),
    item_index: usize,
    trigger_id: []const u8,
    overlays: *overlay_mod.OverlayStack,
    app: *App,
    frame: *const element.FrameState,
    input: *element.InputState,
    viewport: Size(Pixels),
    list_id: []const u8,
    z_index: i32 = 65,
    content_ctx: ?*anyopaque = null,
    content_fn: ?SubmenuContentFn = null,
};

const SubmenuCloseBridge = struct {
    app: *App,
    nav_state: app_mod.Entity(NavMenuState),

    fn onClose(ctx: ?*anyopaque) void {
        const self: *SubmenuCloseBridge = @ptrCast(@alignCast(ctx.?));
        self.app.read(NavMenuState, self.nav_state).submenu_open_index = null;
        notify(self.app, self.nav_state);
    }
};

/// Register submenu overlay when the matching trigger is open.
pub fn navSubmenu(arena: std.mem.Allocator, props: SubmenuProps) !*Div {
    if (submenuOpenIndex(props.app, props.nav_state)) |idx| {
        if (idx != props.item_index) return div_mod.div(arena).sizePx(0, 0);
    } else {
        return div_mod.div(arena).sizePx(0, 0);
    }

    const bridge = arena.create(SubmenuCloseBridge) catch @panic("frame arena OOM");
    bridge.* = .{ .app = props.app, .nav_state = props.nav_state };

    if (!props.app.read(MenuState, props.menu_state).open) {
        menu_mod.open(props.app, props.menu_state);
    }

    return menu_mod.menu(arena, .{
        .id = props.id,
        .trigger_id = props.trigger_id,
        .state = props.menu_state,
        .overlays = props.overlays,
        .app = props.app,
        .frame = props.frame,
        .input = props.input,
        .viewport = props.viewport,
        .list_id = props.list_id,
        .z_index = props.z_index,
        .content_ctx = props.content_ctx,
        .content_fn = props.content_fn,
        .on_close = .{ .ctx = bridge, .func = SubmenuCloseBridge.onClose },
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const NavFixture = struct {
    harness: *testing_mod.Harness = undefined,
    nav_state: app_mod.Entity(NavMenuState) = undefined,
    menu_state: app_mod.Entity(MenuState) = undefined,
    presses: u32 = 0,

    const item_names = [_][]const u8{ "nav-home", "nav-products", "nav-more" };

    fn itemStyle(state: ItemStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 64 };
        s.height = .{ .px = 28 };
        s.background = if (state.selected) color.Rgba.fromHex(0xbfdbfe) else color.Rgba.fromHex(0xffffff);
        return s;
    }

    fn onHomePress(ctx: ?*anyopaque) void {
        const self: *NavFixture = @ptrCast(@alignCast(ctx.?));
        self.presses += 1;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *NavFixture = @ptrCast(@alignCast(ctx.?));
        const app = &harness.app;
        const selected: SelectedValue = .{ .uncontrolled = self.nav_state };

        var menu = navMenu(arena, .{
            .id = "nav-menu",
            .nav_state = self.nav_state,
            .app = app,
            .item_count = item_names.len,
        });

        menu = menu.childDiv(navItem(arena, .{
            .id = item_names[0],
            .nav_state = self.nav_state,
            .selected = selected,
            .app = app,
            .input = &harness.input,
            .index = 0,
            .menu_id = "nav-menu",
            .on_press = .{ .ctx = self, .func = onHomePress },
            .style_fn = itemStyle,
        }));
        menu = menu.childDiv(navItem(arena, .{
            .id = item_names[1],
            .nav_state = self.nav_state,
            .selected = selected,
            .app = app,
            .input = &harness.input,
            .index = 1,
            .menu_id = "nav-menu",
            .style_fn = itemStyle,
        }));
        menu = menu.childDiv(navItem(arena, .{
            .id = item_names[2],
            .nav_state = self.nav_state,
            .selected = selected,
            .app = app,
            .input = &harness.input,
            .index = 2,
            .menu_id = "nav-menu",
            .is_trigger = true,
            .menu_state = self.menu_state,
            .submenu_list_id = "nav-submenu-list",
            .style_fn = itemStyle,
        }));

        _ = try navSubmenu(arena, .{
            .id = "nav-submenu",
            .nav_state = self.nav_state,
            .menu_state = self.menu_state,
            .item_index = 2,
            .trigger_id = item_names[2],
            .overlays = &harness.overlays,
            .app = app,
            .frame = &harness.frame,
            .input = &harness.input,
            .viewport = harness.viewport,
            .list_id = "nav-submenu-list",
            .content_ctx = self,
            .content_fn = buildSubmenu,
        });

        return div_mod.div(arena).sizePx(400, 80).padPx(20).childDiv(menu).any();
    }

    fn buildSubmenu(ctx: ?*anyopaque, arena: std.mem.Allocator, registry: *MenuRegistry) !*Div {
        const self: *NavFixture = @ptrCast(@alignCast(ctx.?));
        const app = &self.harness.app;

        var list = menu_mod.menuList(arena, .{
            .id = "nav-submenu-list",
            .state = self.menu_state,
            .app = app,
            .item_count = 1,
            .registry = registry,
        });
        list = list.childDiv(try menu_mod.menuItem(arena, &self.harness.input, .{
            .id = "submenu-action",
            .state = self.menu_state,
            .app = app,
            .index = 0,
            .on_select = .{ .ctx = self, .func = onSubmenuSelect },
            .registry = registry,
        }));
        return list;
    }

    fn onSubmenuSelect(ctx: ?*anyopaque) void {
        const self: *NavFixture = @ptrCast(@alignCast(ctx.?));
        self.presses += 10;
    }
};

test "nav menu selects item on click" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 80 });
    defer harness.deinit();

    var fixture = NavFixture{ .harness = &harness };
    fixture.nav_state = try harness.app.new(NavMenuState, .{});
    fixture.menu_state = try harness.app.new(MenuState, .{});
    try harness.setRoot(&fixture, NavFixture.render);

    const selected: SelectedValue = .{ .uncontrolled = fixture.nav_state };

    try harness.clickOn("nav-home");
    try std.testing.expectEqual(@as(?usize, 0), selectedIndex(&harness.app, selected));
    try std.testing.expectEqual(@as(u32, 1), fixture.presses);

    try harness.clickOn("nav-products");
    try std.testing.expectEqual(@as(?usize, 1), selectedIndex(&harness.app, selected));
}

test "nav menu arrow keys move focus among items" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 80 });
    defer harness.deinit();

    var fixture = NavFixture{ .harness = &harness };
    fixture.nav_state = try harness.app.new(NavMenuState, .{});
    fixture.menu_state = try harness.app.new(MenuState, .{});
    try harness.setRoot(&fixture, NavFixture.render);

    try harness.focusById(element.elementId("nav-menu"));
    try std.testing.expectEqual(@as(usize, 0), harness.app.read(NavMenuState, fixture.nav_state).focus_index);

    try harness.keyDown(.right);
    try std.testing.expectEqual(@as(usize, 1), harness.app.read(NavMenuState, fixture.nav_state).focus_index);

    try harness.keyDown(.right);
    try std.testing.expectEqual(@as(usize, 2), harness.app.read(NavMenuState, fixture.nav_state).focus_index);
}

test "nav menu opens submenu from trigger" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 80 });
    defer harness.deinit();

    var fixture = NavFixture{ .harness = &harness };
    fixture.nav_state = try harness.app.new(NavMenuState, .{});
    fixture.menu_state = try harness.app.new(MenuState, .{});
    try harness.setRoot(&fixture, NavFixture.render);

    try harness.clickOn("nav-more");
    try std.testing.expectEqual(@as(?usize, 2), submenuOpenIndex(&harness.app, fixture.nav_state));
    try std.testing.expect(harness.app.read(MenuState, fixture.menu_state).open);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);

    // Enter selects the highlighted item without a second mouse_up hitting the trigger.
    try harness.keyDown(.enter);
    try std.testing.expect(submenuOpenIndex(&harness.app, fixture.nav_state) == null);
    try std.testing.expectEqual(@as(u32, 10), fixture.presses);
}
