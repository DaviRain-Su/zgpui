//! Headless pagination: prev/next controls, optional page-number buttons,
//! and controlled/uncontrolled page index via `value.Value(usize)`.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const value_mod = @import("../value.zig");

const Div = div_mod.Div;
const App = app_mod.App;

pub const Value = value_mod.Value(usize);

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, page: usize) void,
};

pub const ButtonStyleState = struct {
    hovered: bool = false,
    focused: bool = false,
    disabled: bool = false,
};

pub const ButtonStyleFn = *const fn (state: ButtonStyleState) style_mod.Style;

pub const PageStyleState = struct {
    selected: bool = false,
    hovered: bool = false,
    focused: bool = false,
    disabled: bool = false,
};

pub const PageStyleFn = *const fn (state: PageStyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    value: Value,
    page_count: usize,
    show_page_numbers: bool = false,
    disabled: bool = false,
    /// When true, the nav container handles arrow/home/end keys.
    keyboard: bool = false,
    on_change: ?ChangeHandler = null,
    prev_style_fn: ?ButtonStyleFn = null,
    next_style_fn: ?ButtonStyleFn = null,
    page_style_fn: ?PageStyleFn = null,
};

pub fn pageIndex(app: *App, value: Value) usize {
    return value.get(app);
}

fn clampPage(page: usize, page_count: usize) usize {
    if (page_count == 0) return 0;
    return std.math.clamp(page, 0, page_count - 1);
}

fn setPage(app: *App, value: Value, page_count: usize, next: usize, on_change: ?ChangeHandler) void {
    const clamped = clampPage(next, page_count);
    const current = value.get(app);
    if (current == clamped) return;
    value.set(app, clamped);
    if (on_change) |handler| handler.func(handler.ctx, clamped);
}

const Nav = struct {
    app: *App,
    value: Value,
    page_count: usize,
    disabled: bool,
    on_change: ?ChangeHandler,

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *Nav = @ptrCast(@alignCast(ctx.?));
        if (self.disabled or self.page_count == 0) return false;
        const current = pageIndex(self.app, self.value);
        const next: usize = switch (event.key) {
            .left, .up => current -| 1,
            .right, .down => current + 1,
            .home => 0,
            .end => self.page_count - 1,
            else => return false,
        };
        setPage(self.app, self.value, self.page_count, next, self.on_change);
        return true;
    }
};

const PrevNext = struct {
    app: *App,
    value: Value,
    page_count: usize,
    delta: i32,
    disabled: bool,
    on_change: ?ChangeHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *PrevNext = @ptrCast(@alignCast(ctx.?));
        if (self.disabled) return;
        const current = pageIndex(self.app, self.value);
        const next: usize = if (self.delta < 0)
            current -| @as(usize, @intCast(-self.delta))
        else
            current + @as(usize, @intCast(self.delta));
        setPage(self.app, self.value, self.page_count, next, self.on_change);
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        if (event.key != .enter and event.key != .space) return false;
        const self: *PrevNext = @ptrCast(@alignCast(ctx.?));
        PrevNext.onClick(ctx, &.{
            .button = .left,
            .position = .{ .x = 0, .y = 0 },
        });
        _ = self;
        return true;
    }
};

const PageActivate = struct {
    app: *App,
    value: Value,
    page_count: usize,
    page: usize,
    disabled: bool,
    on_change: ?ChangeHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *PageActivate = @ptrCast(@alignCast(ctx.?));
        if (self.disabled) return;
        setPage(self.app, self.value, self.page_count, self.page, self.on_change);
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        if (event.key != .enter and event.key != .space) return false;
        PageActivate.onClick(ctx, &.{
            .button = .left,
            .position = .{ .x = 0, .y = 0 },
        });
        return true;
    }
};

fn buttonStyle(
    input: *const element.InputState,
    id_name: []const u8,
    disabled: bool,
    style_fn: ?ButtonStyleFn,
) style_mod.Style {
    const id = element.elementId(id_name);
    const focus_id: element.FocusId = id;
    const state = ButtonStyleState{
        .hovered = input.isHovered(id),
        .focused = input.isFocused(focus_id),
        .disabled = disabled,
    };
    if (style_fn) |fn_ptr| return fn_ptr(state);
    var s = style_mod.Style{};
    s.width = .{ .px = 32 };
    s.height = .{ .px = 32 };
    return s;
}

fn pageStyle(
    input: *const element.InputState,
    id_name: []const u8,
    selected: bool,
    disabled: bool,
    style_fn: ?PageStyleFn,
) style_mod.Style {
    const id = element.elementId(id_name);
    const focus_id: element.FocusId = id;
    const state = PageStyleState{
        .selected = selected,
        .hovered = input.isHovered(id),
        .focused = input.isFocused(focus_id),
        .disabled = disabled,
    };
    if (style_fn) |fn_ptr| return fn_ptr(state);
    var s = style_mod.Style{};
    s.width = .{ .px = 28 };
    s.height = .{ .px = 28 };
    return s;
}

fn appendPrevNext(
    arena: std.mem.Allocator,
    app: *App,
    input: *const element.InputState,
    nav: *Div,
    props: Props,
    suffix: []const u8,
    delta: i32,
    style_fn: ?ButtonStyleFn,
) void {
    var id_buf: [64]u8 = undefined;
    const id_name = std.fmt.bufPrint(&id_buf, "{s}-{s}", .{ props.id, suffix }) catch @panic("id too long");
    const id = element.elementId(id_name);
    const focus_id: element.FocusId = id;

    const at_edge = if (delta < 0)
        pageIndex(app, props.value) == 0
    else
        props.page_count == 0 or pageIndex(app, props.value) >= props.page_count - 1;
    const btn_disabled = props.disabled or at_edge;

    var d = div_mod.div(arena)
        .withId(id_name)
        .interactive()
        .withStyle(buttonStyle(input, id_name, btn_disabled, style_fn));

    if (!btn_disabled) {
        const control = arena.create(PrevNext) catch @panic("frame arena OOM");
        control.* = .{
            .app = app,
            .value = props.value,
            .page_count = props.page_count,
            .delta = delta,
            .disabled = btn_disabled,
            .on_change = props.on_change,
        };
        d = d.onClick(control, PrevNext.onClick)
            .focusable(focus_id, .{ .ctx = control, .func = PrevNext.onKey });
    }

    _ = nav.childDiv(d);
}

/// Build a pagination row: prev, optional page buttons, next.
pub fn pagination(arena: std.mem.Allocator, app: *App, input: *const element.InputState, props: Props) *Div {
    const current = pageIndex(app, props.value);

    var nav = div_mod.div(arena)
        .withId(props.id)
        .flexRow()
        .itemsCenter()
        .gapPx(4);

    if (props.keyboard and !props.disabled) {
        const nav_control = arena.create(Nav) catch @panic("frame arena OOM");
        nav_control.* = .{
            .app = app,
            .value = props.value,
            .page_count = props.page_count,
            .disabled = props.disabled,
            .on_change = props.on_change,
        };
        const focus_id: element.FocusId = element.elementId(props.id);
        nav = nav.focusable(focus_id, .{ .ctx = nav_control, .func = Nav.onKey });
    }

    appendPrevNext(arena, app, input, nav, props, "prev", -1, props.prev_style_fn);

    if (props.show_page_numbers) {
        var page: usize = 0;
        while (page < props.page_count) : (page += 1) {
            var id_buf: [64]u8 = undefined;
            const id_name = std.fmt.bufPrint(&id_buf, "{s}-page-{d}", .{ props.id, page }) catch @panic("id too long");
            const id = element.elementId(id_name);
            const focus_id: element.FocusId = id;
            const selected = page == current;
            const page_disabled = props.disabled;

            var d = div_mod.div(arena)
                .withId(id_name)
                .interactive()
                .withStyle(pageStyle(input, id_name, selected, page_disabled, props.page_style_fn));

            if (!page_disabled) {
                const activate = arena.create(PageActivate) catch @panic("frame arena OOM");
                activate.* = .{
                    .app = app,
                    .value = props.value,
                    .page_count = props.page_count,
                    .page = page,
                    .disabled = page_disabled,
                    .on_change = props.on_change,
                };
                d = d.onClick(activate, PageActivate.onClick)
                    .focusable(focus_id, .{ .ctx = activate, .func = PageActivate.onKey });
            }

            nav = nav.childDiv(d);
        }
    }

    appendPrevNext(arena, app, input, nav, props, "next", 1, props.next_style_fn);

    return nav;
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const PaginationFixture = struct {
    harness: *testing_mod.Harness = undefined,
    page: app_mod.Entity(PageState) = undefined,
    uncontrolled: ?Value = null,
    page_count: usize = 5,
    show_page_numbers: bool = true,
    keyboard: bool = false,
    disabled: bool = false,

    const PageState = struct { index: usize = 0 };

    fn onChange(ctx: ?*anyopaque, page: usize) void {
        const self: *PaginationFixture = @ptrCast(@alignCast(ctx.?));
        self.harness.app.read(PageState, self.page).index = page;
        self.harness.app.notify(self.page.id);
    }

    fn value(self: *PaginationFixture) Value {
        if (self.uncontrolled) |v| return v;
        return .{ .controlled = self.harness.app.read(PageState, self.page).index };
    }

    fn prevStyle(state: ButtonStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 32 };
        s.height = .{ .px = 32 };
        s.background = if (state.disabled) color.Rgba.fromHex(0x333333) else color.Rgba.fromHex(0x555555);
        return s;
    }

    fn nextStyle(state: ButtonStyleState) style_mod.Style {
        return prevStyle(state);
    }

    fn pageNumStyle(state: PageStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 28 };
        s.height = .{ .px = 28 };
        s.background = if (state.selected) color.Rgba.fromHex(0xffffff) else color.Rgba.fromHex(0x444444);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *PaginationFixture = @ptrCast(@alignCast(ctx.?));
        const pager = pagination(arena, &harness.app, &harness.input, .{
            .id = "pager",
            .value = self.value(),
            .page_count = self.page_count,
            .show_page_numbers = self.show_page_numbers,
            .keyboard = self.keyboard,
            .disabled = self.disabled,
            .on_change = if (self.uncontrolled == null)
                .{ .ctx = self, .func = onChange }
            else
                null,
            .prev_style_fn = prevStyle,
            .next_style_fn = nextStyle,
            .page_style_fn = pageNumStyle,
        });
        const root = div_mod.div(arena)
            .sizePx(400, 80)
            .padPx(10)
            .childDiv(pager);
        return root.any();
    }
};

test "pagination prev/next clamp page index" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 80 });
    defer harness.deinit();

    var fixture = PaginationFixture{
        .harness = &harness,
        .page_count = 5,
        .show_page_numbers = false,
    };
    fixture.page = try harness.app.new(PaginationFixture.PageState, .{ .index = 2 });
    try harness.setRoot(&fixture, PaginationFixture.render);

    try harness.clickOn("pager-next");
    try std.testing.expectEqual(@as(usize, 3), pageIndex(&harness.app, fixture.value()));

    try harness.clickOn("pager-prev");
    try std.testing.expectEqual(@as(usize, 2), pageIndex(&harness.app, fixture.value()));

    // Clamp at zero.
    harness.app.read(PaginationFixture.PageState, fixture.page).index = 0;
    try harness.renderFrame();
    try harness.clickOn("pager-prev");
    try std.testing.expectEqual(@as(usize, 0), pageIndex(&harness.app, fixture.value()));

    // Clamp at last page.
    harness.app.read(PaginationFixture.PageState, fixture.page).index = 4;
    try harness.renderFrame();
    try harness.clickOn("pager-next");
    try std.testing.expectEqual(@as(usize, 4), pageIndex(&harness.app, fixture.value()));
}

test "pagination page number buttons select page" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 80 });
    defer harness.deinit();

    var fixture = PaginationFixture{
        .harness = &harness,
        .page_count = 3,
    };
    fixture.page = try harness.app.new(PaginationFixture.PageState, .{ .index = 0 });
    try harness.setRoot(&fixture, PaginationFixture.render);

    try harness.clickOn("pager-page-2");
    try std.testing.expectEqual(@as(usize, 2), pageIndex(&harness.app, fixture.value()));
}

test "pagination uncontrolled value updates on interaction" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 80 });
    defer harness.deinit();

    const entity = try harness.app.new(Value.Store, .{ .value = 1 });
    var fixture = PaginationFixture{
        .harness = &harness,
        .uncontrolled = .{ .uncontrolled = entity },
        .page_count = 4,
        .show_page_numbers = false,
    };
    try harness.setRoot(&fixture, PaginationFixture.render);

    try harness.clickOn("pager-next");
    try std.testing.expectEqual(@as(usize, 2), pageIndex(&harness.app, fixture.value()));
}

test "pagination keyboard navigation when enabled" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 80 });
    defer harness.deinit();

    var fixture = PaginationFixture{
        .harness = &harness,
        .page_count = 5,
        .show_page_numbers = false,
        .keyboard = true,
    };
    fixture.page = try harness.app.new(PaginationFixture.PageState, .{ .index = 1 });
    try harness.setRoot(&fixture, PaginationFixture.render);

    try harness.focusById(element.elementId("pager"));
    try harness.keyDown(.right);
    try std.testing.expectEqual(@as(usize, 2), pageIndex(&harness.app, fixture.value()));
    try harness.keyDown(.left);
    try std.testing.expectEqual(@as(usize, 1), pageIndex(&harness.app, fixture.value()));
    try harness.keyDown(.end);
    try std.testing.expectEqual(@as(usize, 4), pageIndex(&harness.app, fixture.value()));
    try harness.keyDown(.home);
    try std.testing.expectEqual(@as(usize, 0), pageIndex(&harness.app, fixture.value()));
}

test "selected page button gets selected style" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 80 });
    defer harness.deinit();

    var fixture = PaginationFixture{
        .harness = &harness,
        .page_count = 3,
    };
    fixture.page = try harness.app.new(PaginationFixture.PageState, .{ .index = 1 });
    try harness.setRoot(&fixture, PaginationFixture.render);

    // Quads: prev + 3 pages + next = 5.
    try std.testing.expectEqual(@as(usize, 5), harness.scene.quads.items.len);
    const selected_quad = harness.scene.quads.items[2];
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), selected_quad.background.r, 0.001);
}
