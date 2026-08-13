//! Headless menubar: horizontal top-level triggers open dropdown menus
//! (reusing `menu.zig` overlay). Arrow Left/Right move among triggers;
//! Down opens the focused menu; Escape closes.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const overlay_mod = @import("../overlay.zig");
const geometry = @import("../geometry.zig");
const menu_mod = @import("menu.zig");
const color = @import("../color.zig");
const a11y_mod = @import("../a11y.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Pixels = geometry.Pixels;
const Size = geometry.Size;

pub const MenubarState = struct {
    open_index: ?usize = null,
    focus_index: usize = 0,
};

pub const MenuState = menu_mod.MenuState;
pub const MenuRegistry = menu_mod.MenuRegistry;
pub const SelectHandler = menu_mod.SelectHandler;
pub const ContentFn = menu_mod.ContentFn;

pub const menuList = menu_mod.menuList;
pub const menuItem = menu_mod.menuItem;
pub const highlightedIndex = menu_mod.highlightedIndex;
pub const isHighlighted = menu_mod.isHighlighted;

pub fn openIndex(app: *App, state: app_mod.Entity(MenubarState)) ?usize {
    return app.read(MenubarState, state).open_index;
}

pub fn focusIndex(app: *App, state: app_mod.Entity(MenubarState)) usize {
    return app.read(MenubarState, state).focus_index;
}

pub fn isMenuOpen(app: *App, state: app_mod.Entity(MenubarState), index: usize) bool {
    const s = app.read(MenubarState, state);
    return s.open_index != null and s.open_index.? == index;
}

fn notify(app: *App, state: app_mod.Entity(MenubarState)) void {
    app.notify(state.id);
}

pub fn closeMenu(app: *App, menubar_state: app_mod.Entity(MenubarState), menu_state: app_mod.Entity(MenuState)) void {
    app.read(MenubarState, menubar_state).open_index = null;
    menu_mod.close(app, menu_state);
    notify(app, menubar_state);
}

fn openMenuAt(
    app: *App,
    menubar_state: app_mod.Entity(MenubarState),
    menu_state: app_mod.Entity(MenuState),
    input: *element.InputState,
    index: usize,
    list_id: []const u8,
) void {
    const mb = app.read(MenubarState, menubar_state);
    mb.open_index = index;
    mb.focus_index = index;
    menu_mod.open(app, menu_state);
    input.focus(element.elementId(list_id));
    notify(app, menubar_state);
}

fn moveFocus(app: *App, menubar_state: app_mod.Entity(MenubarState), menu_state: app_mod.Entity(MenuState), item_count: usize, delta: i32) void {
    if (item_count == 0) return;
    const mb = app.read(MenubarState, menubar_state);
    const current = mb.focus_index;
    const next: usize = switch (delta) {
        -1 => (current + item_count - 1) % item_count,
        else => (current + 1) % item_count,
    };
    mb.focus_index = next;
    if (mb.open_index != null) {
        mb.open_index = next;
        menu_mod.open(app, menu_state);
    }
    notify(app, menubar_state);
}

// ---------------------------------------------------------------------------
// Menubar list
// ---------------------------------------------------------------------------

pub const ListProps = struct {
    id: []const u8,
    menubar_state: app_mod.Entity(MenubarState),
    menu_state: app_mod.Entity(MenuState),
    app: *App,
    item_count: usize,
    /// Menu list id passed to `openMenuAt` when Down is pressed.
    list_id: []const u8,
};

const ListNav = struct {
    app: *App,
    menubar_state: app_mod.Entity(MenubarState),
    menu_state: app_mod.Entity(MenuState),
    item_count: usize,
    list_id: []const u8,
    input: *element.InputState,

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *ListNav = @ptrCast(@alignCast(ctx.?));
        if (self.item_count == 0) return false;

        switch (event.key) {
            .left => {
                moveFocus(self.app, self.menubar_state, self.menu_state, self.item_count, -1);
                return true;
            },
            .right => {
                moveFocus(self.app, self.menubar_state, self.menu_state, self.item_count, 1);
                return true;
            },
            .down => {
                const idx = focusIndex(self.app, self.menubar_state);
                openMenuAt(self.app, self.menubar_state, self.menu_state, self.input, idx, self.list_id);
                return true;
            },
            .escape => {
                if (openIndex(self.app, self.menubar_state) != null) {
                    closeMenu(self.app, self.menubar_state, self.menu_state);
                    return true;
                }
                return false;
            },
            else => return false,
        }
    }
};

/// Horizontal menubar container with arrow-key navigation among top-level items.
pub fn menubar(arena: std.mem.Allocator, input: *element.InputState, props: ListProps) *Div {
    const focus_id: element.FocusId = element.elementId(props.id);

    const nav = arena.create(ListNav) catch @panic("frame arena OOM");
    nav.* = .{
        .app = props.app,
        .menubar_state = props.menubar_state,
        .menu_state = props.menu_state,
        .item_count = props.item_count,
        .list_id = props.list_id,
        .input = input,
    };

    return div_mod.div(arena)
        .withId(props.id)
        .flexRow()
        .role(.menu_bar)
        .a11yOrientation(.horizontal)
        .a11yName(props.id)
        .focusable(focus_id, .{ .ctx = nav, .func = ListNav.onKey });
}

// ---------------------------------------------------------------------------
// Menubar item (trigger)
// ---------------------------------------------------------------------------

pub const TriggerStyleState = struct {
    open: bool = false,
    focused: bool = false,
    focus_visible: bool = false,
    hovered: bool = false,
    disabled: bool = false,
};

pub const TriggerStyleFn = *const fn (state: TriggerStyleState) style_mod.Style;

pub const ItemProps = struct {
    id: []const u8,
    menubar_state: app_mod.Entity(MenubarState),
    menu_state: app_mod.Entity(MenuState),
    app: *App,
    input: *element.InputState,
    index: usize,
    menubar_id: []const u8,
    list_id: []const u8,
    disabled: bool = false,
    style_fn: ?TriggerStyleFn = null,
};

const ItemToggle = struct {
    app: *App,
    menubar_state: app_mod.Entity(MenubarState),
    menu_state: app_mod.Entity(MenuState),
    input: *element.InputState,
    index: usize,
    list_id: []const u8,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *ItemToggle = @ptrCast(@alignCast(ctx.?));
        if (isMenuOpen(self.app, self.menubar_state, self.index)) {
            closeMenu(self.app, self.menubar_state, self.menu_state);
        } else {
            openMenuAt(self.app, self.menubar_state, self.menu_state, self.input, self.index, self.list_id);
        }
        const mb = self.app.read(MenubarState, self.menubar_state);
        mb.focus_index = self.index;
        notify(self.app, self.menubar_state);
    }
};

pub fn menubarItem(arena: std.mem.Allocator, props: ItemProps) *Div {
    const id = element.elementId(props.id);
    const menubar_focus_id = element.elementId(props.menubar_id);
    const mb = props.app.read(MenubarState, props.menubar_state);

    const state = TriggerStyleState{
        .open = isMenuOpen(props.app, props.menubar_state, props.index),
        .focused = mb.focus_index == props.index,
        .focus_visible = props.input.focus_visible and props.input.isFocused(menubar_focus_id) and mb.focus_index == props.index,
        .hovered = props.input.isHovered(id),
        .disabled = props.disabled,
    };

    var d = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.menu_item)
        .a11yExpanded(state.open)
        .a11ySelected(state.focused);
    if (props.disabled) {
        d = d.a11yDisabled(true);
    }
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    } else {
        var s = style_mod.Style{};
        s.width = .{ .px = 72 };
        s.height = .{ .px = 28 };
        s.padding = .{
            .top = .{ .px = 6 },
            .right = .{ .px = 10 },
            .bottom = .{ .px = 6 },
            .left = .{ .px = 10 },
        };
        s.background = if (state.open)
            Rgba.fromHex(0xe5e7eb)
        else if (state.focus_visible)
            Rgba.fromHex(0xf3f4f6)
        else if (state.hovered)
            Rgba.fromHex(0xf9fafb)
        else
            Rgba.fromHex(0xffffff);
        d = d.withStyle(s);
    }

    if (!props.disabled) {
        const toggle = arena.create(ItemToggle) catch @panic("frame arena OOM");
        toggle.* = .{
            .app = props.app,
            .menubar_state = props.menubar_state,
            .menu_state = props.menu_state,
            .input = props.input,
            .index = props.index,
            .list_id = props.list_id,
        };
        d = d.onClick(toggle, ItemToggle.onClick);
    }

    return d;
}

const Rgba = color.Rgba;

// ---------------------------------------------------------------------------
// Dropdown overlay (one call per open item, or one shared with item_index)
// ---------------------------------------------------------------------------

pub const MenuProps = struct {
    id: []const u8,
    menubar_state: app_mod.Entity(MenubarState),
    menu_state: app_mod.Entity(MenuState),
    item_index: usize,
    trigger_id: []const u8,
    overlays: *overlay_mod.OverlayStack,
    app: *App,
    frame: *const element.FrameState,
    input: *element.InputState,
    viewport: Size(Pixels),
    list_id: []const u8,
    z_index: i32 = 72,
    content_ctx: ?*anyopaque = null,
    content_fn: ?ContentFn = null,
};

const CloseBridge = struct {
    app: *App,
    menubar_state: app_mod.Entity(MenubarState),
    menu_state: app_mod.Entity(MenuState),

    fn onClose(ctx: ?*anyopaque) void {
        const self: *CloseBridge = @ptrCast(@alignCast(ctx.?));
        self.app.read(MenubarState, self.menubar_state).open_index = null;
        notify(self.app, self.menubar_state);
    }
};

/// Register the dropdown overlay when this item's menu is open.
pub fn menubarMenu(arena: std.mem.Allocator, props: MenuProps) !*Div {
    if (openIndex(props.app, props.menubar_state)) |idx| {
        if (idx != props.item_index) return div_mod.div(arena).sizePx(0, 0);
    } else {
        return div_mod.div(arena).sizePx(0, 0);
    }

    const bridge = arena.create(CloseBridge) catch @panic("frame arena OOM");
    bridge.* = .{
        .app = props.app,
        .menubar_state = props.menubar_state,
        .menu_state = props.menu_state,
    };

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
        .on_close = .{ .ctx = bridge, .func = CloseBridge.onClose },
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

const MenubarFixture = struct {
    harness: *testing_mod.Harness = undefined,
    menubar_state: app_mod.Entity(MenubarState) = undefined,
    menu_state: app_mod.Entity(MenuState) = undefined,
    selected: i32 = -1,

    const item_names = [_][]const u8{ "mb-file", "mb-edit", "mb-view" };
    const menu_ids = [_][]const u8{ "menu-file", "menu-edit", "menu-view" };

    fn itemStyle(state: TriggerStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 72 };
        s.height = .{ .px = 28 };
        s.background = if (state.open) color.Rgba.fromHex(0xbfdbfe) else color.Rgba.fromHex(0xffffff);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *MenubarFixture = @ptrCast(@alignCast(ctx.?));
        const app = &harness.app;

        var bar = menubar(arena, &harness.input, .{
            .id = "menubar",
            .menubar_state = self.menubar_state,
            .menu_state = self.menu_state,
            .app = app,
            .item_count = item_names.len,
            .list_id = "menubar-menu-list",
        });

        for (item_names, 0..) |name, i| {
            bar = bar.childDiv(menubarItem(arena, .{
                .id = name,
                .menubar_state = self.menubar_state,
                .menu_state = self.menu_state,
                .app = app,
                .input = &harness.input,
                .index = i,
                .menubar_id = "menubar",
                .list_id = "menubar-menu-list",
                .style_fn = itemStyle,
            }));
        }

        for (menu_ids, 0..) |menu_id, i| {
            _ = try menubarMenu(arena, .{
                .id = menu_id,
                .menubar_state = self.menubar_state,
                .menu_state = self.menu_state,
                .item_index = i,
                .trigger_id = item_names[i],
                .overlays = &harness.overlays,
                .app = app,
                .frame = &harness.frame,
                .input = &harness.input,
                .viewport = harness.viewport,
                .list_id = "menubar-menu-list",
                .content_ctx = self,
                .content_fn = buildMenu,
            });
        }

        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(bar).any();
    }

    fn buildMenu(ctx: ?*anyopaque, arena: std.mem.Allocator, registry: *MenuRegistry) !*Div {
        const self: *MenubarFixture = @ptrCast(@alignCast(ctx.?));
        const app = &self.harness.app;

        var list = menuList(arena, .{
            .id = "menubar-menu-list",
            .state = self.menu_state,
            .app = app,
            .item_count = 2,
            .registry = registry,
        });

        list = list.childDiv(try menuItem(arena, &self.harness.input, .{
            .id = "mb-action-a",
            .state = self.menu_state,
            .app = app,
            .index = 0,
            .on_select = .{ .ctx = self, .func = onSelect },
            .registry = registry,
        }));
        list = list.childDiv(try menuItem(arena, &self.harness.input, .{
            .id = "mb-action-b",
            .state = self.menu_state,
            .app = app,
            .index = 1,
            .on_select = .{ .ctx = self, .func = onSelect },
            .registry = registry,
        }));
        return list;
    }

    fn onSelect(ctx: ?*anyopaque) void {
        const self: *MenubarFixture = @ptrCast(@alignCast(ctx.?));
        self.selected = highlightedIndex(&self.harness.app, self.menu_state);
    }
};

test "menubar opens menu via trigger click" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = MenubarFixture{ .harness = &harness };
    fixture.menubar_state = try harness.app.new(MenubarState, .{});
    fixture.menu_state = try harness.app.new(MenuState, .{});
    try harness.setRoot(&fixture, MenubarFixture.render);

    try std.testing.expect(openIndex(&harness.app, fixture.menubar_state) == null);
    try std.testing.expectEqual(a11y_mod.Role.menu_bar, harness.a11yRole("menubar").?);
    try std.testing.expectEqual(a11y_mod.Orientation.horizontal, harness.a11yNode("menubar").?.orientation.?);
    try std.testing.expectEqual(a11y_mod.Role.menu_item, harness.a11yRole("mb-file").?);
    try harness.clickOn("mb-file");
    try std.testing.expectEqual(@as(?usize, 0), openIndex(&harness.app, fixture.menubar_state));
    try std.testing.expect(harness.app.read(MenuState, fixture.menu_state).open);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);
    try std.testing.expect(harness.a11yNode("mb-file").?.expanded.?);
    try std.testing.expectEqual(@as(?bool, true), harness.a11yNode("mb-file").?.selected);
}

test "menubar arrow keys move focus between top-level items" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = MenubarFixture{ .harness = &harness };
    fixture.menubar_state = try harness.app.new(MenubarState, .{});
    fixture.menu_state = try harness.app.new(MenuState, .{});
    try harness.setRoot(&fixture, MenubarFixture.render);

    try harness.focusById(element.elementId("menubar"));
    try std.testing.expectEqual(@as(usize, 0), focusIndex(&harness.app, fixture.menubar_state));

    try harness.keyDown(.right);
    try std.testing.expectEqual(@as(usize, 1), focusIndex(&harness.app, fixture.menubar_state));

    try harness.keyDown(.right);
    try std.testing.expectEqual(@as(usize, 2), focusIndex(&harness.app, fixture.menubar_state));

    try harness.keyDown(.left);
    try std.testing.expectEqual(@as(usize, 1), focusIndex(&harness.app, fixture.menubar_state));
}

test "menubar Escape closes open menu" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = MenubarFixture{ .harness = &harness };
    fixture.menubar_state = try harness.app.new(MenubarState, .{});
    fixture.menu_state = try harness.app.new(MenuState, .{});
    try harness.setRoot(&fixture, MenubarFixture.render);

    try harness.clickOn("mb-edit");
    try std.testing.expectEqual(@as(?usize, 1), openIndex(&harness.app, fixture.menubar_state));

    try harness.keyDown(.escape);
    try std.testing.expect(openIndex(&harness.app, fixture.menubar_state) == null);
    try std.testing.expect(!harness.app.read(MenuState, fixture.menu_state).open);
}

test "menubar trigger toggles menu closed" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = MenubarFixture{ .harness = &harness };
    fixture.menubar_state = try harness.app.new(MenubarState, .{});
    fixture.menu_state = try harness.app.new(MenuState, .{});
    try harness.setRoot(&fixture, MenubarFixture.render);

    try harness.clickOn("mb-view");
    try std.testing.expect(isMenuOpen(&harness.app, fixture.menubar_state, 2));

    try harness.clickOn("mb-view");
    try std.testing.expect(openIndex(&harness.app, fixture.menubar_state) == null);
}
