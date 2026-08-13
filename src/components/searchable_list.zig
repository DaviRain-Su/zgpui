//! Headless searchable list: query filter + virtualized matched rows.
//!
//! Contract aligned with gpui-component `SearchableList` / `SearchableVec`:
//! case-insensitive title (and optional keywords) matching, then only the
//! matched window is rendered. Default match mode is substring (upstream);
//! `subsequence` reuses the combobox fuzzy path.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const list_mod = @import("list.zig");
const combobox_mod = @import("combobox.zig");
const scroll_mod = @import("../elements/scroll.zig");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Pixels = geometry.Pixels;
const Rgba = color.Rgba;
const ScrollState = scroll_mod.ScrollState;

pub const filter_capacity = 128;

/// How query text is compared to item labels.
pub const MatchMode = enum {
    /// Case-insensitive substring (gpui-component default `matches`).
    substring,
    /// Ordered subsequence (combobox / command-palette fuzzy).
    subsequence,
};

pub const Item = struct {
    id: []const u8,
    label: []const u8,
    disabled: bool = false,
    keywords: ?[]const u8 = null,
};

pub const State = struct {
    query_buf: [filter_capacity]u8 = undefined,
    query_len: usize = 0,
    /// Highlight within the *filtered* list (`-1` = none).
    highlighted: i32 = 0,
    /// Last confirmed source index into the full item slice.
    selected_source: ?usize = null,

    pub fn query(self: *const State) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    pub fn setQuery(self: *State, text: []const u8) void {
        const len = @min(text.len, filter_capacity);
        @memcpy(self.query_buf[0..len], text[0..len]);
        self.query_len = len;
        self.highlighted = 0;
    }

    pub fn clearQuery(self: *State) void {
        self.query_len = 0;
        self.highlighted = 0;
    }
};

pub const SelectHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, source_index: usize) void,
};

pub const ItemStyleState = struct {
    highlighted: bool = false,
    selected: bool = false,
    hovered: bool = false,
    disabled: bool = false,
};

pub const ItemStyleFn = *const fn (state: ItemStyleState) style_mod.Style;
pub const FilterStyleFn = *const fn () style_mod.Style;

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

pub fn textMatches(label: []const u8, query: []const u8, mode: MatchMode) bool {
    if (query.len == 0) return true;
    return switch (mode) {
        .substring => containsIgnoreCase(label, query),
        .subsequence => combobox_mod.labelMatchesFilter(label, query),
    };
}

pub fn itemMatches(item: Item, query: []const u8, mode: MatchMode) bool {
    if (textMatches(item.label, query, mode)) return true;
    if (item.keywords) |kw| return textMatches(kw, query, mode);
    return false;
}

/// Collect source indices whose labels/keywords match `query`.
pub fn collectMatches(
    allocator: std.mem.Allocator,
    items: []const Item,
    query: []const u8,
    mode: MatchMode,
) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(allocator);
    for (items, 0..) |item, i| {
        if (itemMatches(item, query, mode)) try out.append(allocator, i);
    }
    return try out.toOwnedSlice(allocator);
}

pub const Props = struct {
    id: []const u8,
    state: app_mod.Entity(State),
    app: *App,
    input: *element.InputState,
    items: []const Item,
    match_mode: MatchMode = .substring,
    item_height: Pixels = 28,
    viewport_width: Pixels = 280,
    viewport_height: Pixels = 200,
    scroll_state: ?*ScrollState = null,
    on_select: ?SelectHandler = null,
    filter_id: []const u8 = "searchable-list-filter",
    list_id: []const u8 = "searchable-list-rows",
    filter_style_fn: ?FilterStyleFn = null,
    item_style_fn: ?ItemStyleFn = null,
    a11y_filter_label: []const u8 = "Filter",
};

fn setQueryAndNotify(app: *App, state: app_mod.Entity(State), text: []const u8) void {
    const s = app.read(State, state);
    s.setQuery(text);
    app.notify(state.id);
}

fn confirmHighlight(
    app: *App,
    state: app_mod.Entity(State),
    matches: []const usize,
    items: []const Item,
    on_select: ?SelectHandler,
) void {
    if (matches.len == 0) return;
    const s = app.read(State, state);
    var hi = s.highlighted;
    if (hi < 0) hi = 0;
    const filtered: usize = @intCast(@min(hi, @as(i32, @intCast(matches.len - 1))));
    const source = matches[filtered];
    if (source >= items.len or items[source].disabled) return;
    s.selected_source = source;
    s.highlighted = @intCast(filtered);
    app.notify(state.id);
    if (on_select) |handler| handler.func(handler.ctx, source);
}

// ---------------------------------------------------------------------------
// Filter field
// ---------------------------------------------------------------------------

const FilterNav = struct {
    app: *App,
    state: app_mod.Entity(State),
    input: *element.InputState,
    list_id: []const u8,

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *FilterNav = @ptrCast(@alignCast(ctx.?));
        const s = self.app.read(State, self.state);
        switch (event.key) {
            .down => {
                self.input.focus(element.elementId(self.list_id));
                return true;
            },
            .backspace => {
                if (s.query_len == 0) return false;
                s.query_len -= 1;
                s.highlighted = 0;
                self.app.notify(self.state.id);
                return true;
            },
            else => return false,
        }
    }

    fn onTextInput(ctx: ?*anyopaque, event: *const platform.TextInputEvent) bool {
        const self: *FilterNav = @ptrCast(@alignCast(ctx.?));
        const s = self.app.read(State, self.state);
        for (event.text) |ch| {
            if (s.query_len >= filter_capacity) break;
            s.query_buf[s.query_len] = ch;
            s.query_len += 1;
        }
        s.highlighted = 0;
        self.app.notify(self.state.id);
        return true;
    }
};

fn buildFilter(arena: std.mem.Allocator, props: *const Props) *Div {
    const query_text = props.app.read(State, props.state).query();
    const nav = arena.create(FilterNav) catch @panic("frame arena OOM");
    nav.* = .{
        .app = props.app,
        .state = props.state,
        .input = props.input,
        .list_id = props.list_id,
    };

    var filter = div_mod.div(arena)
        .withId(props.filter_id)
        .role(.search)
        .a11yName(props.a11y_filter_label)
        .a11yValueText(query_text)
        .focusable(element.elementId(props.filter_id), .{ .ctx = nav, .func = FilterNav.onKey })
        .onTextInput(nav, FilterNav.onTextInput);

    if (props.filter_style_fn) |style_fn| {
        filter = filter.withStyle(style_fn());
    } else {
        var s = style_mod.Style{};
        s.width = .{ .px = props.viewport_width };
        s.height = .{ .px = 32 };
        s.padding = .{
            .top = .{ .px = 6 },
            .right = .{ .px = 10 },
            .bottom = .{ .px = 6 },
            .left = .{ .px = 10 },
        };
        s.background = Rgba.fromHex(0xf9fafb);
        filter = filter.withStyle(s);
    }
    return filter;
}

// ---------------------------------------------------------------------------
// Matched rows (virtual list)
// ---------------------------------------------------------------------------

const RowHost = struct {
    app: *App,
    state: app_mod.Entity(State),
    input: *const element.InputState,
    items: []const Item,
    matches: []const usize,
    on_select: ?SelectHandler,
    item_style_fn: ?ItemStyleFn,
    list_id: []const u8,

    fn renderItem(ctx: ?*anyopaque, arena: std.mem.Allocator, filtered_index: usize, _: list_mod.ItemStyleState) !*Div {
        const self: *RowHost = @ptrCast(@alignCast(ctx.?));
        if (filtered_index >= self.matches.len) {
            return div_mod.div(arena).sizePx(0, 0);
        }
        const source = self.matches[filtered_index];
        const item = self.items[source];
        const st = self.app.read(State, self.state);
        const id_buf = try std.fmt.allocPrint(arena, "{s}-item-{d}", .{ self.list_id, source });

        const style_state = ItemStyleState{
            .highlighted = st.highlighted == @as(i32, @intCast(filtered_index)),
            .selected = st.selected_source == source,
            .hovered = self.input.isHovered(element.elementId(id_buf)),
            .disabled = item.disabled,
        };

        var row = div_mod.div(arena)
            .withId(id_buf)
            .interactive()
            .role(.list_item)
            .a11yName(item.label)
            .a11ySelected(style_state.selected or style_state.highlighted);
        if (propsItemStyle(self, style_state)) |style| row = row.withStyle(style);

        if (!item.disabled) {
            const click = arena.create(RowClick) catch @panic("frame arena OOM");
            click.* = .{
                .app = self.app,
                .state = self.state,
                .source = source,
                .filtered = filtered_index,
                .on_select = self.on_select,
            };
            row = row.onClick(click, RowClick.onClick);
        }
        return row;
    }

    fn propsItemStyle(self: *const RowHost, state: ItemStyleState) ?style_mod.Style {
        if (self.item_style_fn) |style_fn| return style_fn(state);
        var s = style_mod.Style{};
        s.width = .{ .percent = 100 };
        s.height = .{ .px = 28 };
        s.background = if (state.highlighted or state.selected)
            Rgba.fromHex(0xdbeafe)
        else
            Rgba.fromHex(0xffffff);
        return s;
    }
};

const RowClick = struct {
    app: *App,
    state: app_mod.Entity(State),
    source: usize,
    filtered: usize,
    on_select: ?SelectHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *RowClick = @ptrCast(@alignCast(ctx.?));
        const s = self.app.read(State, self.state);
        s.selected_source = self.source;
        s.highlighted = @intCast(self.filtered);
        self.app.notify(self.state.id);
        if (self.on_select) |handler| handler.func(handler.ctx, self.source);
    }
};

const ListNav = struct {
    app: *App,
    state: app_mod.Entity(State),
    matches: []const usize,
    items: []const Item,
    on_select: ?SelectHandler,

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *ListNav = @ptrCast(@alignCast(ctx.?));
        if (self.matches.len == 0) return false;
        const s = self.app.read(State, self.state);
        const max_i: i32 = @intCast(self.matches.len - 1);
        switch (event.key) {
            .down => {
                s.highlighted = @min(if (s.highlighted < 0) 0 else s.highlighted + 1, max_i);
                self.app.notify(self.state.id);
                return true;
            },
            .up => {
                s.highlighted = @max(if (s.highlighted < 0) 0 else s.highlighted - 1, 0);
                self.app.notify(self.state.id);
                return true;
            },
            .enter, .space => {
                confirmHighlight(self.app, self.state, self.matches, self.items, self.on_select);
                return true;
            },
            .home => {
                s.highlighted = 0;
                self.app.notify(self.state.id);
                return true;
            },
            .end => {
                s.highlighted = max_i;
                self.app.notify(self.state.id);
                return true;
            },
            else => return false,
        }
    }
};

/// Build filter field + virtualized matched rows.
pub fn searchableList(arena: std.mem.Allocator, props: Props) !element.Element {
    const query_text = props.app.read(State, props.state).query();
    const matches = try collectMatches(arena, props.items, query_text, props.match_mode);

    // Clamp highlight into range.
    {
        const s = props.app.read(State, props.state);
        if (matches.len == 0) {
            s.highlighted = -1;
        } else if (s.highlighted < 0) {
            s.highlighted = 0;
        } else if (s.highlighted >= @as(i32, @intCast(matches.len))) {
            s.highlighted = @intCast(matches.len - 1);
        }
    }

    const host = arena.create(RowHost) catch @panic("frame arena OOM");
    host.* = .{
        .app = props.app,
        .state = props.state,
        .input = props.input,
        .items = props.items,
        .matches = matches,
        .on_select = props.on_select,
        .item_style_fn = props.item_style_fn,
        .list_id = props.list_id,
    };

    const rows = try list_mod.list(arena, props.input, .{
        .app = props.app,
        .item_count = matches.len,
        .item_height = props.item_height,
        .viewport_width = props.viewport_width,
        .viewport_height = props.viewport_height,
        .scroll_state = props.scroll_state,
        .item_fn = RowHost.renderItem,
        .item_ctx = host,
        .id = props.list_id,
        .keyboard = false,
    });

    const nav = arena.create(ListNav) catch @panic("frame arena OOM");
    nav.* = .{
        .app = props.app,
        .state = props.state,
        .matches = matches,
        .items = props.items,
        .on_select = props.on_select,
    };

    const list_shell = div_mod.div(arena)
        .withId(props.list_id)
        .role(.list)
        .a11yOrientation(.vertical)
        .a11yName("Results")
        .focusable(element.elementId(props.list_id), .{ .ctx = nav, .func = ListNav.onKey })
        .child(rows);

    const filter = buildFilter(arena, &props);
    return div_mod.div(arena)
        .withId(props.id)
        .flexCol()
        .role(.group)
        .a11yName("Searchable list")
        .childDiv(filter)
        .childDiv(list_shell)
        .any();
}

pub const setQuery = setQueryAndNotify;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const a11y_mod = @import("../a11y.zig");

test "collectMatches substring and subsequence" {
    const items = [_]Item{
        .{ .id = "a", .label = "Apple" },
        .{ .id = "b", .label = "Banana" },
        .{ .id = "c", .label = "Apricot", .keywords = "fruit orange" },
    };

    const sub = try collectMatches(std.testing.allocator, &items, "ap", .substring);
    defer std.testing.allocator.free(sub);
    try std.testing.expectEqual(@as(usize, 2), sub.len);
    try std.testing.expectEqual(@as(usize, 0), sub[0]);
    try std.testing.expectEqual(@as(usize, 2), sub[1]);

    const kw = try collectMatches(std.testing.allocator, &items, "orange", .substring);
    defer std.testing.allocator.free(kw);
    try std.testing.expectEqual(@as(usize, 1), kw.len);
    try std.testing.expectEqual(@as(usize, 2), kw[0]);

    const fuzzy = try collectMatches(std.testing.allocator, &items, "bna", .subsequence);
    defer std.testing.allocator.free(fuzzy);
    try std.testing.expectEqual(@as(usize, 1), fuzzy.len);
    try std.testing.expectEqual(@as(usize, 1), fuzzy[0]);
}

test "searchableList filters on typing and selects matched row" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 320, .height = 280 });
    defer harness.deinit();

    const Fixture = struct {
        state: app_mod.Entity(State) = undefined,
        scroll_state: ScrollState = .{},
        selected: ?usize = null,
        items: []const Item = undefined,

        fn onSelect(ctx: ?*anyopaque, source: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.selected = source;
        }

        fn itemStyle(state: ItemStyleState) style_mod.Style {
            var s = style_mod.Style{};
            s.width = .{ .px = 280 };
            s.height = .{ .px = 28 };
            s.background = if (state.highlighted) Rgba.fromHex(0xbfdbfe) else Rgba.fromHex(0xffffff);
            return s;
        }

        fn filterStyle() style_mod.Style {
            var s = style_mod.Style{};
            s.width = .{ .px = 280 };
            s.height = .{ .px = 32 };
            s.background = Rgba.fromHex(0xf3f4f6);
            return s;
        }

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, h: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return searchableList(arena, .{
                .id = "countries",
                .state = self.state,
                .app = &h.app,
                .input = &h.input,
                .items = self.items,
                .scroll_state = &self.scroll_state,
                .on_select = .{ .ctx = self, .func = onSelect },
                .item_style_fn = itemStyle,
                .filter_style_fn = filterStyle,
            });
        }
    };

    const items = [_]Item{
        .{ .id = "us", .label = "United States" },
        .{ .id = "uk", .label = "United Kingdom" },
        .{ .id = "ca", .label = "Canada" },
        .{ .id = "jp", .label = "Japan" },
    };

    var fixture: Fixture = .{
        .state = try harness.app.new(State, .{}),
        .items = &items,
    };
    try harness.setRoot(&fixture, Fixture.render);

    try std.testing.expectEqual(a11y_mod.Role.group, harness.a11yRole("countries").?);
    try std.testing.expectEqualStrings("Searchable list", harness.a11yName("countries").?);
    try std.testing.expectEqual(a11y_mod.Role.search, harness.a11yRole("searchable-list-filter").?);
    try std.testing.expectEqual(a11y_mod.Role.list, harness.a11yRole("searchable-list-rows").?);
    try std.testing.expectEqual(a11y_mod.Orientation.vertical, harness.a11yNode("searchable-list-rows").?.orientation.?);

    try harness.focusById(element.elementId("searchable-list-filter"));
    try harness.textInput("uni");
    try harness.renderFrame();

    try std.testing.expectEqualStrings("uni", harness.app.read(State, fixture.state).query());
    try std.testing.expect(harness.hitboxBounds(element.elementId("searchable-list-rows-item-0")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("searchable-list-rows-item-1")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("searchable-list-rows-item-2")) == null);

    try harness.clickOn("searchable-list-rows-item-1");
    try std.testing.expectEqual(@as(?usize, 1), fixture.selected);
    try std.testing.expectEqual(@as(?usize, 1), harness.app.read(State, fixture.state).selected_source);
}

test "searchableList keyboard moves highlight and Enter selects" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 320, .height = 280 });
    defer harness.deinit();

    const Fixture = struct {
        state: app_mod.Entity(State) = undefined,
        selected: ?usize = null,
        items: []const Item = undefined,

        fn onSelect(ctx: ?*anyopaque, source: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.selected = source;
        }

        fn itemStyle(state: ItemStyleState) style_mod.Style {
            var s = style_mod.Style{};
            s.width = .{ .px = 280 };
            s.height = .{ .px = 28 };
            s.background = if (state.highlighted) Rgba.fromHex(0xbfdbfe) else Rgba.fromHex(0xffffff);
            return s;
        }

        fn filterStyle() style_mod.Style {
            var s = style_mod.Style{};
            s.width = .{ .px = 280 };
            s.height = .{ .px = 32 };
            return s;
        }

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, h: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return searchableList(arena, .{
                .id = "picker",
                .state = self.state,
                .app = &h.app,
                .input = &h.input,
                .items = self.items,
                .on_select = .{ .ctx = self, .func = onSelect },
                .item_style_fn = itemStyle,
                .filter_style_fn = filterStyle,
            });
        }
    };

    const items = [_]Item{
        .{ .id = "a", .label = "Alpha" },
        .{ .id = "b", .label = "Beta" },
        .{ .id = "c", .label = "Gamma" },
    };
    var fixture: Fixture = .{
        .state = try harness.app.new(State, .{}),
        .items = &items,
    };
    try harness.setRoot(&fixture, Fixture.render);

    try harness.focusById(element.elementId("searchable-list-rows"));
    try harness.keyDown(.down);
    try std.testing.expectEqual(@as(i32, 1), harness.app.read(State, fixture.state).highlighted);
    try harness.keyDown(.enter);
    try std.testing.expectEqual(@as(?usize, 1), fixture.selected);
}
