//! Headless accordion (compound parts): multiple expandable items with
//! single- or multi-expand modes. Open state is a bitmask via `OpenMaskValue`.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const value_mod = @import("../value.zig");

const Div = div_mod.Div;
const App = app_mod.App;

pub const Mode = enum {
    single,
    multi,
};

pub const OpenMaskValue = value_mod.MaskValue(u32);

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, mask: u32) void,
};

pub const TriggerStyleState = struct {
    open: bool = false,
    hovered: bool = false,
    focused: bool = false,
    disabled: bool = false,
};

pub const TriggerStyleFn = *const fn (state: TriggerStyleState) style_mod.Style;

pub const RootProps = struct {
    id: []const u8,
};

pub const TriggerProps = struct {
    id: []const u8,
    value: OpenMaskValue,
    index: usize,
    mode: Mode = .single,
    disabled: bool = false,
    on_change: ?ChangeHandler = null,
    style_fn: ?TriggerStyleFn = null,
};

pub fn openMask(app: *App, value: OpenMaskValue) u32 {
    return value.get(app);
}

pub fn isOpen(app: *App, value: OpenMaskValue, index: usize) bool {
    if (index >= 32) return false;
    const mask = openMask(app, value);
    return (mask & (@as(u32, 1) << @intCast(index))) != 0;
}

fn setMask(app: *App, value: OpenMaskValue, mask: u32, on_change: ?ChangeHandler) void {
    const current = openMask(app, value);
    if (current == mask) return;
    _ = value.setIfUncontrolled(app, mask);
    if (on_change) |handler| handler.func(handler.ctx, mask);
}

fn toggleAt(app: *App, value: OpenMaskValue, mode: Mode, index: usize, on_change: ?ChangeHandler) void {
    if (index >= 32) return;
    const bit = @as(u32, 1) << @intCast(index);
    var mask = openMask(app, value);
    switch (mode) {
        .single => {
            if (mask & bit != 0) {
                mask = 0;
            } else {
                mask = bit;
            }
        },
        .multi => {
            mask ^= bit;
        },
    }
    setMask(app, value, mask, on_change);
}

/// Vertical container for accordion items.
pub fn root(arena: std.mem.Allocator, props: RootProps) *Div {
    return div_mod.div(arena)
        .withId(props.id)
        .flexCol()
        .wFull();
}

const TriggerToggle = struct {
    app: *App,
    value: OpenMaskValue,
    index: usize,
    mode: Mode,
    on_change: ?ChangeHandler,

    fn activate(self: *TriggerToggle) void {
        toggleAt(self.app, self.value, self.mode, self.index, self.on_change);
    }

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *TriggerToggle = @ptrCast(@alignCast(ctx.?));
        self.activate();
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        if (event.key != .space and event.key != .enter) return false;
        const self: *TriggerToggle = @ptrCast(@alignCast(ctx.?));
        self.activate();
        return true;
    }
};

/// Focusable header that toggles the item's open state.
pub fn trigger(arena: std.mem.Allocator, app: *App, input: *const element.InputState, props: TriggerProps) *Div {
    const id = element.elementId(props.id);
    const focus_id: element.FocusId = id;
    const open = isOpen(app, props.value, props.index);

    const state = TriggerStyleState{
        .open = open,
        .hovered = input.isHovered(id),
        .focused = input.isFocused(focus_id),
        .disabled = props.disabled,
    };

    var d = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.button)
        .a11yExpanded(open);
    if (props.disabled) {
        d = d.a11yDisabled(true);
    }
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    }

    if (!props.disabled) {
        const toggle = arena.create(TriggerToggle) catch @panic("frame arena OOM");
        toggle.* = .{
            .app = app,
            .value = props.value,
            .index = props.index,
            .mode = props.mode,
            .on_change = props.on_change,
        };
        d = d.onClick(toggle, TriggerToggle.onClick)
            .focusable(focus_id, .{ .ctx = toggle, .func = TriggerToggle.onKey });
    }

    return d;
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const a11y_mod = @import("../a11y.zig");
const color = @import("../color.zig");

const AccordionFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(OpenMaskValue.Store) = undefined,
    controlled_mask: ?u32 = null,
    mode: Mode = .single,
    disabled: bool = false,
    change_log: std.ArrayList(u32) = .empty,

    const item_names = [_][]const u8{ "acc-a", "acc-b", "acc-c" };
    const content_names = [_][]const u8{ "content-a", "content-b", "content-c" };

    fn deinit(self: *AccordionFixture) void {
        self.change_log.deinit(std.testing.allocator);
    }

    fn onChange(ctx: ?*anyopaque, mask: u32) void {
        const self: *AccordionFixture = @ptrCast(@alignCast(ctx.?));
        self.change_log.append(std.testing.allocator, mask) catch unreachable;
    }

    fn triggerStyle(state: TriggerStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 200 };
        s.height = .{ .px = 30 };
        s.background = if (state.open) color.Rgba.fromHex(0xffffff) else color.Rgba.fromHex(0x444444);
        return s;
    }

    fn currentValue(self: *AccordionFixture) OpenMaskValue {
        return if (self.controlled_mask) |mask|
            .{ .controlled = mask }
        else
            .{ .uncontrolled = self.state };
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *AccordionFixture = @ptrCast(@alignCast(ctx.?));
        const app = &harness.app;
        const value = self.currentValue();

        var acc = root(arena, .{ .id = "accordion" });
        for (item_names, 0..) |name, i| {
            acc = acc.childDiv(trigger(arena, app, &harness.input, .{
                .id = name,
                .value = value,
                .index = i,
                .mode = self.mode,
                .disabled = self.disabled,
                .on_change = .{ .ctx = self, .func = onChange },
                .style_fn = triggerStyle,
            }));
            if (isOpen(app, value, i)) {
                acc = acc.childDiv(div_mod.div(arena)
                    .withId(content_names[i])
                    .interactive()
                    .wFull()
                    .hPx(40)
                    .bg(color.Rgba.fromHex(0x222222)));
            }
        }

        return div_mod.div(arena)
            .sizePx(220, 300)
            .childDiv(acc)
            .any();
    }
};

test "single-mode accordion opens exclusively on click" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 220, .height = 300 });
    defer harness.deinit();

    var fixture = AccordionFixture{ .harness = &harness, .mode = .single };
    defer fixture.deinit();
    fixture.state = try harness.app.new(OpenMaskValue.Store, .{ .value = 0 });
    try harness.setRoot(&fixture, AccordionFixture.render);

    try harness.clickOn("acc-b");
    try std.testing.expect(isOpen(&harness.app, fixture.currentValue(), 1));
    try std.testing.expect(!isOpen(&harness.app, fixture.currentValue(), 0));
    try std.testing.expect(harness.hitboxBounds(element.elementId("content-b")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("content-a")) == null);

    try harness.clickOn("acc-c");
    try std.testing.expect(isOpen(&harness.app, fixture.currentValue(), 2));
    try std.testing.expect(!isOpen(&harness.app, fixture.currentValue(), 1));
    try std.testing.expect(harness.hitboxBounds(element.elementId("content-c")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("content-b")) == null);
}

test "single-mode clicking open item closes it" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 220, .height = 300 });
    defer harness.deinit();

    var fixture = AccordionFixture{ .harness = &harness, .mode = .single };
    defer fixture.deinit();
    fixture.state = try harness.app.new(OpenMaskValue.Store, .{ .value = 1 << 1 });
    try harness.setRoot(&fixture, AccordionFixture.render);

    try harness.clickOn("acc-b");
    try std.testing.expectEqual(@as(u32, 0), openMask(&harness.app, fixture.currentValue()));
    try std.testing.expect(harness.hitboxBounds(element.elementId("content-b")) == null);
}

test "multi-mode accordion allows multiple open items" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 220, .height = 300 });
    defer harness.deinit();

    var fixture = AccordionFixture{ .harness = &harness, .mode = .multi };
    defer fixture.deinit();
    fixture.state = try harness.app.new(OpenMaskValue.Store, .{ .value = 0 });
    try harness.setRoot(&fixture, AccordionFixture.render);

    try harness.clickOn("acc-a");
    try harness.clickOn("acc-c");
    try std.testing.expect(isOpen(&harness.app, fixture.currentValue(), 0));
    try std.testing.expect(!isOpen(&harness.app, fixture.currentValue(), 1));
    try std.testing.expect(isOpen(&harness.app, fixture.currentValue(), 2));
    try std.testing.expect(harness.hitboxBounds(element.elementId("content-a")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("content-c")) != null);
}

test "accordion trigger toggles via keyboard" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 220, .height = 300 });
    defer harness.deinit();

    var fixture = AccordionFixture{ .harness = &harness, .mode = .single };
    defer fixture.deinit();
    fixture.state = try harness.app.new(OpenMaskValue.Store, .{ .value = 0 });
    try harness.setRoot(&fixture, AccordionFixture.render);

    try harness.focusById(element.elementId("acc-a"));
    try harness.keyDown(.enter);
    try std.testing.expect(isOpen(&harness.app, fixture.currentValue(), 0));
    try std.testing.expect(harness.hitboxBounds(element.elementId("content-a")) != null);
}

test "controlled accordion reports intent without updating itself" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 220, .height = 300 });
    defer harness.deinit();

    var fixture = AccordionFixture{ .harness = &harness, .mode = .single, .controlled_mask = 0 };
    defer fixture.deinit();
    fixture.state = try harness.app.new(OpenMaskValue.Store, .{ .value = 0 });
    try harness.setRoot(&fixture, AccordionFixture.render);

    try harness.clickOn("acc-b");
    try harness.renderFrame();

    try std.testing.expect(harness.hitboxBounds(element.elementId("content-b")) == null);
    try std.testing.expectEqual(@as(u32, 1 << 1), fixture.change_log.items[0]);
}

test "disabled accordion trigger does not toggle" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 220, .height = 300 });
    defer harness.deinit();

    var fixture = AccordionFixture{ .harness = &harness, .mode = .single, .disabled = true };
    defer fixture.deinit();
    fixture.state = try harness.app.new(OpenMaskValue.Store, .{ .value = 0 });
    try harness.setRoot(&fixture, AccordionFixture.render);

    try harness.clickOn("acc-a");
    try std.testing.expectEqual(@as(u32, 0), openMask(&harness.app, fixture.currentValue()));
    try std.testing.expectEqual(@as(usize, 0), fixture.change_log.items.len);
}

test "accordion trigger exposes button role and expanded state" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 220, .height = 300 });
    defer harness.deinit();

    var fixture = AccordionFixture{ .harness = &harness, .mode = .single };
    defer fixture.deinit();
    fixture.state = try harness.app.new(OpenMaskValue.Store, .{ .value = 0 });
    try harness.setRoot(&fixture, AccordionFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.button, harness.a11yRole("acc-a").?);
    try std.testing.expect(!harness.a11yNode("acc-a").?.expanded.?);

    try harness.clickOn("acc-a");
    try std.testing.expect(harness.a11yNode("acc-a").?.expanded.?);
    try std.testing.expect(!harness.a11yNode("acc-b").?.expanded.?);
}
