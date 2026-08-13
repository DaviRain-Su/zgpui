//! Headless table (compound parts): `table`, `header`, `row`, `cell`, and
//! optional virtualized `body` reusing list windowing.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const scroll_mod = @import("../elements/scroll.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const value_mod = @import("../value.zig");
const list_mod = @import("list.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const ScrollState = scroll_mod.ScrollState;
const Pixels = @import("../geometry.zig").Pixels;
const a11y_mod = @import("../a11y.zig");

pub const Value = value_mod.Value(usize);

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, index: usize) void,
};

pub const RowStyleState = struct {
    selected: bool = false,
    hovered: bool = false,
    focused_table: bool = false,
};

pub const RowStyleFn = *const fn (state: RowStyleState) style_mod.Style;
pub const CellStyleFn = *const fn () style_mod.Style;

pub fn selectedRow(app: *App, value: Value) usize {
    return value.get(app);
}

pub fn isRowSelected(app: *App, value: Value, index: usize) bool {
    return selectedRow(app, value) == index;
}

fn selectRow(app: *App, value: Value, index: usize, on_change: ?ChangeHandler) void {
    const current = selectedRow(app, value);
    if (current == index) return;
    value.set(app, index);
    if (on_change) |handler| handler.func(handler.ctx, index);
}

// ---------------------------------------------------------------------------
// Compound parts
// ---------------------------------------------------------------------------

pub const TableProps = struct {
    id: []const u8 = "table",
    a11y_label: ?[]const u8 = null,
};

pub fn table(arena: std.mem.Allocator, props: TableProps) *Div {
    var d = div_mod.div(arena)
        .withId(props.id)
        .flexCol()
        .wFull()
        .role(.table);
    if (props.a11y_label) |label| {
        d = d.a11yName(label);
    } else {
        d = d.a11yName("Table");
    }
    return d;
}

pub const HeaderProps = struct {
    id: []const u8 = "table-header",
};

pub fn header(arena: std.mem.Allocator, props: HeaderProps) *Div {
    return div_mod.div(arena)
        .withId(props.id)
        .flexRow()
        .wFull()
        .role(.group)
        .a11yName("Header");
}

pub const CellProps = struct {
    id: ?[]const u8 = null,
    a11y_label: ?[]const u8 = null,
    style_fn: ?CellStyleFn = null,
};

pub fn cell(arena: std.mem.Allocator, props: CellProps) *Div {
    var d = div_mod.div(arena).grow().role(.cell);
    if (props.id) |id| d = d.withId(id).interactive();
    if (props.a11y_label) |label| d = d.a11yName(label);
    if (props.style_fn) |style_fn| d = d.withStyle(style_fn());
    return d;
}

pub const RowProps = struct {
    id: []const u8,
    index: usize,
    table_id: []const u8,
    selected: ?Value = null,
    on_change: ?ChangeHandler = null,
    style_fn: ?RowStyleFn = null,
};

const RowSelect = struct {
    app: *App,
    selected: Value,
    index: usize,
    on_change: ?ChangeHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *RowSelect = @ptrCast(@alignCast(ctx.?));
        selectRow(self.app, self.selected, self.index, self.on_change);
    }
};

pub fn row(arena: std.mem.Allocator, app: *App, input: *const element.InputState, props: RowProps) *Div {
    const id = element.elementId(props.id);
    const selected = if (props.selected) |value| isRowSelected(app, value, props.index) else false;
    const state = RowStyleState{
        .selected = selected,
        .hovered = input.isHovered(id),
        .focused_table = input.isFocused(element.elementId(props.table_id)),
    };

    var d = div_mod.div(arena)
        .withId(props.id)
        .flexRow()
        .wFull()
        .interactive()
        .role(.list_item)
        .a11ySelected(selected);
    if (props.style_fn) |style_fn| d = d.withStyle(style_fn(state));

    if (props.selected) |value| {
        const select_ctx = arena.create(RowSelect) catch @panic("frame arena OOM");
        select_ctx.* = .{
            .app = app,
            .selected = value,
            .index = props.index,
            .on_change = props.on_change,
        };
        d = d.onClick(select_ctx, RowSelect.onClick);
    }

    return d;
}

// ---------------------------------------------------------------------------
// Virtualized body (reuses list windowing)
// ---------------------------------------------------------------------------

pub const RowFn = *const fn (
    ctx: ?*anyopaque,
    arena: std.mem.Allocator,
    index: usize,
    state: list_mod.ItemStyleState,
) anyerror!*Div;

pub const BodyProps = struct {
    app: *App,
    row_count: usize,
    row_height: Pixels,
    viewport_width: Pixels,
    viewport_height: Pixels,
    row_fn: RowFn,
    row_ctx: ?*anyopaque = null,
    scroll_state: ?*ScrollState = null,
    overscan: usize = 2,
};

pub fn body(arena: std.mem.Allocator, input: ?*const element.InputState, props: BodyProps) anyerror!element.Element {
    return list_mod.list(arena, input, .{
        .app = props.app,
        .item_count = props.row_count,
        .item_height = props.row_height,
        .viewport_width = props.viewport_width,
        .viewport_height = props.viewport_height,
        .scroll_state = props.scroll_state,
        .overscan = props.overscan,
        .item_fn = props.row_fn,
        .item_ctx = props.row_ctx,
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");
const Rgba = color.Rgba;

const TableFixture = struct {
    harness: *testing_mod.Harness = undefined,
    selected: app_mod.Entity(Value.Store) = undefined,
    change_log: std.ArrayList(usize) = .empty,

    fn deinit(self: *TableFixture) void {
        self.change_log.deinit(std.testing.allocator);
    }

    fn onChange(ctx: ?*anyopaque, index: usize) void {
        const self: *TableFixture = @ptrCast(@alignCast(ctx.?));
        self.change_log.append(std.testing.allocator, index) catch unreachable;
    }

    fn headerCellStyle() style_mod.Style {
        var s = style_mod.Style{};
        s.flex_grow = 1;
        s.height = .{ .px = 28 };
        s.background = Rgba.fromHex(0x222222);
        return s;
    }

    fn rowStyle(state: RowStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.height = .{ .px = 24 };
        s.background = if (state.selected) Rgba.fromHex(0x555555) else Rgba.fromHex(0x333333);
        return s;
    }

    fn cellStyle() style_mod.Style {
        var s = style_mod.Style{};
        s.flex_grow = 1;
        s.height = .{ .px = 24 };
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *TableFixture = @ptrCast(@alignCast(ctx.?));
        self.harness = harness;
        const app = &harness.app;
        const value: Value = .{ .uncontrolled = self.selected };

        var tbl = table(arena, .{});
        var hdr = header(arena, .{});
        hdr = hdr
            .childDiv(cell(arena, .{ .id = "col-a", .style_fn = headerCellStyle }))
            .childDiv(cell(arena, .{ .id = "col-b", .style_fn = headerCellStyle }));
        tbl = tbl.childDiv(hdr);

        var rows = div_mod.div(arena).flexCol().wFull();
        for (0..4) |i| {
            const id_buf = try std.fmt.allocPrint(arena, "row-{d}", .{i});
            var r = row(arena, app, &harness.input, .{
                .id = id_buf,
                .index = i,
                .table_id = "table",
                .selected = value,
                .on_change = .{ .ctx = self, .func = onChange },
                .style_fn = rowStyle,
            });
            r = r
                .childDiv(cell(arena, .{ .id = "cell-a", .style_fn = cellStyle }))
                .childDiv(cell(arena, .{ .style_fn = cellStyle }));
            rows = rows.childDiv(r);
        }
        tbl = tbl.childDiv(rows);

        return div_mod.div(arena).sizePx(240, 160).childDiv(tbl).any();
    }
};

test "table exposes table row and header a11y roles" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 240, .height = 160 });
    defer harness.deinit();

    var fixture: TableFixture = .{
        .selected = try harness.app.new(Value.Store, .{ .value = 1 }),
    };
    defer fixture.deinit();

    try harness.setRoot(&fixture, TableFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.table, harness.a11yRole("table").?);
    try std.testing.expectEqualStrings("Table", harness.a11yName("table").?);
    try std.testing.expectEqual(a11y_mod.Role.group, harness.a11yRole("table-header").?);
    try std.testing.expectEqual(a11y_mod.Role.cell, harness.a11yRole("col-a").?);
    try std.testing.expectEqual(a11y_mod.Role.list_item, harness.a11yRole("row-0").?);
    try std.testing.expect(!harness.a11yNode("row-0").?.selected.?);
    try std.testing.expect(harness.a11yNode("row-1").?.selected.?);
}

test "table header and rows register hitboxes" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 240, .height = 160 });
    defer harness.deinit();

    var fixture: TableFixture = .{
        .selected = try harness.app.new(Value.Store, .{ .value = 0 }),
    };
    defer fixture.deinit();

    try harness.setRoot(&fixture, TableFixture.render);

    try std.testing.expect(harness.hitboxBounds(element.elementId("col-a")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("col-b")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("row-0")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("row-3")) != null);
}

test "click selects table row" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 240, .height = 160 });
    defer harness.deinit();

    var fixture: TableFixture = .{
        .selected = try harness.app.new(Value.Store, .{ .value = 0 }),
    };
    defer fixture.deinit();

    try harness.setRoot(&fixture, TableFixture.render);
    try harness.clickOn("row-2");

    try std.testing.expectEqual(@as(usize, 2), selectedRow(&harness.app, .{ .uncontrolled = fixture.selected }));
    try std.testing.expectEqual(@as(usize, 1), fixture.change_log.items.len);
    try std.testing.expectEqual(@as(usize, 2), fixture.change_log.items[0]);
}

const VirtualTableFixture = struct {
    harness: *testing_mod.Harness = undefined,
    scroll_state: ScrollState = .{},

    fn rowStyle(_: list_mod.ItemStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.height = .{ .px = 20 };
        s.background = Rgba.fromHex(0x333333);
        return s;
    }

    fn renderRow(ctx: ?*anyopaque, arena: std.mem.Allocator, index: usize, state: list_mod.ItemStyleState) !*Div {
        _ = ctx;
        const id_buf = try std.fmt.allocPrint(arena, "vrow-{d}", .{index});
        return div_mod.div(arena).withId(id_buf).interactive().withStyle(rowStyle(state));
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *VirtualTableFixture = @ptrCast(@alignCast(ctx.?));
        self.harness = harness;

        var tbl = table(arena, .{});
        tbl = tbl.childDiv(header(arena, .{}).childDiv(cell(arena, .{ .id = "vh", .style_fn = headerCellStyle })));
        const body_el = try body(arena, &harness.input, .{
            .app = &harness.app,
            .row_count = 500,
            .row_height = 20,
            .viewport_width = 200,
            .viewport_height = 100,
            .scroll_state = &self.scroll_state,
            .row_fn = renderRow,
            .row_ctx = self,
        });
        tbl = tbl.child(body_el);

        return div_mod.div(arena).sizePx(200, 140).child(tbl.any()).any();
    }

    fn headerCellStyle() style_mod.Style {
        var s = style_mod.Style{};
        s.height = .{ .px = 24 };
        s.background = Rgba.fromHex(0x222222);
        return s;
    }
};

test "virtual table body renders windowed rows" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 140 });
    defer harness.deinit();

    var fixture: VirtualTableFixture = .{};
    try harness.setRoot(&fixture, VirtualTableFixture.render);

    const range = list_mod.visibleRange(0, 20, 100, 500, 2);
    var row_hitboxes: usize = 0;
    for (harness.frame.hitboxes.items) |hb| {
        if (hb.id != null and hb.id.? != element.elementId("vh")) row_hitboxes += 1;
    }
    try std.testing.expectEqual(range.end - range.start, row_hitboxes);
}
