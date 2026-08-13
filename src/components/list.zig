//! Virtualized list: fixed or variable row heights, scroll viewport, optional
//! keyboard selection via `Value(usize)`.
//!
//! Variable-height mode takes a known `item_heights` slice (gpui-base
//! `virtual_list` contract) and only mounts the visible window.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const scroll_mod = @import("../elements/scroll.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const value_mod = @import("../value.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const ScrollState = scroll_mod.ScrollState;
const ScrollView = scroll_mod.ScrollView;
const Pixels = @import("../geometry.zig").Pixels;

pub const Value = value_mod.Value(usize);

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, index: usize) void,
};

pub const ItemStyleState = struct {
    selected: bool = false,
    highlighted: bool = false,
    hovered: bool = false,
};

pub const ItemStyleFn = *const fn (state: ItemStyleState) style_mod.Style;

pub const ItemFn = *const fn (
    ctx: ?*anyopaque,
    arena: std.mem.Allocator,
    index: usize,
    state: ItemStyleState,
) anyerror!*Div;

pub const Props = struct {
    app: *App,
    item_count: usize,
    /// Fixed row height when `item_heights` is null.
    item_height: Pixels = 0,
    /// Per-row heights (length should match `item_count`). When set, overrides
    /// `item_height` for layout and visible-range calculation.
    item_heights: ?[]const Pixels = null,
    viewport_width: Pixels,
    viewport_height: Pixels,
    item_fn: ItemFn,
    item_ctx: ?*anyopaque = null,
    scroll_state: ?*ScrollState = null,
    overscan: usize = 2,
    id: []const u8 = "virtual-list",
    selected: ?Value = null,
    on_change: ?ChangeHandler = null,
    keyboard: bool = false,
};

pub fn selectedIndex(app: *App, value: Value) usize {
    return value.get(app);
}

pub fn isSelected(app: *App, value: Value, index: usize) bool {
    return selectedIndex(app, value) == index;
}

pub fn selectIndex(app: *App, value: Value, index: usize, on_change: ?ChangeHandler) void {
    const current = selectedIndex(app, value);
    if (current == index) return;
    value.set(app, index);
    if (on_change) |handler| handler.func(handler.ctx, index);
}

/// Sum of heights before `index` (top of that row).
pub fn itemTop(heights: []const Pixels, index: usize) Pixels {
    var top: Pixels = 0;
    const n = @min(index, heights.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        top += heights[i];
    }
    return top;
}

pub fn totalHeight(heights: []const Pixels) Pixels {
    var sum: Pixels = 0;
    for (heights) |h| sum += h;
    return sum;
}

pub const IndexRange = struct {
    start: usize,
    end: usize,
};

/// Compute the index range `[start, end)` to render for fixed row height.
pub fn visibleRange(
    offset_y: Pixels,
    item_height: Pixels,
    viewport_height: Pixels,
    item_count: usize,
    overscan: usize,
) IndexRange {
    if (item_count == 0 or item_height <= 0) return .{ .start = 0, .end = 0 };

    const first_visible = @as(usize, @intFromFloat(@floor(offset_y / item_height)));
    const visible = @as(usize, @intFromFloat(@ceil(viewport_height / item_height)));
    const start = if (first_visible > overscan) first_visible - overscan else 0;
    const end = @min(item_count, first_visible + visible + overscan);
    if (end <= start) return .{ .start = 0, .end = 0 };
    return .{ .start = start, .end = end };
}

/// Visible `[start, end)` for variable row heights (gpui-base virtual_list).
pub fn visibleRangeVariable(
    offset_y: Pixels,
    viewport_height: Pixels,
    heights: []const Pixels,
    overscan: usize,
) IndexRange {
    const item_count = heights.len;
    if (item_count == 0 or viewport_height <= 0) return .{ .start = 0, .end = 0 };

    var cum: Pixels = 0;
    var first_visible: usize = item_count;
    for (heights, 0..) |h, i| {
        cum += h;
        if (cum > offset_y) {
            first_visible = i;
            break;
        }
    }
    if (first_visible >= item_count) return .{ .start = 0, .end = 0 };

    const view_bottom = offset_y + viewport_height;
    cum = 0;
    var last_exclusive: usize = item_count;
    for (heights, 0..) |h, i| {
        cum += h;
        if (cum > view_bottom) {
            last_exclusive = i + 1;
            break;
        }
    }

    const start = if (first_visible > overscan) first_visible - overscan else 0;
    const end = @min(item_count, last_exclusive + overscan);
    if (end <= start) return .{ .start = 0, .end = 0 };
    return .{ .start = start, .end = end };
}

pub fn itemStyle(index: usize, item_height: Pixels, width: Pixels) style_mod.Style {
    return itemStyleAt(@as(f32, @floatFromInt(index)) * item_height, item_height, width);
}

pub fn itemStyleAt(top: Pixels, height: Pixels, width: Pixels) style_mod.Style {
    var s = style_mod.Style{};
    s.position = .absolute;
    s.inset.top = .{ .px = top };
    s.inset.left = .{ .px = 0 };
    s.width = .{ .px = width };
    s.height = .{ .px = height };
    return s;
}

fn buildScrollView(arena: std.mem.Allocator, props: *const Props, input: ?*const element.InputState) !*ScrollView {
    const offset_y = if (props.scroll_state) |state| state.offset.y else 0;

    const range: IndexRange = if (props.item_heights) |heights|
        visibleRangeVariable(offset_y, props.viewport_height, heights[0..@min(heights.len, props.item_count)], props.overscan)
    else
        visibleRange(offset_y, props.item_height, props.viewport_height, props.item_count, props.overscan);

    const content_height: Pixels = if (props.item_heights) |heights|
        totalHeight(heights[0..@min(heights.len, props.item_count)])
    else
        @as(Pixels, @floatFromInt(props.item_count)) * props.item_height;

    var content = div_mod.div(arena).wPx(props.viewport_width).hPx(content_height);

    var index = range.start;
    while (index < range.end) : (index += 1) {
        var item_state = ItemStyleState{};
        if (props.selected) |value| {
            item_state.selected = isSelected(props.app, value, index);
            item_state.highlighted = item_state.selected;
        }
        if (input) |inp| {
            const id = try itemId(arena, index);
            item_state.hovered = inp.isHovered(element.elementId(id));
        }

        const row = try props.item_fn(props.item_ctx, arena, index, item_state);
        const style = if (props.item_heights) |heights|
            itemStyleAt(itemTop(heights, index), heights[index], props.viewport_width)
        else
            itemStyle(index, props.item_height, props.viewport_width);
        content = content.childDiv(row.withStyle(style));
    }

    const sv = scroll_mod.scrollView(arena)
        .sizePx(props.viewport_width, props.viewport_height)
        .withApp(props.app)
        .child(content.any());

    if (props.scroll_state) |state| _ = sv.bindState(state);
    return sv;
}

const ListNav = struct {
    app: *App,
    value: Value,
    item_count: usize,
    on_change: ?ChangeHandler,

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *ListNav = @ptrCast(@alignCast(ctx.?));
        if (self.item_count == 0) return false;
        const current = selectedIndex(self.app, self.value);
        const next: usize = switch (event.key) {
            .down => @min(current + 1, self.item_count - 1),
            .up => if (current > 0) current - 1 else 0,
            .home => 0,
            .end => self.item_count - 1,
            else => return false,
        };
        selectIndex(self.app, self.value, next, self.on_change);
        return true;
    }
};

/// Virtualized scroll list. When `keyboard` is true, `selected` must be set.
pub fn list(arena: std.mem.Allocator, input: ?*const element.InputState, props: Props) anyerror!element.Element {
    var props_mut = props;
    const sv = try buildScrollView(arena, &props_mut, input);

    if (props.keyboard and props.selected != null) {
        const focus_id: element.FocusId = element.elementId(props.id);
        const nav = arena.create(ListNav) catch @panic("frame arena OOM");
        nav.* = .{
            .app = props.app,
            .value = props.selected.?,
            .item_count = props.item_count,
            .on_change = props.on_change,
        };
        return div_mod.div(arena)
            .withId(props.id)
            .focusable(focus_id, .{ .ctx = nav, .func = ListNav.onKey })
            .child(sv.any())
            .any();
    }

    return sv.any();
}

// ---------------------------------------------------------------------------
// Selectable row helper
// ---------------------------------------------------------------------------

pub const ItemProps = struct {
    id: []const u8,
    index: usize,
    selected: Value,
    list_id: []const u8,
    on_change: ?ChangeHandler = null,
    style_fn: ?ItemStyleFn = null,
};

const ItemSelect = struct {
    app: *App,
    selected: Value,
    index: usize,
    on_change: ?ChangeHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *ItemSelect = @ptrCast(@alignCast(ctx.?));
        selectIndex(self.app, self.selected, self.index, self.on_change);
    }
};

pub fn item(
    arena: std.mem.Allocator,
    app: *App,
    input: *const element.InputState,
    props: ItemProps,
) *Div {
    const id = element.elementId(props.id);
    const state = ItemStyleState{
        .selected = isSelected(app, props.selected, props.index),
        .highlighted = isSelected(app, props.selected, props.index),
        .hovered = input.isHovered(id),
    };

    var d = div_mod.div(arena).withId(props.id).interactive();
    if (props.style_fn) |style_fn| d = d.withStyle(style_fn(state));

    const select_ctx = arena.create(ItemSelect) catch @panic("frame arena OOM");
    select_ctx.* = .{
        .app = app,
        .selected = props.selected,
        .index = props.index,
        .on_change = props.on_change,
    };
    _ = props.list_id;
    return d.onClick(select_ctx, ItemSelect.onClick);
}

fn itemId(arena: std.mem.Allocator, index: usize) ![]const u8 {
    return std.fmt.allocPrint(arena, "list-item-{d}", .{index}) catch @panic("frame arena OOM");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");
const Rgba = color.Rgba;

const ListFixture = struct {
    harness: *testing_mod.Harness = undefined,
    scroll_state: ScrollState = .{},
    selected: app_mod.Entity(Value.Store) = undefined,
    item_count: usize = 1000,
    change_log: std.ArrayList(usize) = .empty,

    fn deinit(self: *ListFixture) void {
        self.change_log.deinit(std.testing.allocator);
    }

    fn onChange(ctx: ?*anyopaque, index: usize) void {
        const self: *ListFixture = @ptrCast(@alignCast(ctx.?));
        self.change_log.append(std.testing.allocator, index) catch unreachable;
    }

    fn fixtureItemStyle(state: ItemStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 200 };
        s.height = .{ .px = 20 };
        s.background = if (state.selected) Rgba.fromHex(0xffffff) else Rgba.fromHex(0x333333);
        return s;
    }

    fn renderItem(ctx: ?*anyopaque, arena: std.mem.Allocator, index: usize, _: ItemStyleState) !*Div {
        const self: *ListFixture = @ptrCast(@alignCast(ctx.?));
        const id_buf = try itemId(arena, index);
        const value: Value = .{ .uncontrolled = self.selected };
        return item(arena, &self.harness.app, &self.harness.input, .{
            .id = id_buf,
            .index = index,
            .selected = value,
            .list_id = "list",
            .on_change = .{ .ctx = self, .func = onChange },
            .style_fn = fixtureItemStyle,
        });
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *ListFixture = @ptrCast(@alignCast(ctx.?));
        self.harness = harness;
        return list(arena, &harness.input, .{
            .app = &harness.app,
            .item_count = self.item_count,
            .item_height = 20,
            .viewport_width = 200,
            .viewport_height = 200,
            .scroll_state = &self.scroll_state,
            .item_fn = renderItem,
            .item_ctx = self,
            .id = "list",
            .selected = .{ .uncontrolled = self.selected },
            .on_change = .{ .ctx = self, .func = onChange },
            .keyboard = true,
        });
    }
};

fn countItemHitboxes(harness: *const testing_mod.Harness) usize {
    var count: usize = 0;
    for (harness.frame.hitboxes.items) |hb| {
        if (hb.id != null) count += 1;
    }
    return count;
}

test "virtual list renders only visible window of items" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 200 });
    defer harness.deinit();

    var fixture: ListFixture = .{
        .selected = try harness.app.new(Value.Store, .{ .value = 0 }),
    };
    defer fixture.deinit();

    try harness.setRoot(&fixture, ListFixture.render);

    const range = visibleRange(0, 20, 200, fixture.item_count, 2);
    const expected = range.end - range.start;
    try std.testing.expect(expected < 20);
    try std.testing.expectEqual(expected, countItemHitboxes(&harness));
}

test "scroll offset changes rendered item range" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 200 });
    defer harness.deinit();

    var fixture: ListFixture = .{
        .selected = try harness.app.new(Value.Store, .{ .value = 0 }),
    };
    defer fixture.deinit();

    try harness.setRoot(&fixture, ListFixture.render);

    try std.testing.expect(harness.hitboxBounds(element.elementId("list-item-0")) != null);

    fixture.scroll_state.offset = .{ .x = 0, .y = 400 };
    try harness.renderFrame();

    try std.testing.expect(harness.hitboxBounds(element.elementId("list-item-0")) == null);

    const range = visibleRange(400, 20, 200, fixture.item_count, 2);
    var rendered: usize = 0;
    for (harness.frame.hitboxes.items) |hb| {
        if (hb.id != null) rendered += 1;
    }
    try std.testing.expectEqual(range.end - range.start, rendered);
    try std.testing.expect(harness.hitboxBounds(element.elementId("list-item-20")) != null);
}

test "click selects list item" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 200 });
    defer harness.deinit();

    var fixture: ListFixture = .{
        .selected = try harness.app.new(Value.Store, .{ .value = 0 }),
    };
    defer fixture.deinit();

    try harness.setRoot(&fixture, ListFixture.render);
    try harness.clickOn("list-item-3");

    try std.testing.expectEqual(@as(usize, 3), selectedIndex(&harness.app, .{ .uncontrolled = fixture.selected }));
    try std.testing.expectEqual(@as(usize, 1), fixture.change_log.items.len);
    try std.testing.expectEqual(@as(usize, 3), fixture.change_log.items[0]);
}

test "keyboard up down changes selection" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 200 });
    defer harness.deinit();

    var fixture: ListFixture = .{
        .selected = try harness.app.new(Value.Store, .{ .value = 2 }),
    };
    defer fixture.deinit();

    try harness.setRoot(&fixture, ListFixture.render);
    try harness.focusById(element.elementId("list"));
    try harness.keyDown(.down);
    try std.testing.expectEqual(@as(usize, 3), selectedIndex(&harness.app, .{ .uncontrolled = fixture.selected }));
    try harness.keyDown(.up);
    try std.testing.expectEqual(@as(usize, 2), selectedIndex(&harness.app, .{ .uncontrolled = fixture.selected }));
}

test "visibleRange matches spec" {
    const range = visibleRange(0, 20, 200, 1000, 2);
    try std.testing.expectEqual(@as(usize, 0), range.start);
    try std.testing.expectEqual(@as(usize, 12), range.end);

    const scrolled = visibleRange(200, 20, 200, 1000, 2);
    try std.testing.expectEqual(@as(usize, 8), scrolled.start);
    try std.testing.expectEqual(@as(usize, 22), scrolled.end);
}

test "visibleRangeVariable and itemTop for mixed heights" {
    const heights = [_]Pixels{ 20, 40, 20, 60, 20, 40, 20, 40, 20, 40 };
    try std.testing.expectEqual(@as(Pixels, 0), itemTop(&heights, 0));
    try std.testing.expectEqual(@as(Pixels, 20), itemTop(&heights, 1));
    try std.testing.expectEqual(@as(Pixels, 60), itemTop(&heights, 2));
    try std.testing.expectEqual(@as(Pixels, 320), totalHeight(&heights));

    const top = visibleRangeVariable(0, 100, &heights, 0);
    try std.testing.expectEqual(@as(usize, 0), top.start);
    // 20+40+20+60 = 140 > 100 → last exclusive 4
    try std.testing.expectEqual(@as(usize, 4), top.end);

    // offset past first two rows (20+40=60)
    const mid = visibleRangeVariable(60, 100, &heights, 1);
    try std.testing.expectEqual(@as(usize, 1), mid.start); // first visible is 2, overscan 1 → 1
    try std.testing.expect(mid.end > mid.start);
}

test "variable-height list renders only visible window" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 200 });
    defer harness.deinit();

    var heights: [200]Pixels = undefined;
    for (&heights, 0..) |*h, i| {
        h.* = if (i % 2 == 0) 20 else 40;
    }

    const VarFixture = struct {
        harness: *testing_mod.Harness = undefined,
        scroll_state: ScrollState = .{},
        selected: app_mod.Entity(Value.Store) = undefined,
        heights: []const Pixels = undefined,

        fn renderItem(ctx: ?*anyopaque, arena: std.mem.Allocator, index: usize, _: ItemStyleState) !*Div {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const id_buf = try itemId(arena, index);
            const h = self.heights[index];
            return div_mod.div(arena)
                .withId(id_buf)
                .sizePx(200, h)
                .bg(Rgba.fromHex(0x336699))
                .interactive();
        }

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness_inner: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.harness = harness_inner;
            return list(arena, &harness_inner.input, .{
                .app = &harness_inner.app,
                .item_count = self.heights.len,
                .item_heights = self.heights,
                .viewport_width = 200,
                .viewport_height = 200,
                .scroll_state = &self.scroll_state,
                .item_fn = renderItem,
                .item_ctx = self,
                .id = "var-list",
                .overscan = 1,
            });
        }
    };

    var fixture: VarFixture = .{
        .selected = try harness.app.new(Value.Store, .{ .value = 0 }),
        .heights = &heights,
    };
    try harness.setRoot(&fixture, VarFixture.render);

    const range = visibleRangeVariable(0, 200, &heights, 1);
    try std.testing.expect(range.end - range.start < heights.len);
    try std.testing.expectEqual(range.end - range.start, countItemHitboxes(&harness));
    try std.testing.expect(harness.hitboxBounds(element.elementId("list-item-0")) != null);

    const first = harness.hitboxBounds(element.elementId("list-item-0")).?;
    try std.testing.expectEqual(@as(Pixels, 20), first.size.height);
    const second = harness.hitboxBounds(element.elementId("list-item-1")).?;
    try std.testing.expectEqual(@as(Pixels, 40), second.size.height);
    try std.testing.expectApproxEqAbs(@as(Pixels, 20), second.origin.y - first.origin.y, 0.5);

    // Scroll deep enough that early items leave the window.
    fixture.scroll_state.offset = .{ .x = 0, .y = 600 };
    try harness.renderFrame();
    try std.testing.expect(harness.hitboxBounds(element.elementId("list-item-0")) == null);

    const scrolled = visibleRangeVariable(600, 200, &heights, 1);
    try std.testing.expectEqual(scrolled.end - scrolled.start, countItemHitboxes(&harness));
    var id_buf: [64]u8 = undefined;
    const id_name = try std.fmt.bufPrint(&id_buf, "list-item-{d}", .{scrolled.start});
    try std.testing.expect(harness.hitboxBounds(element.elementId(id_name)) != null);
}
