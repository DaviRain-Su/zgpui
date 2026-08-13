//! Headless datepicker: trigger + overlay calendar, dismiss via Escape or
//! outside click.

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
const calendar_mod = @import("calendar.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Date = calendar_mod.Date;
const CalendarState = calendar_mod.CalendarState;
const Rgba = color.Rgba;
const Pixels = geometry.Pixels;
const Bounds = geometry.Bounds;
const Size = geometry.Size;

pub const Value = calendar_mod.Value;
pub const ChangeHandler = calendar_mod.ChangeHandler;

pub const DatepickerState = struct {
    open: bool = false,

    pub fn openPicker(self: *DatepickerState) void {
        self.open = true;
    }

    pub fn close(self: *DatepickerState) void {
        self.open = false;
    }
};

pub const StyleFn = *const fn (open: bool) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    trigger_id: []const u8,
    state: app_mod.Entity(DatepickerState),
    cal_state: app_mod.Entity(CalendarState),
    value: Value,
    overlays: *overlay_mod.OverlayStack,
    app: *App,
    frame: *const element.FrameState,
    input: *element.InputState,
    viewport: Size(Pixels),
    calendar_id: []const u8,
    today: ?Date = null,
    z_index: i32 = 70,
    trap_focus: bool = true,
    modal: bool = true,
    on_change: ?ChangeHandler = null,
    panel_style: ?StyleFn = null,
    day_style_fn: ?calendar_mod.DayStyleFn = null,
};

pub fn selectedDate(app: *App, value: Value) Date {
    return calendar_mod.selectedDate(app, value);
}

pub fn close(app: *App, state: app_mod.Entity(DatepickerState)) void {
    app.read(DatepickerState, state).close();
    app.notify(state.id);
}

pub fn open(app: *App, state: app_mod.Entity(DatepickerState)) void {
    app.read(DatepickerState, state).openPicker();
    app.notify(state.id);
}

pub fn toggle(app: *App, state: app_mod.Entity(DatepickerState)) void {
    const s = app.read(DatepickerState, state);
    if (s.open) s.close() else s.openPicker();
    app.notify(state.id);
}

const Host = struct {
    app: *App,
    picker_state: app_mod.Entity(DatepickerState),
    cal_state: app_mod.Entity(CalendarState),
    value: Value,
    frame: *const element.FrameState,
    viewport: Size(Pixels),
    trigger_id: []const u8,
    panel_id: []const u8,
    calendar_id: []const u8,
    today: ?Date,
    on_change: ?ChangeHandler,
    panel_style: ?StyleFn,
    day_style_fn: ?calendar_mod.DayStyleFn,
    input: *element.InputState,

    fn dismiss(ctx: ?*anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        close(self.app, self.picker_state);
    }

    fn dismissMouseDown(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        dismiss(ctx);
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!element.Element {
        const self: *Host = @ptrCast(@alignCast(ctx.?));
        const is_open = self.app.read(DatepickerState, self.picker_state).open;
        if (!is_open) return div_mod.div(arena).sizePx(0, 0).any();

        var backdrop = div_mod.div(arena)
            .withId("datepicker-backdrop")
            .absolute()
            .wFull()
            .hFull()
            .interactive()
            .onMouseDown(self, dismissMouseDown);

        var panel = div_mod.div(arena)
            .withId(self.panel_id)
            .absolute()
            .interactive()
            .role(.dialog)
            .a11yModal(true)
            .a11yName("Date picker");
        if (self.panel_style) |style_fn| {
            panel = panel.withStyle(style_fn(true));
        } else {
            var s = style_mod.Style{};
            s.width = .{ .px = 260 };
            s.min_height = .{ .px = 240 };
            s.background = Rgba.fromHex(0xffffff);
            s.corner_radii = geometry.Corners(Pixels).all(6);
            s.padding = .{
                .top = .{ .px = 8 },
                .right = .{ .px = 8 },
                .bottom = .{ .px = 8 },
                .left = .{ .px = 8 },
            };
            panel = panel.withStyle(s);
        }
        panel = panel.onClick(null, struct {
            fn swallow(_: ?*anyopaque, _: *const platform.MouseButtonEvent) void {}
        }.swallow);

        const cal = calendar_mod.calendar(arena, .{
            .id = self.calendar_id,
            .state = self.cal_state,
            .value = self.value,
            .app = self.app,
            .input = self.input,
            .today = self.today,
            .on_change = self.on_change,
            .day_style_fn = self.day_style_fn,
        });
        panel = panel.childDiv(cal);

        if (triggerBounds(self.frame, self.trigger_id)) |bounds| {
            var s = panel.style;
            s.position = .absolute;
            s.inset.top = .{ .px = bounds.origin.y + bounds.size.height + 4 };
            s.inset.left = .{ .px = bounds.origin.x };
            panel.style = s;
        } else {
            var s = panel.style;
            s.position = .absolute;
            s.inset.top = .{ .px = self.viewport.height / 2 - 120 };
            s.inset.left = .{ .px = self.viewport.width / 2 - 130 };
            panel.style = s;
        }

        return backdrop.childDiv(panel).any();
    }
};

const TriggerHost = struct {
    app: *App,
    state: app_mod.Entity(DatepickerState),
    cal_state: app_mod.Entity(CalendarState),
    value: Value,
    input: *element.InputState,
    calendar_id: []const u8,

    fn toggle(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *TriggerHost = @ptrCast(@alignCast(ctx.?));
        const s = self.app.read(DatepickerState, self.state);
        if (s.open) {
            s.close();
        } else {
            const selected = selectedDate(self.app, self.value);
            self.app.read(CalendarState, self.cal_state).setView(selected.year, selected.month);
            self.app.notify(self.cal_state.id);
            s.openPicker();
            self.input.focus(element.elementId(self.calendar_id));
        }
        self.app.notify(self.state.id);
    }
};

const DayPickClose = struct {
    app: *App,
    picker_state: app_mod.Entity(DatepickerState),
    wrapped: ChangeHandler,

    fn onChange(ctx: ?*anyopaque, date: Date) void {
        const self: *DayPickClose = @ptrCast(@alignCast(ctx.?));
        self.wrapped.func(self.wrapped.ctx, date);
        close(self.app, self.picker_state);
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

fn registerOverlay(arena: std.mem.Allocator, props: Props, on_change: ?ChangeHandler) !void {
    const is_open = props.app.read(DatepickerState, props.state).open;
    if (!is_open) return;

    const host = arena.create(Host) catch @panic("frame arena OOM");
    host.* = .{
        .app = props.app,
        .picker_state = props.state,
        .cal_state = props.cal_state,
        .value = props.value,
        .frame = props.frame,
        .viewport = props.viewport,
        .trigger_id = props.trigger_id,
        .panel_id = props.id,
        .calendar_id = props.calendar_id,
        .today = props.today,
        .on_change = on_change,
        .panel_style = props.panel_style,
        .day_style_fn = props.day_style_fn,
        .input = props.input,
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

/// Zero-size main-tree placeholder; registers the datepicker overlay when open.
pub fn datepicker(arena: std.mem.Allocator, props: Props) !*Div {
    try registerOverlay(arena, props, props.on_change);
    return div_mod.div(arena).sizePx(0, 0);
}

/// Wire a click-to-toggle trigger and register the overlay when open.
pub fn datepickerWithTrigger(
    arena: std.mem.Allocator,
    props: Props,
    trigger: *Div,
) !*Div {
    var on_change = props.on_change;
    if (on_change == null) {
        on_change = .{ .ctx = null, .func = struct {
            fn noop(_: ?*anyopaque, _: Date) void {}
        }.noop };
    }
    const wrap = arena.create(DayPickClose) catch @panic("frame arena OOM");
    wrap.* = .{
        .app = props.app,
        .picker_state = props.state,
        .wrapped = on_change.?,
    };
    const wrapped_on_change = ChangeHandler{ .ctx = wrap, .func = DayPickClose.onChange };

    const trigger_host = arena.create(TriggerHost) catch @panic("frame arena OOM");
    trigger_host.* = .{
        .app = props.app,
        .state = props.state,
        .cal_state = props.cal_state,
        .value = props.value,
        .input = props.input,
        .calendar_id = props.calendar_id,
    };
    _ = trigger.onClick(trigger_host, TriggerHost.toggle);

    const is_open = props.app.read(DatepickerState, props.state).open;
    const selected = selectedDate(props.app, props.value);
    if (trigger.a11y_role == null) _ = trigger.role(.button);
    _ = trigger.a11yExpanded(is_open);
    if (trigger.a11y_name == .none) _ = trigger.a11yName("Date");
    const value_text = std.fmt.allocPrint(arena, "{d}-{d:0>2}-{d:0>2}", .{ selected.year, selected.month, selected.day }) catch @panic("frame arena OOM");
    _ = trigger.a11yValueText(value_text);

    try registerOverlay(arena, props, wrapped_on_change);
    return trigger;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const a11y_mod = @import("../a11y.zig");

const DatepickerFixture = struct {
    harness: *testing_mod.Harness = undefined,
    picker_state: app_mod.Entity(DatepickerState) = undefined,
    cal_state: app_mod.Entity(CalendarState) = undefined,
    value_entity: app_mod.Entity(Value.Store) = undefined,
    change_log: std.ArrayList(Date) = .empty,

    fn deinit(self: *DatepickerFixture) void {
        self.change_log.deinit(std.testing.allocator);
    }

    fn onChange(ctx: ?*anyopaque, date: Date) void {
        const self: *DatepickerFixture = @ptrCast(@alignCast(ctx.?));
        self.change_log.append(std.testing.allocator, date) catch unreachable;
    }

    fn currentValue(self: *DatepickerFixture) Value {
        return .{ .uncontrolled = self.value_entity };
    }

    fn dayStyle(state: calendar_mod.DayStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 32 };
        s.height = .{ .px = 32 };
        s.background = if (state.selected) Rgba.fromHex(0x2563eb) else Rgba.fromHex(0xffffff);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *DatepickerFixture = @ptrCast(@alignCast(ctx.?));

        var trigger = div_mod.div(arena)
            .withId("datepicker-trigger")
            .sizePx(140, 32)
            .bg(Rgba.fromHex(0x336699));
        trigger = try datepickerWithTrigger(arena, .{
            .id = "birthday-picker",
            .trigger_id = "datepicker-trigger",
            .state = self.picker_state,
            .cal_state = self.cal_state,
            .value = self.currentValue(),
            .overlays = &harness.overlays,
            .app = &harness.app,
            .frame = &harness.frame,
            .input = &harness.input,
            .viewport = harness.viewport,
            .calendar_id = "picker-cal",
            .on_change = .{ .ctx = self, .func = onChange },
            .day_style_fn = dayStyle,
        }, trigger);

        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(trigger).any();
    }
};

test "datepicker opens via trigger" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = DatepickerFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.picker_state = try harness.app.new(DatepickerState, .{});
    fixture.cal_state = try harness.app.new(CalendarState, .{ .view_year = 2024, .view_month = 8 });
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = .{ .year = 2024, .month = 8, .day = 1 } });
    try harness.setRoot(&fixture, DatepickerFixture.render);

    try std.testing.expect(!harness.app.read(DatepickerState, fixture.picker_state).open);
    try harness.clickOn("datepicker-trigger");
    try std.testing.expect(harness.app.read(DatepickerState, fixture.picker_state).open);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);
    try std.testing.expectEqual(a11y_mod.Role.button, harness.a11yRole("datepicker-trigger").?);
    try std.testing.expect(harness.a11yNode("datepicker-trigger").?.expanded.?);
    try std.testing.expectEqualStrings("Date", harness.a11yName("datepicker-trigger").?);
    try std.testing.expectEqual(a11y_mod.Role.dialog, harness.a11yRole("birthday-picker").?);
    try std.testing.expectEqualStrings("Date picker", harness.a11yName("birthday-picker").?);
}

test "datepicker day select closes and updates value" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = DatepickerFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.picker_state = try harness.app.new(DatepickerState, .{});
    fixture.cal_state = try harness.app.new(CalendarState, .{ .view_year = 2024, .view_month = 8 });
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = .{ .year = 2024, .month = 8, .day = 1 } });
    try harness.setRoot(&fixture, DatepickerFixture.render);

    try harness.clickOn("datepicker-trigger");
    try harness.clickOn("picker-cal-day-18");
    try std.testing.expect(!harness.app.read(DatepickerState, fixture.picker_state).open);
    const selected = selectedDate(&harness.app, fixture.currentValue());
    try std.testing.expectEqual(@as(u8, 15), selected.day);
    try std.testing.expectEqual(@as(usize, 1), fixture.change_log.items.len);
}

test "datepicker closes via Escape" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = DatepickerFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.picker_state = try harness.app.new(DatepickerState, .{});
    fixture.cal_state = try harness.app.new(CalendarState, .{ .view_year = 2024, .view_month = 8 });
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = .{ .year = 2024, .month = 8, .day = 1 } });
    try harness.setRoot(&fixture, DatepickerFixture.render);

    try harness.clickOn("datepicker-trigger");
    try std.testing.expect(harness.app.read(DatepickerState, fixture.picker_state).open);
    try harness.keyDown(.escape);
    try std.testing.expect(!harness.app.read(DatepickerState, fixture.picker_state).open);
}

test "datepicker closes via outside click" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = DatepickerFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.picker_state = try harness.app.new(DatepickerState, .{});
    fixture.cal_state = try harness.app.new(CalendarState, .{ .view_year = 2024, .view_month = 8 });
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = .{ .year = 2024, .month = 8, .day = 1 } });
    try harness.setRoot(&fixture, DatepickerFixture.render);

    try harness.clickOn("datepicker-trigger");
    try std.testing.expect(harness.app.read(DatepickerState, fixture.picker_state).open);
    try harness.click(5, 5);
    try std.testing.expect(!harness.app.read(DatepickerState, fixture.picker_state).open);
}
