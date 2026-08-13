//! Headless freeform tile canvas: move / resize / z-order for floating panels
//! (gpui-component Tiles geometry contract, without panel registry / history).

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
const Point = geometry.Point;
const Size = geometry.Size;
const Bounds = geometry.Bounds;
const Rgba = color.Rgba;
const a11y_mod = @import("../a11y.zig");

pub const minimum_size: Size(Pixels) = .{ .width = 100, .height = 100 };

pub const Tile = struct {
    id: []const u8,
    bounds: Bounds(Pixels),
    z_index: usize = 0,
};

pub const State = struct {
    /// Active drag / resize bookkeeping (optional UI).
    dragging_id: ?[]const u8 = null,
    drag_grab: Point(Pixels) = .{},
    drag_origin: Point(Pixels) = .{},
    resizing_id: ?[]const u8 = null,
};

/// Clamp a tile size to the minimum, keeping origin.
pub fn clampBounds(bounds: Bounds(Pixels)) Bounds(Pixels) {
    return .{
        .origin = bounds.origin,
        .size = .{
            .width = @max(minimum_size.width, bounds.size.width),
            .height = @max(minimum_size.height, bounds.size.height),
        },
    };
}

/// Move tile so its origin follows `pointer - grab`, then clamp size.
pub fn moveTile(bounds: Bounds(Pixels), pointer: Point(Pixels), grab: Point(Pixels)) Bounds(Pixels) {
    return clampBounds(.{
        .origin = .{
            .x = pointer.x - grab.x,
            .y = pointer.y - grab.y,
        },
        .size = bounds.size,
    });
}

pub const ResizeEdge = enum { left, right, top, bottom, bottom_right };

/// Resize from an edge / corner relative to the bounds at drag start.
pub fn resizeTile(
    initial: Bounds(Pixels),
    edge: ResizeEdge,
    pointer: Point(Pixels),
    start_pointer: Point(Pixels),
) Bounds(Pixels) {
    const dx = pointer.x - start_pointer.x;
    const dy = pointer.y - start_pointer.y;
    var next = initial;

    switch (edge) {
        .left => {
            const new_w = initial.size.width - dx;
            if (new_w >= minimum_size.width) {
                next.origin.x = initial.origin.x + dx;
                next.size.width = new_w;
            } else {
                next.origin.x = initial.right() - minimum_size.width;
                next.size.width = minimum_size.width;
            }
        },
        .right => next.size.width = @max(minimum_size.width, initial.size.width + dx),
        .top => {
            const new_h = initial.size.height - dy;
            if (new_h >= minimum_size.height) {
                next.origin.y = initial.origin.y + dy;
                next.size.height = new_h;
            } else {
                next.origin.y = initial.bottom() - minimum_size.height;
                next.size.height = minimum_size.height;
            }
        },
        .bottom => next.size.height = @max(minimum_size.height, initial.size.height + dy),
        .bottom_right => {
            next.size.width = @max(minimum_size.width, initial.size.width + dx);
            next.size.height = @max(minimum_size.height, initial.size.height + dy);
        },
    }
    return clampBounds(next);
}

/// Highest z_index tile containing `point` (topmost wins).
pub fn hitTest(items: []const Tile, point: Point(Pixels)) ?usize {
    var best: ?usize = null;
    var best_z: usize = 0;
    for (items, 0..) |tile, i| {
        const b = tile.bounds;
        if (point.x < b.origin.x or point.y < b.origin.y) continue;
        if (point.x >= b.right() or point.y >= b.bottom()) continue;
        if (best == null or tile.z_index >= best_z) {
            best = i;
            best_z = tile.z_index;
        }
    }
    return best;
}

/// Raise `index` above every other tile (max z + 1).
pub fn bringToFront(items: []Tile, index: usize) void {
    if (index >= items.len) return;
    var max_z: usize = 0;
    for (items) |t| max_z = @max(max_z, t.z_index);
    items[index].z_index = max_z + 1;
}

pub const TileStyleFn = *const fn (active: bool) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    tiles: []const Tile,
    /// Optional persistent drag state.
    state: ?app_mod.Entity(State) = null,
    app: ?*App = null,
    tile_style_fn: ?TileStyleFn = null,
    active_id: ?[]const u8 = null,
};

/// Render absolute-positioned tiles inside a relative canvas.
pub fn tiles(arena: std.mem.Allocator, props: Props) *Div {
    var canvas = div_mod.div(arena)
        .withId(props.id)
        .wFull()
        .hFull()
        .overflowHidden()
        .role(.group)
        .a11yName("Tiles");

    // Paint low z first so later siblings sit on top visually; hit-test uses z_index.
    var order_buf: [64]usize = undefined;
    const n = @min(props.tiles.len, order_buf.len);
    for (0..n) |i| order_buf[i] = i;
    // Simple insertion sort by z_index ascending.
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const key = order_buf[i];
        var j = i;
        while (j > 0 and props.tiles[order_buf[j - 1]].z_index > props.tiles[key].z_index) : (j -= 1) {
            order_buf[j] = order_buf[j - 1];
        }
        order_buf[j] = key;
    }

    for (order_buf[0..n]) |ti| {
        const tile = props.tiles[ti];
        const active = if (props.active_id) |aid| std.mem.eql(u8, aid, tile.id) else false;
        var panel = div_mod.div(arena)
            .withId(tile.id)
            .absolute()
            .interactive()
            .role(.group)
            .a11ySelected(active)
            .a11yName(tile.id);
        var s = style_mod.Style{};
        s.position = .absolute;
        s.inset.top = .{ .px = tile.bounds.origin.y };
        s.inset.left = .{ .px = tile.bounds.origin.x };
        s.width = .{ .px = tile.bounds.size.width };
        s.height = .{ .px = tile.bounds.size.height };
        if (props.tile_style_fn) |style_fn| {
            var styled = style_fn(active);
            styled.position = .absolute;
            styled.inset = s.inset;
            styled.width = s.width;
            styled.height = s.height;
            panel = panel.withStyle(styled);
        } else {
            s.background = if (active) Rgba.fromHex(0xbfdbfe) else Rgba.fromHex(0xe2e8f0);
            panel = panel.withStyle(s);
        }
        canvas = canvas.childDiv(panel);
    }
    return canvas;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

test "clampBounds enforces minimum size" {
    const b = clampBounds(.{
        .origin = .{ .x = 10, .y = 20 },
        .size = .{ .width = 40, .height = 50 },
    });
    try std.testing.expectEqual(minimum_size.width, b.size.width);
    try std.testing.expectEqual(minimum_size.height, b.size.height);
    try std.testing.expectEqual(@as(Pixels, 10), b.origin.x);
}

test "moveTile and resizeTile" {
    const start = Bounds(Pixels).init(.{ .x = 100, .y = 100 }, .{ .width = 200, .height = 150 });
    const moved = moveTile(start, .{ .x = 130, .y = 140 }, .{ .x = 20, .y = 30 });
    try std.testing.expectEqual(@as(Pixels, 110), moved.origin.x);
    try std.testing.expectEqual(@as(Pixels, 110), moved.origin.y);

    const grown = resizeTile(start, .bottom_right, .{ .x = 320, .y = 270 }, .{ .x = 300, .y = 250 });
    try std.testing.expectEqual(@as(Pixels, 220), grown.size.width);
    try std.testing.expectEqual(@as(Pixels, 170), grown.size.height);

    const shrunk = resizeTile(start, .left, .{ .x = 250, .y = 100 }, .{ .x = 100, .y = 100 });
    try std.testing.expectEqual(minimum_size.width, shrunk.size.width);
}

test "hitTest prefers higher z_index" {
    const tiles_arr = [_]Tile{
        .{ .id = "a", .bounds = Bounds(Pixels).init(.{ .x = 0, .y = 0 }, .{ .width = 100, .height = 100 }), .z_index = 1 },
        .{ .id = "b", .bounds = Bounds(Pixels).init(.{ .x = 50, .y = 50 }, .{ .width = 100, .height = 100 }), .z_index = 2 },
    };
    const ix = hitTest(&tiles_arr, .{ .x = 60, .y = 60 }).?;
    try std.testing.expectEqual(@as(usize, 1), ix);
    try std.testing.expect(hitTest(&tiles_arr, .{ .x = 10, .y = 10 }).? == 0);
    try std.testing.expect(hitTest(&tiles_arr, .{ .x = 400, .y = 400 }) == null);
}

test "bringToFront raises z_index" {
    var tiles_arr = [_]Tile{
        .{ .id = "a", .bounds = Bounds(Pixels).init(.{}, .{ .width = 100, .height = 100 }), .z_index = 1 },
        .{ .id = "b", .bounds = Bounds(Pixels).init(.{}, .{ .width = 100, .height = 100 }), .z_index = 5 },
    };
    bringToFront(&tiles_arr, 0);
    try std.testing.expectEqual(@as(usize, 6), tiles_arr[0].z_index);
}

test "tiles canvas positions panels" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    const Fixture = struct {
        fn render(_: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
            const items = [_]Tile{
                .{
                    .id = "tile-a",
                    .bounds = Bounds(Pixels).init(.{ .x = 20, .y = 30 }, .{ .width = 120, .height = 100 }),
                    .z_index = 1,
                },
                .{
                    .id = "tile-b",
                    .bounds = Bounds(Pixels).init(.{ .x = 80, .y = 60 }, .{ .width = 120, .height = 100 }),
                    .z_index = 2,
                },
            };
            return div_mod.div(arena).sizePx(400, 300).childDiv(tiles(arena, .{
                .id = "canvas",
                .tiles = &items,
                .active_id = "tile-b",
            })).any();
        }
    };

    var fixture: Fixture = .{};
    try harness.setRoot(&fixture, Fixture.render);
    try std.testing.expectEqual(a11y_mod.Role.group, harness.a11yRole("canvas").?);
    try std.testing.expectEqualStrings("Tiles", harness.a11yName("canvas").?);
    try std.testing.expectEqual(a11y_mod.Role.group, harness.a11yRole("tile-b").?);
    try std.testing.expect(harness.a11yNode("tile-b").?.selected.?);
    try std.testing.expect(!harness.a11yNode("tile-a").?.selected.?);
    const a = harness.hitboxBounds(element.elementId("tile-a")).?;
    try std.testing.expectEqual(@as(Pixels, 20), a.origin.x);
    try std.testing.expectEqual(@as(Pixels, 30), a.origin.y);
    try std.testing.expectEqual(@as(Pixels, 120), a.size.width);
}
