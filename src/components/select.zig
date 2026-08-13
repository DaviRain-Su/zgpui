//! Headless select: dropdown list with controlled/uncontrolled selected index,
//! overlay panel, keyboard navigation (Up/Down, Enter), and click-to-select.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const overlay_mod = @import("../overlay.zig");
const value_mod = @import("../value.zig");
const color = @import("../color.zig");
const geometry = @import("../geometry.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Rgba = color.Rgba;
const Pixels = geometry.Pixels;
const Bounds = geometry.Bounds;
const Size = geometry.Size;

pub const Value = value_mod.Value(usize);

pub const SelectState = struct {
    open: bool = false,
    highlighted_index: i32 = -1,

    pub fn openSelect(self: *SelectState, highlight: i32) void {
        self.open = true;
        self.highlighted_index = highlight;
    }

    pub fn close(self: *SelectState) void {
        self.open = false;
        self.highlighted_index = -1;
    }
};

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, index: usize) void,
};

pub const ItemStyleState = struct {
    selected: bool = false,
    highlighted: bool = false,
    hovered: bool = false,
    disabled: bool = false,
};

pub const ItemStyleFn = *const fn (state: ItemStyleState) style_mod.Style;
pub const StyleFn = *const fn (open: bool) style_mod.Style;
pub const ContentFn = *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator, registry: *SelectRegistry) anyerror!*Div;

pub const SelectRegistry = struct {
    entries: std.ArrayList(Entry),

    pub const Entry = struct {
        index: usize,
        disabled: bool,
    };

    pub fn init() SelectRegistry {
        return .{ .entries = .empty };
    }

    pub fn register(self: *SelectRegistry, arena: std.mem.Allocator, entry: Entry) !void {
        try self.entries.append(arena, entry);
    }

    pub fn isDisabled(self: *const SelectRegistry, index: usize) bool {
        for (self.entries.items) |entry| {
            if (entry.index == index) return entry.disabled;
        }
        return false;
    }
};

pub fn selectedIndex(app: *App, value: Value) usize {
    return value.get(app);
}

pub fn isSelected(app: *App, value: Value, index: usize) bool {
    return selectedIndex(app, value) == index;
}

pub fn selectIndex(app: *App, value: Value, index: usize, on_change: ?ChangeHandler) void {
    const current = value.get(app);
    if (current == index) return;
    value.set(app, index);
    if (on_change) |handler| handler.func(handler.ctx, index);
}

pub fn highlightedIndex(app: *App, state: app_mod.Entity(SelectState)) i32 {
    return app.read(SelectState, state).highlighted_index;
}

pub fn isHighlighted(app: *App, state: app_mod.Entity(SelectState), index: usize) bool {
    return highlightedIndex(app, state) == @as(i32, @intCast(index));
}

fn setHighlighted(app: *App, state: app_mod.Entity(SelectState), index: i32) void {
    app.read(SelectState, state).highlighted_index = index;
    app.notify(state.id);
}

fn moveHighlight(app: *App, state: app_mod.Entity(SelectState), registry: *const SelectRegistry, item_count: usize, delta: i32) void {
    if (item_count == 0) return;
    var idx = highlightedIndex(app, state);
    if (idx < 0) idx = 0;

    var attempts: usize = 0;
    while (attempts < item_count) : (attempts += 1) {
        var next = idx + delta;
        while (next < 0) next += @as(i32, @intCast(item_count));
        while (next >= @as(i32, @intCast(item_count))) next -= @as(i32, @intCast(item_count));
        idx = next;

        if (!registry.isDisabled(@intCast(idx))) {
            setHighlighted(app, state, idx);
            return;
        }
    }
}

pub fn close(app: *App, state: app_mod.Entity(SelectState)) void {
    app.read(SelectState, state).close();
    app.notify(state.id);
}

pub fn open(app: *App, state: app_mod.Entity(SelectState), value: Value) void {
    const highlight = @as(i32, @intCast(selectedIndex(app, value)));
    app.read(SelectState, state).openSelect(highlight);
    app.notify(state.id);
}

pub fn toggle(app: *App, state: app_mod.Entity(SelectState), value: Value) void {
    const s = app.read(SelectState, state);
    if (s.open) {
        s.close();
    } else {
        s.openSelect(@intCast(selectedIndex(app, value)));
    }
    app.notify(state.id);
}

// ---------------------------------------------------------------------------
// List (keyboard navigation)
// ---------------------------------------------------------------------------

pub const ListProps = struct {
    id: []const u8,
    state: app_mod.Entity(SelectState),
    value: Value,
    app: *App,
    item_count: usize,
    registry: *SelectRegistry,
    on_change: ?ChangeHandler = null,
};

const ListNav = struct {
    app: *App,
    state: app_mod.Entity(SelectState),
    value: Value,
    item_count: usize,
    registry: *SelectRegistry,
    on_change: ?ChangeHandler,

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
                const index: usize = @intCast(idx);
                if (self.registry.isDisabled(index)) return false;
                selectIndex(self.app, self.value, index, self.on_change);
                close(self.app, self.state);
                return true;
            },
            else => return false,
        }
    }
};

/// Focusable select list container; handles Up/Down and Enter/Space.
pub fn selectList(arena: std.mem.Allocator, props: ListProps) *Div {
    const focus_id: element.FocusId = element.elementId(props.id);

    const nav = arena.create(ListNav) catch @panic("frame arena OOM");
    nav.* = .{
        .app = props.app,
        .state = props.state,
        .value = props.value,
        .item_count = props.item_count,
        .registry = props.registry,
        .on_change = props.on_change,
    };

    return div_mod.div(arena)
        .withId(props.id)
        .flexCol()
        .role(.list)
        .a11yExpanded(true)
        .focusable(focus_id, .{ .ctx = nav, .func = ListNav.onKey });
}

// ---------------------------------------------------------------------------
// Item
// ---------------------------------------------------------------------------

pub const ItemProps = struct {
    id: []const u8,
    state: app_mod.Entity(SelectState),
    value: Value,
    app: *App,
    index: usize,
    disabled: bool = false,
    on_change: ?ChangeHandler = null,
    style_fn: ?ItemStyleFn = null,
    registry: *SelectRegistry,
};

const ItemSelect = struct {
    app: *App,
    state: app_mod.Entity(SelectState),
    value: Value,
    index: usize,
    on_change: ?ChangeHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *ItemSelect = @ptrCast(@alignCast(ctx.?));
        setHighlighted(self.app, self.state, @intCast(self.index));
        selectIndex(self.app, self.value, self.index, self.on_change);
        close(self.app, self.state);
    }
};

pub fn selectItem(arena: std.mem.Allocator, input: *const element.InputState, props: ItemProps) !*Div {
    const id = element.elementId(props.id);

    props.registry.register(arena, .{
        .index = props.index,
        .disabled = props.disabled,
    }) catch @panic("frame arena OOM");

    const item_state = ItemStyleState{
        .selected = isSelected(props.app, props.value, props.index),
        .highlighted = isHighlighted(props.app, props.state, props.index),
        .hovered = input.isHovered(id),
        .disabled = props.disabled,
    };

    var d = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.list_item)
        .a11ySelected(item_state.selected);
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
        else if (item_state.selected)
            Rgba.fromHex(0xdbeafe)
        else if (item_state.hovered)
            Rgba.fromHex(0xf3f4f6)
        else
            Rgba.fromHex(0xffffff);
        d = d.withStyle(s);
    }

    if (!props.disabled) {
        const select_ctx = arena.create(ItemSelect) catch @panic("frame arena OOM");
        select_ctx.* = .{
            .app = props.app,
            .state = props.state,
            .value = props.value,
            .index = props.index,
            .on_change = props.on_change,
        };
        d = d.onClick(select_ctx, ItemSelect.onClick);
    }

    return d;
}

// ---------------------------------------------------------------------------
// Overlay host
// ---------------------------------------------------------------------------

pub const Props = struct {
    id: []const u8,
    trigger_id: []const u8,
    state: app_mod.Entity(SelectState),
    value: Value,
    overlays: *overlay_mod.OverlayStack,
    app: *App,
    frame: *const element.FrameState,
    input: *element.InputState,
    viewport: Size(Pixels),
    list_id: []const u8,
    z_index: i32 = 65,
    trap_focus: bool = true,
    modal: bool = true,
    on_change: ?ChangeHandler = null,
    panel_style: ?StyleFn = null,
    content_ctx: ?*anyopaque = null,
    content_fn: ?ContentFn = null,
};

const Host = struct {
    app: *App,
    state: app_mod.Entity(SelectState),
    frame: *const element.FrameState,
    viewport: Size(Pixels),
    trigger_id: []const u8,
    panel_style: ?StyleFn,
    panel_id: []const u8,
    content_ctx: ?*anyopaque,
    content_fn: ?ContentFn,

    fn dismiss(ctx: ?*anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        close(self.app, self.state);
    }

    fn dismissMouseDown(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        dismiss(ctx);
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!element.Element {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        const select_state = self.app.read(SelectState, self.state);
        if (!select_state.open) return div_mod.div(arena).sizePx(0, 0).any();

        var backdrop = div_mod.div(arena)
            .withId("select-backdrop")
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
            const registry = arena.create(SelectRegistry) catch @panic("frame arena OOM");
            registry.* = SelectRegistry.init();
            const body = try content_fn(self.content_ctx, arena, registry);
            panel = panel.childDiv(body);
        }

        if (triggerBounds(self.frame, self.trigger_id)) |bounds| {
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
    state: app_mod.Entity(SelectState),
    value: Value,
    input: *element.InputState,
    list_id: []const u8,

    fn toggle(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *TriggerHost = @ptrCast(@alignCast(ctx.?));
        const s = self.app.read(SelectState, self.state);
        if (s.open) {
            s.close();
        } else {
            s.openSelect(@intCast(selectedIndex(self.app, self.value)));
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
    const is_open = props.app.read(SelectState, props.state).open;
    if (!is_open) return;

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

/// Zero-size main-tree placeholder; registers the select overlay when open.
pub fn select(arena: std.mem.Allocator, props: Props) !*Div {
    try registerOverlay(arena, props);
    return div_mod.div(arena).sizePx(0, 0);
}

/// Wire a click-to-toggle trigger and register the overlay when open.
pub fn selectWithTrigger(
    arena: std.mem.Allocator,
    props: Props,
    trigger: *Div,
) !*Div {
    const trigger_host = arena.create(TriggerHost) catch @panic("frame arena OOM");
    trigger_host.* = .{
        .app = props.app,
        .state = props.state,
        .value = props.value,
        .input = props.input,
        .list_id = props.list_id,
    };
    _ = trigger.onClick(trigger_host, TriggerHost.toggle);
    if (trigger.a11y_role == null) _ = trigger.role(.button);
    const is_open = props.app.read(SelectState, props.state).open;
    _ = trigger.a11yExpanded(is_open);

    try registerOverlay(arena, props);
    return trigger;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

const SelectFixture = struct {
    harness: *testing_mod.Harness = undefined,
    select_state: app_mod.Entity(SelectState) = undefined,
    value_entity: app_mod.Entity(Value.Store) = undefined,
    controlled_index: ?usize = null,
    change_log: std.ArrayList(usize) = .empty,

    const item_count = 3;

    fn deinit(self: *SelectFixture) void {
        self.change_log.deinit(std.testing.allocator);
    }

    fn onChange(ctx: ?*anyopaque, index: usize) void {
        const self: *SelectFixture = @ptrCast(@alignCast(ctx.?));
        self.change_log.append(std.testing.allocator, index) catch unreachable;
    }

    fn currentValue(self: *SelectFixture) Value {
        return if (self.controlled_index) |index|
            .{ .controlled = index }
        else
            .{ .uncontrolled = self.value_entity };
    }

    fn itemStyle(state: ItemStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 160 };
        s.height = .{ .px = 28 };
        s.background = if (state.highlighted) Rgba.fromHex(0xbfdbfe) else Rgba.fromHex(0xffffff);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *SelectFixture = @ptrCast(@alignCast(ctx.?));
        const app = &harness.app;
        const value = self.currentValue();

        var trigger = div_mod.div(arena)
            .withId("select-trigger")
            .sizePx(120, 30)
            .bg(Rgba.fromHex(0x336699));
        trigger = try selectWithTrigger(arena, .{
            .id = "fruit-select",
            .trigger_id = "select-trigger",
            .state = self.select_state,
            .value = value,
            .overlays = &harness.overlays,
            .app = app,
            .frame = &harness.frame,
            .input = &harness.input,
            .viewport = harness.viewport,
            .list_id = "select-list",
            .on_change = .{ .ctx = self, .func = onChange },
            .content_ctx = self,
            .content_fn = buildList,
        }, trigger);

        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(trigger).any();
    }

    fn buildList(ctx: ?*anyopaque, arena: std.mem.Allocator, registry: *SelectRegistry) !*Div {
        const self: *SelectFixture = @ptrCast(@alignCast(ctx.?));
        const app = &self.harness.app;
        const value = self.currentValue();

        var list = selectList(arena, .{
            .id = "select-list",
            .state = self.select_state,
            .value = value,
            .app = app,
            .item_count = item_count,
            .registry = registry,
            .on_change = .{ .ctx = self, .func = onChange },
        });

        const names = [_][]const u8{ "select-item-0", "select-item-1", "select-item-2" };
        for (names, 0..) |name, i| {
            list = list.childDiv(try selectItem(arena, &self.harness.input, .{
                .id = name,
                .state = self.select_state,
                .value = value,
                .app = app,
                .index = i,
                .on_change = .{ .ctx = self, .func = onChange },
                .style_fn = itemStyle,
                .registry = registry,
            }));
        }
        return list;
    }
};

test "select opens via trigger" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = SelectFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.select_state = try harness.app.new(SelectState, .{});
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = 0 });
    try harness.setRoot(&fixture, SelectFixture.render);

    try std.testing.expect(!harness.app.read(SelectState, fixture.select_state).open);
    try harness.clickOn("select-trigger");
    try std.testing.expect(harness.app.read(SelectState, fixture.select_state).open);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);
}

test "select item click selects and closes" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = SelectFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.select_state = try harness.app.new(SelectState, .{});
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = 0 });
    try harness.setRoot(&fixture, SelectFixture.render);

    try harness.clickOn("select-trigger");
    try harness.clickOn("select-item-2");
    try std.testing.expect(!harness.app.read(SelectState, fixture.select_state).open);
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(&harness.app, fixture.currentValue()));
    try std.testing.expectEqualSlices(usize, &.{2}, fixture.change_log.items);
}

test "select closes via Escape" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = SelectFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.select_state = try harness.app.new(SelectState, .{});
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = 0 });
    try harness.setRoot(&fixture, SelectFixture.render);

    try harness.clickOn("select-trigger");
    try std.testing.expect(harness.app.read(SelectState, fixture.select_state).open);
    try harness.keyDown(.escape);
    try std.testing.expect(!harness.app.read(SelectState, fixture.select_state).open);
}

test "select arrow keys move highlight and Enter selects" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = SelectFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.select_state = try harness.app.new(SelectState, .{});
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = 0 });
    try harness.setRoot(&fixture, SelectFixture.render);

    try harness.clickOn("select-trigger");
    try harness.focusById(element.elementId("select-list"));

    try std.testing.expectEqual(@as(i32, 0), highlightedIndex(&harness.app, fixture.select_state));
    try harness.keyDown(.down);
    try std.testing.expectEqual(@as(i32, 1), highlightedIndex(&harness.app, fixture.select_state));
    try harness.keyDown(.down);
    try std.testing.expectEqual(@as(i32, 2), highlightedIndex(&harness.app, fixture.select_state));
    try harness.keyDown(.enter);
    try std.testing.expect(!harness.app.read(SelectState, fixture.select_state).open);
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(&harness.app, fixture.currentValue()));
}
