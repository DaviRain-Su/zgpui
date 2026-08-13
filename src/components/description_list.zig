//! Headless description list: label/value rows with optional separators and
//! column packing (`groupItemRows`, matching gpui-component).

const std = @import("std");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const separator_mod = @import("separator.zig");

const Div = div_mod.Div;

pub const Orientation = enum { horizontal, vertical };

pub const ItemKind = enum { entry, separator };

pub const Item = struct {
    kind: ItemKind = .entry,
    id: []const u8 = "",
    label: []const u8 = "",
    value: []const u8 = "",
    /// Column span for horizontal packing (default 1).
    span: usize = 1,
};

pub const LabelStyleFn = *const fn () style_mod.Style;
pub const ValueStyleFn = *const fn () style_mod.Style;
pub const RowStyleFn = *const fn () style_mod.Style;

pub const Props = struct {
    id: []const u8,
    items: []const Item,
    orientation: Orientation = .horizontal,
    columns: usize = 3,
    bordered: bool = false,
    label_style_fn: ?LabelStyleFn = null,
    value_style_fn: ?ValueStyleFn = null,
    row_style_fn: ?RowStyleFn = null,
};

/// Pack items into rows by `columns` and each entry's `span` (upstream algorithm).
pub fn groupItemRows(allocator: std.mem.Allocator, items: []const Item, columns: usize) ![][]const Item {
    const cols = std.math.clamp(columns, 1, 10);
    var rows: std.ArrayList([]const Item) = .empty;
    errdefer {
        for (rows.items) |row| allocator.free(row);
        rows.deinit(allocator);
    }

    var current: std.ArrayList(Item) = .empty;
    defer current.deinit(allocator);
    var current_span: usize = 0;

    for (items) |item| {
        if (item.kind == .separator) {
            if (current.items.len > 0) {
                try rows.append(allocator, try allocator.dupe(Item, current.items));
                current.clearRetainingCapacity();
                current_span = 0;
            }
            try rows.append(allocator, try allocator.dupe(Item, &[_]Item{item}));
            continue;
        }

        const span = @max(@as(usize, 1), item.span);
        if (current.items.len > 0 and current_span + span > cols) {
            try rows.append(allocator, try allocator.dupe(Item, current.items));
            current.clearRetainingCapacity();
            current_span = 0;
        }
        try current.append(allocator, item);
        current_span += span;
    }

    if (current.items.len > 0) {
        try rows.append(allocator, try allocator.dupe(Item, current.items));
    }

    return try rows.toOwnedSlice(allocator);
}

pub fn freeItemRows(allocator: std.mem.Allocator, rows: [][]const Item) void {
    for (rows) |row| allocator.free(row);
    allocator.free(rows);
}

pub fn descriptionList(arena: std.mem.Allocator, props: Props) !*Div {
    var root = div_mod.div(arena).withId(props.id).flexCol().wFull();

    const rows = try groupItemRows(arena, props.items, props.columns);
    // Rows live in the frame arena — no free needed.

    for (rows, 0..) |row, row_ix| {
        const row_id = std.fmt.allocPrint(arena, "{s}-row-{d}", .{ props.id, row_ix }) catch @panic("frame arena OOM");
        var row_div = div_mod.div(arena).withId(row_id).flexRow().wFull();
        if (props.orientation == .vertical) row_div = row_div.flexCol();
        if (props.row_style_fn) |style_fn| row_div = row_div.withStyle(style_fn());

        for (row) |item| {
            if (item.kind == .separator) {
                row_div = row_div.childDiv(separator_mod.separator(arena, .{
                    .id = if (item.id.len > 0) item.id else std.fmt.allocPrint(arena, "{s}-sep-{d}", .{ props.id, row_ix }) catch @panic("frame arena OOM"),
                    .orientation = .horizontal,
                }));
                continue;
            }

            const entry_id = if (item.id.len > 0)
                item.id
            else
                std.fmt.allocPrint(arena, "{s}-item-{d}", .{ props.id, row_ix }) catch @panic("frame arena OOM");

            var entry = div_mod.div(arena).withId(entry_id).flexRow();
            if (props.orientation == .vertical) entry = entry.flexCol();

            const label_id = std.fmt.allocPrint(arena, "{s}-label", .{entry_id}) catch @panic("frame arena OOM");
            var label = div_mod.div(arena).withId(label_id).role(.label).a11yName(item.label);
            if (props.label_style_fn) |style_fn| label = label.withStyle(style_fn());

            const value_id = std.fmt.allocPrint(arena, "{s}-value", .{entry_id}) catch @panic("frame arena OOM");
            var value = div_mod.div(arena).withId(value_id).role(.label).a11yName(item.value);
            if (props.value_style_fn) |style_fn| value = value.withStyle(style_fn());

            entry = entry.childDiv(label).childDiv(value);
            row_div = row_div.childDiv(entry);
        }

        root = root.childDiv(row_div);
    }

    return root;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const element = @import("../element.zig");

test "groupItemRows packs spans like upstream" {
    const items = [_]Item{
        .{ .label = "test1" },
        .{ .label = "test2", .span = 2 },
        .{ .label = "test3" },
        .{ .label = "test4" },
        .{ .label = "test5" },
        .{ .label = "test6", .span = 3 },
        .{ .label = "test7" },
    };
    const rows = try groupItemRows(std.testing.allocator, &items, 3);
    defer freeItemRows(std.testing.allocator, rows);

    try std.testing.expectEqual(@as(usize, 4), rows.len);
    try std.testing.expectEqual(@as(usize, 2), rows[0].len);
    try std.testing.expectEqual(@as(usize, 3), rows[1].len);
    try std.testing.expectEqual(@as(usize, 1), rows[2].len);
    try std.testing.expectEqual(@as(usize, 1), rows[3].len);
}

test "descriptionList renders label a11y names" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 200 });
    defer harness.deinit();

    const Fixture = struct {
        fn labelStyle() style_mod.Style {
            var s = style_mod.Style{};
            s.width = .{ .px = 100 };
            s.height = .{ .px = 24 };
            return s;
        }

        fn valueStyle() style_mod.Style {
            var s = style_mod.Style{};
            s.width = .{ .px = 120 };
            s.height = .{ .px = 24 };
            return s;
        }

        fn render(_: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
            const items = [_]Item{
                .{ .id = "name", .label = "Name", .value = "Ada", .span = 1 },
                .{ .id = "role", .label = "Role", .value = "Engineer", .span = 2 },
            };
            const list = try descriptionList(arena, .{
                .id = "profile",
                .items = &items,
                .columns = 3,
                .label_style_fn = labelStyle,
                .value_style_fn = valueStyle,
            });
            return div_mod.div(arena).sizePx(400, 200).childDiv(list).any();
        }
    };

    var fixture: Fixture = .{};
    try harness.setRoot(&fixture, Fixture.render);
    try std.testing.expectEqualStrings("Name", harness.a11yName("name-label").?);
    try std.testing.expectEqualStrings("Ada", harness.a11yName("name-value").?);
}
