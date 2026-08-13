//! Headless calendar: civil-date grid (6×7), month navigation, keyboard
//! selection. No OS calendar APIs — pure date math (Sakamoto weekday).

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const value_mod = @import("../value.zig");
const color = @import("../color.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Rgba = color.Rgba;
const a11y_mod = @import("../a11y.zig");

pub const grid_rows = 6;
pub const grid_cols = 7;
pub const grid_size = grid_rows * grid_cols;

/// Simple civil date (month 1–12, day 1–31).
pub const Date = struct {
    year: i32,
    month: u8,
    day: u8,

    pub fn eql(a: Date, b: Date) bool {
        return a.year == b.year and a.month == b.month and a.day == b.day;
    }

    pub fn isLeap(year: i32) bool {
        return @rem(year, 4) == 0 and (@rem(year, 100) != 0 or @rem(year, 400) == 0);
    }

    pub fn daysInMonth(year: i32, month: u8) u8 {
        return switch (month) {
            1, 3, 5, 7, 8, 10, 12 => 31,
            4, 6, 9, 11 => 30,
            2 => if (isLeap(year)) 29 else 28,
            else => unreachable,
        };
    }

    /// Sakamoto: 0 = Sunday … 6 = Saturday.
    pub fn weekday(year: i32, month: u8, day: u8) u8 {
        const t = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
        var y: i32 = year;
        const m: i32 = @intCast(month);
        y -= @intFromBool(m < 3);
        const sum: i32 = y + @divTrunc(y, 4) - @divTrunc(y, 100) + @divTrunc(y, 400) + t[@intCast(m - 1)] + @as(i32, @intCast(day));
        const w = @mod(sum, 7);
        return @intCast(w);
    }

    pub fn prevMonth(year: i32, month: u8) struct { year: i32, month: u8 } {
        if (month == 1) return .{ .year = year - 1, .month = 12 };
        return .{ .year = year, .month = month - 1 };
    }

    pub fn nextMonth(year: i32, month: u8) struct { year: i32, month: u8 } {
        if (month == 12) return .{ .year = year + 1, .month = 1 };
        return .{ .year = year, .month = month + 1 };
    }

    pub fn addDays(self: Date, delta: i32) Date {
        if (delta == 0) return self;
        var d = self;
        var remaining = delta;
        while (remaining > 0) {
            const dim = daysInMonth(d.year, d.month);
            const space: i32 = @intCast(dim - d.day);
            if (remaining <= space) {
                d.day = @intCast(@as(i32, @intCast(d.day)) + remaining);
                return d;
            }
            remaining -= space + 1;
            const nm = nextMonth(d.year, d.month);
            d = .{ .year = nm.year, .month = nm.month, .day = 1 };
        }
        while (remaining < 0) {
            const day_i: i32 = @intCast(d.day);
            if (day_i + remaining >= 1) {
                d.day = @intCast(day_i + remaining);
                return d;
            }
            remaining += day_i;
            const pm = prevMonth(d.year, d.month);
            d = .{
                .year = pm.year,
                .month = pm.month,
                .day = daysInMonth(pm.year, pm.month),
            };
        }
        return d;
    }

    pub fn syncView(self: Date) CalendarState {
        return .{ .view_year = self.year, .view_month = self.month };
    }
};

pub const DayCell = struct {
    date: Date,
    outside: bool,
};

pub fn monthGrid(view_year: i32, view_month: u8) [grid_size]DayCell {
    const first_wd = Date.weekday(view_year, view_month, 1);
    var start = Date{ .year = view_year, .month = view_month, .day = 1 };
    start = start.addDays(-@as(i32, @intCast(first_wd)));

    var cells: [grid_size]DayCell = undefined;
    var cur = start;
    for (&cells, 0..) |*cell, i| {
        _ = i;
        cell.* = .{
            .date = cur,
            .outside = cur.month != view_month or cur.year != view_year,
        };
        cur = cur.addDays(1);
    }
    return cells;
}

pub const CalendarState = struct {
    view_year: i32 = 2024,
    view_month: u8 = 1,

    pub fn setView(self: *CalendarState, year: i32, month: u8) void {
        self.view_year = year;
        self.view_month = month;
    }

    pub fn prevMonth(self: *CalendarState) void {
        const pm = Date.prevMonth(self.view_year, self.view_month);
        self.view_year = pm.year;
        self.view_month = pm.month;
    }

    pub fn nextMonth(self: *CalendarState) void {
        const nm = Date.nextMonth(self.view_year, self.view_month);
        self.view_year = nm.year;
        self.view_month = nm.month;
    }
};

pub const Value = value_mod.Value(Date);

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, date: Date) void,
};

pub const DayStyleState = struct {
    selected: bool = false,
    today: bool = false,
    outside: bool = false,
    hovered: bool = false,
    focused: bool = false,
};

pub const DayStyleFn = *const fn (state: DayStyleState) style_mod.Style;
pub const NavStyleFn = *const fn (disabled: bool) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    state: app_mod.Entity(CalendarState),
    value: Value,
    app: *App,
    input: *element.InputState,
    /// Optional "today" highlight (no OS clock).
    today: ?Date = null,
    on_change: ?ChangeHandler = null,
    day_style_fn: ?DayStyleFn = null,
    prev_style_fn: ?NavStyleFn = null,
    next_style_fn: ?NavStyleFn = null,
};

pub fn selectedDate(app: *App, value: Value) Date {
    return value.get(app);
}

pub fn viewYear(app: *App, state: app_mod.Entity(CalendarState)) i32 {
    return app.read(CalendarState, state).view_year;
}

pub fn viewMonth(app: *App, state: app_mod.Entity(CalendarState)) u8 {
    return app.read(CalendarState, state).view_month;
}

fn setView(app: *App, state: app_mod.Entity(CalendarState), year: i32, month: u8) void {
    app.read(CalendarState, state).setView(year, month);
    app.notify(state.id);
}

pub fn selectDate(app: *App, value: Value, date: Date, on_change: ?ChangeHandler) void {
    const current = value.get(app);
    if (Date.eql(current, date)) return;
    value.set(app, date);
    if (on_change) |handler| handler.func(handler.ctx, date);
}

fn ensureViewForDate(app: *App, state: app_mod.Entity(CalendarState), date: Date) void {
    const cal = app.read(CalendarState, state);
    if (cal.view_year == date.year and cal.view_month == date.month) return;
    cal.setView(date.year, date.month);
    app.notify(state.id);
}

const MonthNav = struct {
    app: *App,
    state: app_mod.Entity(CalendarState),
    delta: i32,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *MonthNav = @ptrCast(@alignCast(ctx.?));
        const cal = self.app.read(CalendarState, self.state);
        if (self.delta < 0) {
            cal.prevMonth();
        } else {
            cal.nextMonth();
        }
        self.app.notify(self.state.id);
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        if (event.key != .enter and event.key != .space) return false;
        MonthNav.onClick(ctx, &.{
            .button = .left,
            .position = .{ .x = 0, .y = 0 },
        });
        return true;
    }
};

const DaySelect = struct {
    app: *App,
    state: app_mod.Entity(CalendarState),
    value: Value,
    date: Date,
    on_change: ?ChangeHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *DaySelect = @ptrCast(@alignCast(ctx.?));
        ensureViewForDate(self.app, self.state, self.date);
        selectDate(self.app, self.value, self.date, self.on_change);
    }
};

const GridNav = struct {
    app: *App,
    state: app_mod.Entity(CalendarState),
    value: Value,
    on_change: ?ChangeHandler,

    fn moveSelection(self: *GridNav, delta: i32) void {
        const next = selectedDate(self.app, self.value).addDays(delta);
        ensureViewForDate(self.app, self.state, next);
        selectDate(self.app, self.value, next, self.on_change);
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *GridNav = @ptrCast(@alignCast(ctx.?));
        switch (event.key) {
            .left => {
                self.moveSelection(-1);
                return true;
            },
            .right => {
                self.moveSelection(1);
                return true;
            },
            .up => {
                self.moveSelection(-7);
                return true;
            },
            .down => {
                self.moveSelection(7);
                return true;
            },
            .page_up => {
                self.app.read(CalendarState, self.state).prevMonth();
                self.app.notify(self.state.id);
                return true;
            },
            .page_down => {
                self.app.read(CalendarState, self.state).nextMonth();
                self.app.notify(self.state.id);
                return true;
            },
            else => return false,
        }
    }
};

fn defaultDayStyle(state: DayStyleState) style_mod.Style {
    var s = style_mod.Style{};
    s.width = .{ .px = 32 };
    s.height = .{ .px = 32 };
    s.background = if (state.selected)
        Rgba.fromHex(0x2563eb)
    else if (state.today)
        Rgba.fromHex(0xdbeafe)
    else if (state.outside)
        Rgba.fromHex(0xf9fafb)
    else if (state.hovered)
        Rgba.fromHex(0xf3f4f6)
    else
        Rgba.fromHex(0xffffff);
    return s;
}

fn defaultNavStyle(_: bool) style_mod.Style {
    var s = style_mod.Style{};
    s.width = .{ .px = 28 };
    s.height = .{ .px = 28 };
    s.background = Rgba.fromHex(0xe5e7eb);
    return s;
}

fn dayStyle(
    input: *const element.InputState,
    id_name: []const u8,
    cell: DayCell,
    selected: Date,
    today: ?Date,
    style_fn: ?DayStyleFn,
) style_mod.Style {
    const id = element.elementId(id_name);
    const focus_id: element.FocusId = id;
    const state = DayStyleState{
        .selected = Date.eql(cell.date, selected),
        .today = if (today) |t| Date.eql(cell.date, t) else false,
        .outside = cell.outside,
        .hovered = input.isHovered(id),
        .focused = input.isFocused(focus_id),
    };
    if (style_fn) |fn_ptr| return fn_ptr(state);
    return defaultDayStyle(state);
}

pub fn calendarDay(
    arena: std.mem.Allocator,
    input: *const element.InputState,
    props: Props,
    cell: DayCell,
    index: usize,
) *Div {
    var id_buf: [64]u8 = undefined;
    const id_name = std.fmt.bufPrint(&id_buf, "{s}-day-{d}", .{ props.id, index }) catch @panic("id too long");
    const id = element.elementId(id_name);
    const focus_id: element.FocusId = id;
    const selected = selectedDate(props.app, props.value);
    const is_selected = Date.eql(cell.date, selected);
    const day_name = std.fmt.allocPrint(arena, "{d}", .{cell.date.day}) catch @panic("frame arena OOM");

    var d = div_mod.div(arena)
        .withId(id_name)
        .interactive()
        .role(.button)
        .a11yName(day_name)
        .a11ySelected(is_selected)
        .withStyle(dayStyle(input, id_name, cell, selected, props.today, props.day_style_fn));

    const select_ctx = arena.create(DaySelect) catch @panic("frame arena OOM");
    select_ctx.* = .{
        .app = props.app,
        .state = props.state,
        .value = props.value,
        .date = cell.date,
        .on_change = props.on_change,
    };
    d = d.onClick(select_ctx, DaySelect.onClick)
        .focusable(focus_id, .{ .ctx = select_ctx, .func = struct {
            fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
                if (event.key != .enter and event.key != .space) return false;
                DaySelect.onClick(ctx, &.{
                    .button = .left,
                    .position = .{ .x = 0, .y = 0 },
                });
                return true;
            }
        }.onKey });
    return d;
}

/// Calendar compound: prev/next month controls and a 6×7 day grid.
pub fn calendar(arena: std.mem.Allocator, props: Props) *Div {
    const cal_state = props.app.read(CalendarState, props.state);
    const cells = monthGrid(cal_state.view_year, cal_state.view_month);

    var root = div_mod.div(arena)
        .withId(props.id)
        .flexCol()
        .gapPx(4)
        .role(.table)
        .a11yName("Calendar");

    var header = div_mod.div(arena)
        .flexRow()
        .itemsCenter()
        .gapPx(4);

    var id_buf: [64]u8 = undefined;
    const prev_id = std.fmt.bufPrint(&id_buf, "{s}-prev", .{props.id}) catch @panic("id too long");
    const prev_style = if (props.prev_style_fn) |fn_ptr| fn_ptr(false) else defaultNavStyle(false);
    var prev = div_mod.div(arena)
        .withId(prev_id)
        .interactive()
        .role(.button)
        .a11yName("Previous month")
        .withStyle(prev_style);
    const prev_nav = arena.create(MonthNav) catch @panic("frame arena OOM");
    prev_nav.* = .{ .app = props.app, .state = props.state, .delta = -1 };
    prev = prev.onClick(prev_nav, MonthNav.onClick)
        .focusable(element.elementId(prev_id), .{
            .ctx = prev_nav,
            .func = MonthNav.onKey,
        });
    header = header.childDiv(prev);

    const next_id = std.fmt.bufPrint(&id_buf, "{s}-next", .{props.id}) catch @panic("id too long");
    const next_style = if (props.next_style_fn) |fn_ptr| fn_ptr(false) else defaultNavStyle(false);
    var next = div_mod.div(arena)
        .withId(next_id)
        .interactive()
        .role(.button)
        .a11yName("Next month")
        .withStyle(next_style);
    const next_nav = arena.create(MonthNav) catch @panic("frame arena OOM");
    next_nav.* = .{ .app = props.app, .state = props.state, .delta = 1 };
    next = next.onClick(next_nav, MonthNav.onClick)
        .focusable(element.elementId(next_id), .{
            .ctx = next_nav,
            .func = MonthNav.onKey,
        });
    header = header.childDiv(next);
    root = root.childDiv(header);

    const grid_id = std.fmt.bufPrint(&id_buf, "{s}-grid", .{props.id}) catch @panic("id too long");
    var grid = div_mod.div(arena)
        .withId(grid_id)
        .flexCol()
        .gapPx(2)
        .role(.generic)
        .a11yName("Dates");

    const grid_nav = arena.create(GridNav) catch @panic("frame arena OOM");
    grid_nav.* = .{
        .app = props.app,
        .state = props.state,
        .value = props.value,
        .on_change = props.on_change,
    };
    const grid_focus_id: element.FocusId = element.elementId(grid_id);
    grid = grid.focusable(grid_focus_id, .{ .ctx = grid_nav, .func = GridNav.onKey });

    var row_idx: usize = 0;
    while (row_idx < grid_rows) : (row_idx += 1) {
        var row = div_mod.div(arena).flexRow().gapPx(2);
        var col_idx: usize = 0;
        while (col_idx < grid_cols) : (col_idx += 1) {
            const index = row_idx * grid_cols + col_idx;
            row = row.childDiv(calendarDay(arena, props.input, props, cells[index], index));
        }
        grid = grid.childDiv(row);
    }
    root = root.childDiv(grid);

    return root;
}

// ---------------------------------------------------------------------------
// Date math unit tests
// ---------------------------------------------------------------------------

test "Date.isLeap" {
    try std.testing.expect(Date.isLeap(2000));
    try std.testing.expect(Date.isLeap(2024));
    try std.testing.expect(!Date.isLeap(1900));
    try std.testing.expect(!Date.isLeap(2023));
}

test "Date.daysInMonth" {
    try std.testing.expectEqual(@as(u8, 31), Date.daysInMonth(2024, 1));
    try std.testing.expectEqual(@as(u8, 29), Date.daysInMonth(2024, 2));
    try std.testing.expectEqual(@as(u8, 28), Date.daysInMonth(2023, 2));
    try std.testing.expectEqual(@as(u8, 30), Date.daysInMonth(2024, 4));
}

test "Date.weekday Sakamoto known dates" {
    // 2024-08-12 is Monday (1).
    try std.testing.expectEqual(@as(u8, 1), Date.weekday(2024, 8, 12));
    // 2024-01-01 is Monday (1).
    try std.testing.expectEqual(@as(u8, 1), Date.weekday(2024, 1, 1));
    // 2023-12-31 is Sunday (0).
    try std.testing.expectEqual(@as(u8, 0), Date.weekday(2023, 12, 31));
}

test "Date.addDays crosses month boundary" {
    const start = Date{ .year = 2024, .month = 1, .day = 31 };
    const d = start.addDays(1);
    try std.testing.expectEqual(@as(i32, 2024), d.year);
    try std.testing.expectEqual(@as(u8, 2), d.month);
    try std.testing.expectEqual(@as(u8, 1), d.day);
}

test "monthGrid marks outside days" {
    const cells = monthGrid(2024, 8);
    var inside: usize = 0;
    var outside: usize = 0;
    for (cells) |cell| {
        if (cell.outside) {
            outside += 1;
        } else {
            inside += 1;
            try std.testing.expectEqual(@as(u8, 8), cell.date.month);
        }
    }
    try std.testing.expectEqual(@as(usize, 31), inside);
    try std.testing.expect(outside > 0);
    try std.testing.expectEqual(@as(usize, grid_size), inside + outside);
}

// ---------------------------------------------------------------------------
// Harness behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

test "calendar exposes table nav and selected day a11y" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 280, .height = 260 });
    defer harness.deinit();

    var fixture = CalendarFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.cal_state = try harness.app.new(CalendarState, .{ .view_year = 2024, .view_month = 8 });
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = .{ .year = 2024, .month = 8, .day = 12 } });
    try harness.setRoot(&fixture, CalendarFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.table, harness.a11yRole("cal").?);
    try std.testing.expectEqualStrings("Calendar", harness.a11yName("cal").?);
    try std.testing.expectEqual(a11y_mod.Role.button, harness.a11yRole("cal-prev").?);
    try std.testing.expectEqualStrings("Previous month", harness.a11yName("cal-prev").?);
    try std.testing.expectEqual(a11y_mod.Role.button, harness.a11yRole("cal-next").?);
    try std.testing.expectEqual(a11y_mod.Role.button, harness.a11yRole("cal-day-18").?);
    // Aug 2024 starts on Thursday → day 12 is grid index 14? weekday Aug 1 2024 is Thursday (4).
    // Index for Aug 12: first_wd=4, day 12 → index = 4 + 11 = 15.
    try std.testing.expect(harness.a11yNode("cal-day-15").?.selected.?);
}

const CalendarFixture = struct {
    harness: *testing_mod.Harness = undefined,
    cal_state: app_mod.Entity(CalendarState) = undefined,
    value_entity: app_mod.Entity(Value.Store) = undefined,
    controlled_date: ?Date = null,
    change_log: std.ArrayList(Date) = .empty,

    fn deinit(self: *CalendarFixture) void {
        self.change_log.deinit(std.testing.allocator);
    }

    fn onChange(ctx: ?*anyopaque, date: Date) void {
        const self: *CalendarFixture = @ptrCast(@alignCast(ctx.?));
        self.change_log.append(std.testing.allocator, date) catch unreachable;
    }

    fn currentValue(self: *CalendarFixture) Value {
        return if (self.controlled_date) |d|
            .{ .controlled = d }
        else
            .{ .uncontrolled = self.value_entity };
    }

    fn fixtureDayStyle(state: DayStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 32 };
        s.height = .{ .px = 32 };
        s.background = if (state.selected) Rgba.fromHex(0x2563eb) else Rgba.fromHex(0xffffff);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *CalendarFixture = @ptrCast(@alignCast(ctx.?));
        const cal = calendar(arena, .{
            .id = "cal",
            .state = self.cal_state,
            .value = self.currentValue(),
            .app = &harness.app,
            .input = &harness.input,
            .on_change = .{ .ctx = self, .func = onChange },
            .day_style_fn = fixtureDayStyle,
        });
        return div_mod.div(arena).sizePx(280, 260).padPx(8).childDiv(cal).any();
    }
};

test "calendar next month changes view" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 280, .height = 260 });
    defer harness.deinit();

    var fixture = CalendarFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.cal_state = try harness.app.new(CalendarState, .{ .view_year = 2024, .view_month = 8 });
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = .{ .year = 2024, .month = 8, .day = 12 } });
    try harness.setRoot(&fixture, CalendarFixture.render);

    try std.testing.expectEqual(@as(u8, 8), viewMonth(&harness.app, fixture.cal_state));
    try harness.clickOn("cal-next");
    try std.testing.expectEqual(@as(u8, 9), viewMonth(&harness.app, fixture.cal_state));
    try harness.clickOn("cal-prev");
    try std.testing.expectEqual(@as(u8, 8), viewMonth(&harness.app, fixture.cal_state));
}

test "calendar day click selects date" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 280, .height = 260 });
    defer harness.deinit();

    var fixture = CalendarFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.cal_state = try harness.app.new(CalendarState, .{ .view_year = 2024, .view_month = 8 });
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = .{ .year = 2024, .month = 8, .day = 1 } });
    try harness.setRoot(&fixture, CalendarFixture.render);

    // Aug 2024: first cell index 4 is Aug 1 (Thu). Aug 15 is index 18.
    try harness.clickOn("cal-day-18");
    const selected = selectedDate(&harness.app, fixture.currentValue());
    try std.testing.expectEqual(@as(i32, 2024), selected.year);
    try std.testing.expectEqual(@as(u8, 8), selected.month);
    try std.testing.expectEqual(@as(u8, 15), selected.day);
    try std.testing.expectEqual(@as(usize, 1), fixture.change_log.items.len);
}

test "calendar grid keyboard moves selection" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 280, .height = 260 });
    defer harness.deinit();

    var fixture = CalendarFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.cal_state = try harness.app.new(CalendarState, .{ .view_year = 2024, .view_month = 8 });
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = .{ .year = 2024, .month = 8, .day = 12 } });
    try harness.setRoot(&fixture, CalendarFixture.render);

    try harness.focusById(element.elementId("cal-grid"));
    try harness.keyDown(.right);
    const selected = selectedDate(&harness.app, fixture.currentValue());
    try std.testing.expectEqual(@as(u8, 13), selected.day);
}

test "calendar page down changes month" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 280, .height = 260 });
    defer harness.deinit();

    var fixture = CalendarFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.cal_state = try harness.app.new(CalendarState, .{ .view_year = 2024, .view_month = 8 });
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = .{ .year = 2024, .month = 8, .day = 12 } });
    try harness.setRoot(&fixture, CalendarFixture.render);

    try harness.focusById(element.elementId("cal-grid"));
    try harness.keyDown(.page_down);
    try std.testing.expectEqual(@as(u8, 9), viewMonth(&harness.app, fixture.cal_state));
}
