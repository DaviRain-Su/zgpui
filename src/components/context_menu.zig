//! Headless context menu: opens at the pointer on right-click, reusing
//! menu list/items and overlay dismissal (Escape / outside click).

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const overlay_mod = @import("../overlay.zig");
const geometry = @import("../geometry.zig");
const menu_mod = @import("menu.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Point = geometry.Point;
const Pixels = geometry.Pixels;
const Size = geometry.Size;

pub const ContextMenuState = menu_mod.MenuState;

pub const SelectHandler = menu_mod.SelectHandler;
pub const ItemStyleState = menu_mod.ItemStyleState;
pub const ItemStyleFn = menu_mod.ItemStyleFn;
pub const MenuRegistry = menu_mod.MenuRegistry;
pub const ContentFn = menu_mod.ContentFn;

pub const menuList = menu_mod.menuList;
pub const menuItem = menu_mod.menuItem;
pub const close = menu_mod.close;
pub const openAt = menu_mod.openAt;
pub const highlightedIndex = menu_mod.highlightedIndex;
pub const isHighlighted = menu_mod.isHighlighted;

pub const Props = struct {
    id: []const u8,
    state: app_mod.Entity(ContextMenuState),
    overlays: *overlay_mod.OverlayStack,
    app: *App,
    frame: *const element.FrameState,
    input: *element.InputState,
    viewport: Size(Pixels),
    list_id: []const u8,
    z_index: i32 = 75,
    content_ctx: ?*anyopaque = null,
    content_fn: ?ContentFn = null,
};

pub const TargetProps = struct {
    state: app_mod.Entity(ContextMenuState),
    app: *App,
    input: *element.InputState,
    list_id: []const u8,
};

const TargetHost = struct {
    app: *App,
    state: app_mod.Entity(ContextMenuState),
    input: *element.InputState,
    list_id: []const u8,

    fn onMouseDown(ctx: ?*anyopaque, event: *const platform.MouseButtonEvent) void {
        if (event.button != .right) return;
        const self: *TargetHost = @ptrCast(@alignCast(ctx.?));
        openAt(self.app, self.state, event.position);
        self.input.focus(element.elementId(self.list_id));
    }
};

/// Register the context menu overlay when open.
pub fn contextMenu(arena: std.mem.Allocator, props: Props) !*Div {
    return menu_mod.menu(arena, .{
        .id = props.id,
        .state = props.state,
        .overlays = props.overlays,
        .app = props.app,
        .frame = props.frame,
        .input = props.input,
        .viewport = props.viewport,
        .list_id = props.list_id,
        .z_index = props.z_index,
        .content_ctx = props.content_ctx,
        .content_fn = props.content_fn,
    });
}

/// Attach right-click handling to `target` to open the menu at the pointer.
pub fn contextMenuTarget(
    arena: std.mem.Allocator,
    props: TargetProps,
    target: *Div,
) *Div {
    const host = arena.create(TargetHost) catch @panic("frame arena OOM");
    host.* = .{
        .app = props.app,
        .state = props.state,
        .input = props.input,
        .list_id = props.list_id,
    };
    return target.onMouseDown(host, TargetHost.onMouseDown);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const ContextFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(ContextMenuState) = undefined,
    selected: i32 = -1,

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *ContextFixture = @ptrCast(@alignCast(ctx.?));

        var surface = div_mod.div(arena)
            .withId("context-surface")
            .sizePx(300, 200)
            .bg(color.Rgba.fromHex(0xdddddd));
        surface = contextMenuTarget(arena, .{
            .state = self.state,
            .app = &harness.app,
            .input = &harness.input,
            .list_id = "context-list",
        }, surface);

        _ = try contextMenu(arena, .{
            .id = "context-menu",
            .state = self.state,
            .overlays = &harness.overlays,
            .app = &harness.app,
            .frame = &harness.frame,
            .input = &harness.input,
            .viewport = harness.viewport,
            .list_id = "context-list",
            .content_ctx = self,
            .content_fn = buildMenu,
        });

        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(surface).any();
    }

    fn buildMenu(ctx: ?*anyopaque, arena: std.mem.Allocator, registry: *MenuRegistry) !*Div {
        const self: *ContextFixture = @ptrCast(@alignCast(ctx.?));
        const app = &self.harness.app;

        var list = menuList(arena, .{
            .id = "context-list",
            .state = self.state,
            .app = app,
            .item_count = 2,
            .registry = registry,
        });

        list = list.childDiv(try menuItem(arena, &self.harness.input, .{
            .id = "ctx-item-a",
            .state = self.state,
            .app = app,
            .index = 0,
            .on_select = .{ .ctx = self, .func = onSelect },
            .registry = registry,
        }));
        list = list.childDiv(try menuItem(arena, &self.harness.input, .{
            .id = "ctx-item-b",
            .state = self.state,
            .app = app,
            .index = 1,
            .on_select = .{ .ctx = self, .func = onSelect },
            .registry = registry,
        }));
        return list;
    }

    fn onSelect(ctx: ?*anyopaque) void {
        const self: *ContextFixture = @ptrCast(@alignCast(ctx.?));
        self.selected = highlightedIndex(&self.harness.app, self.state);
    }
};

test "context menu opens on right-click" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = ContextFixture{ .harness = &harness };
    fixture.state = try harness.app.new(ContextMenuState, .{});
    try harness.setRoot(&fixture, ContextFixture.render);

    try std.testing.expect(!harness.app.read(ContextMenuState, fixture.state).open);

    const center = harness.centerOf(element.elementId("context-surface")).?;
    try harness.rightClick(center.x, center.y);

    try std.testing.expect(harness.app.read(ContextMenuState, fixture.state).open);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);
    try std.testing.expect(harness.hitboxBounds(element.elementId("context-menu")) != null);
}

test "context menu closes via Escape and outside click" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = ContextFixture{ .harness = &harness };
    fixture.state = try harness.app.new(ContextMenuState, .{});
    try harness.setRoot(&fixture, ContextFixture.render);

    const center = harness.centerOf(element.elementId("context-surface")).?;
    try harness.rightClick(center.x, center.y);
    try std.testing.expect(harness.app.read(ContextMenuState, fixture.state).open);

    try harness.keyDown(.escape);
    try std.testing.expect(!harness.app.read(ContextMenuState, fixture.state).open);

    try harness.rightClick(center.x, center.y);
    try harness.click(5, 5);
    try std.testing.expect(!harness.app.read(ContextMenuState, fixture.state).open);
}

test "context menu item click selects" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = ContextFixture{ .harness = &harness };
    fixture.state = try harness.app.new(ContextMenuState, .{});
    try harness.setRoot(&fixture, ContextFixture.render);

    const center = harness.centerOf(element.elementId("context-surface")).?;
    try harness.rightClick(center.x, center.y);
    try harness.clickOn("ctx-item-b");
    try std.testing.expect(!harness.app.read(ContextMenuState, fixture.state).open);
    try std.testing.expectEqual(@as(i32, 1), fixture.selected);
}
