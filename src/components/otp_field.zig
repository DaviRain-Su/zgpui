//! Headless OTP / PIN field: fixed-length character slots with typing advance,
//! backspace retreat, optional masking, and `on_complete` when filled.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const value_mod = @import("../value.zig");
const a11y_mod = @import("../a11y.zig");

const Div = div_mod.Div;
const App = app_mod.App;

pub const max_length = 8;
pub const default_length = 6;

pub const OtpStore = struct {
    chars: [max_length]u8 = undefined,
    len: usize = 0,

    pub fn text(self: *const OtpStore) []const u8 {
        return self.chars[0..self.len];
    }

    pub fn setText(self: *OtpStore, value: []const u8) void {
        const len = @min(value.len, max_length);
        @memcpy(self.chars[0..len], value[0..len]);
        self.len = len;
    }

    pub fn append(self: *OtpStore, ch: u8) bool {
        if (self.len >= max_length) return false;
        self.chars[self.len] = ch;
        self.len += 1;
        return true;
    }

    pub fn pop(self: *OtpStore) bool {
        if (self.len == 0) return false;
        self.len -= 1;
        return true;
    }
};

pub const Value = value_mod.Value(OtpStore);

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, text: []const u8) void,
};

pub const CompleteHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, text: []const u8) void,
};

pub const SlotStyleState = struct {
    index: usize = 0,
    filled: bool = false,
    active: bool = false,
    char: u8 = 0,
    masked: bool = false,
    hovered: bool = false,
    focused: bool = false,
    focus_visible: bool = false,
    disabled: bool = false,
};

pub const SlotStyleFn = *const fn (state: SlotStyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    value: Value,
    length: usize = default_length,
    mask: bool = false,
    disabled: bool = false,
    on_change: ?ChangeHandler = null,
    on_complete: ?CompleteHandler = null,
    slot_style_fn: ?SlotStyleFn = null,
    /// Accessible name for the OTP field (defaults to "One-time code").
    a11y_name: ?[]const u8 = null,
    a11y_placeholder: ?[]const u8 = null,
};

pub fn readText(app: *App, value: Value) []const u8 {
    return switch (value) {
        // Pointer capture keeps the slice inside the union / entity store.
        .controlled => |*store| store.text(),
        .uncontrolled => |entity| app.read(Value.Store, entity).value.text(),
    };
}

fn activeIndex(len: usize, length: usize) usize {
    if (len >= length) return length - 1;
    return len;
}

fn setText(
    app: *App,
    value: Value,
    text: []const u8,
    length: usize,
    on_change: ?ChangeHandler,
    on_complete: ?CompleteHandler,
) void {
    const capped_len = @min(text.len, @min(length, max_length));
    var store = value.get(app);
    store.setText(text[0..capped_len]);
    _ = value.setIfUncontrolled(app, store);
    if (on_change) |handler| handler.func(handler.ctx, store.text());
    if (store.len >= length) {
        if (on_complete) |handler| handler.func(handler.ctx, store.text());
    }
}

const Control = struct {
    app: *App,
    value: Value,
    length: usize,
    on_change: ?ChangeHandler,
    on_complete: ?CompleteHandler,
    focus_id: element.FocusId,

    fn readStore(self: *Control) OtpStore {
        return self.value.get(self.app);
    }

    fn notify(self: *Control, next: OtpStore) void {
        _ = self.value.setIfUncontrolled(self.app, next);
        if (self.on_change) |handler| handler.func(handler.ctx, next.text());
        if (next.len >= self.length) {
            if (self.on_complete) |handler| handler.func(handler.ctx, next.text());
        }
    }

    fn onKey(ctx: ?*anyopaque, event: *const platform.KeyEvent) bool {
        const self: *Control = @ptrCast(@alignCast(ctx.?));
        switch (event.key) {
            .backspace => {
                var next = self.readStore();
                if (!next.pop()) return false;
                self.notify(next);
                return true;
            },
            else => return false,
        }
    }

    fn onTextInput(ctx: ?*anyopaque, event: *const platform.TextInputEvent) bool {
        const self: *Control = @ptrCast(@alignCast(ctx.?));
        var next = self.readStore();
        var changed = false;
        for (event.text) |ch| {
            if (next.len >= self.length) break;
            if (next.append(ch)) changed = true;
        }
        if (!changed) return false;
        self.notify(next);
        return true;
    }
};

/// Renders a focusable OTP field with `length` slot children (`{id}-slot-{i}`).
pub fn otpField(
    arena: std.mem.Allocator,
    app: *App,
    input: *element.InputState,
    props: Props,
) *Div {
    const length = @min(props.length, max_length);
    const focus_id: element.FocusId = element.elementId(props.id);
    const store = props.value.get(app);
    const active = activeIndex(store.len, length);
    const progress = std.fmt.allocPrint(
        arena,
        "{d} of {d} digits",
        .{ store.len, length },
    ) catch @panic("frame arena OOM");

    var container = div_mod.div(arena)
        .withId(props.id)
        .flexRow()
        .role(.textbox)
        .a11yName(props.a11y_name orelse "One-time code")
        .a11yValueText(store.text())
        .a11yDescription(progress)
        .a11yRequired(true);
    if (props.a11y_placeholder) |placeholder| {
        container = container.a11yPlaceholder(placeholder);
    } else {
        const ph = std.fmt.allocPrint(arena, "Enter {d}-digit code", .{length}) catch @panic("frame arena OOM");
        container = container.a11yPlaceholder(ph);
    }

    if (props.disabled) {
        container = container.a11yDisabled(true);
    } else {
        const control = arena.create(Control) catch @panic("frame arena OOM");
        control.* = .{
            .app = app,
            .value = props.value,
            .length = length,
            .on_change = props.on_change,
            .on_complete = props.on_complete,
            .focus_id = focus_id,
        };
        container = container
            .interactive()
            .focusable(focus_id, .{ .ctx = control, .func = Control.onKey })
            .onTextInput(control, Control.onTextInput);
    }

    var i: usize = 0;
    while (i < length) : (i += 1) {
        const filled = i < store.len;
        const ch: u8 = if (filled) store.chars[i] else 0;
        const slot_state = SlotStyleState{
            .index = i,
            .filled = filled,
            .active = i == active and input.isFocused(focus_id),
            .char = ch,
            .masked = props.mask,
            .hovered = input.isHovered(focus_id),
            .focused = input.isFocused(focus_id),
            .focus_visible = input.focus_visible and input.isFocused(focus_id),
            .disabled = props.disabled,
        };

        const slot_id = std.fmt.allocPrint(arena, "{s}-slot-{d}", .{ props.id, i }) catch @panic("frame arena OOM");
        var slot = div_mod.div(arena)
            .withId(slot_id)
            .role(.group)
            .a11ySelected(i == active and input.isFocused(focus_id));
        if (filled) {
            const slot_value: []const u8 = if (props.mask)
                "•"
            else
                std.fmt.allocPrint(arena, "{c}", .{ch}) catch @panic("frame arena OOM");
            slot = slot.a11yValueText(slot_value);
        }
        if (props.slot_style_fn) |style_fn| {
            slot = slot.withStyle(style_fn(slot_state));
        }
        container = container.childDiv(slot);
    }

    return container;
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const OtpFixture = struct {
    harness: *testing_mod.Harness = undefined,
    state: app_mod.Entity(Value.Store) = undefined,
    controlled: ?OtpStore = null,
    length: usize = default_length,
    mask: bool = false,
    change_log: std.ArrayList([]const u8) = .empty,
    complete_log: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *OtpFixture) void {
        for (self.change_log.items) |s| std.testing.allocator.free(s);
        self.change_log.deinit(std.testing.allocator);
        for (self.complete_log.items) |s| std.testing.allocator.free(s);
        self.complete_log.deinit(std.testing.allocator);
    }

    fn onChange(ctx: ?*anyopaque, text: []const u8) void {
        const self: *OtpFixture = @ptrCast(@alignCast(ctx.?));
        const copy = std.testing.allocator.dupe(u8, text) catch unreachable;
        self.change_log.append(std.testing.allocator, copy) catch unreachable;
    }

    fn onComplete(ctx: ?*anyopaque, text: []const u8) void {
        const self: *OtpFixture = @ptrCast(@alignCast(ctx.?));
        const copy = std.testing.allocator.dupe(u8, text) catch unreachable;
        self.complete_log.append(std.testing.allocator, copy) catch unreachable;
    }

    fn slotStyle(state: SlotStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 28 };
        s.height = .{ .px = 36 };
        s.background = if (state.filled)
            color.Rgba.fromHex(0x00aa00)
        else if (state.active)
            color.Rgba.fromHex(0xccccff)
        else
            color.Rgba.fromHex(0xeeeeee);
        return s;
    }

    fn currentValue(self: *OtpFixture) Value {
        return if (self.controlled) |store|
            .{ .controlled = store }
        else
            .{ .uncontrolled = self.state };
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *OtpFixture = @ptrCast(@alignCast(ctx.?));
        const root = div_mod.div(arena)
            .sizePx(300, 80)
            .padPx(20)
            .childDiv(otpField(arena, &harness.app, &harness.input, .{
                .id = "otp",
                .value = self.currentValue(),
                .length = self.length,
                .mask = self.mask,
                .on_change = .{ .ctx = self, .func = onChange },
                .on_complete = .{ .ctx = self, .func = onComplete },
                .slot_style_fn = slotStyle,
            }));
        return root.any();
    }
};

test "otp field typing fills slots" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 80 });
    defer harness.deinit();

    var fixture = OtpFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(Value.Store, .{ .value = .{} });
    try harness.setRoot(&fixture, OtpFixture.render);

    try harness.focusById(element.elementId("otp"));
    try harness.textInput("123");
    try std.testing.expectEqualStrings("123", readText(&harness.app, fixture.currentValue()));
}

test "otp field on_complete fires when filled" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 80 });
    defer harness.deinit();

    var fixture = OtpFixture{ .harness = &harness, .length = 4 };
    defer fixture.deinit();
    fixture.state = try harness.app.new(Value.Store, .{ .value = .{} });
    try harness.setRoot(&fixture, OtpFixture.render);

    try harness.focusById(element.elementId("otp"));
    try harness.textInput("1234");
    try std.testing.expectEqual(@as(usize, 1), fixture.complete_log.items.len);
    try std.testing.expectEqualStrings("1234", fixture.complete_log.items[0]);
}

test "otp field backspace retreats" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 80 });
    defer harness.deinit();

    var fixture = OtpFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(Value.Store, .{ .value = .{} });
    try harness.setRoot(&fixture, OtpFixture.render);

    try harness.focusById(element.elementId("otp"));
    try harness.textInput("12");
    try harness.keyDown(.backspace);
    try std.testing.expectEqualStrings("1", readText(&harness.app, fixture.currentValue()));
}

test "otp field exposes textbox role" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 80 });
    defer harness.deinit();

    var fixture = OtpFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.state = try harness.app.new(Value.Store, .{ .value = .{} });
    try harness.setRoot(&fixture, OtpFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.textbox, harness.a11yRole("otp").?);
    try std.testing.expectEqualStrings("One-time code", harness.a11yName("otp").?);
    try std.testing.expectEqualStrings("0 of 6 digits", harness.a11yNode("otp").?.description.?);
    try std.testing.expect(harness.a11yNode("otp").?.required);
    try std.testing.expectEqualStrings("Enter 6-digit code", harness.a11yNode("otp").?.placeholder.?);
    try std.testing.expectEqual(a11y_mod.Role.group, harness.a11yRole("otp-slot-0").?);

    try harness.focusById(element.elementId("otp"));
    try harness.textInput("12");
    try std.testing.expectEqualStrings("2 of 6 digits", harness.a11yNode("otp").?.description.?);
    try std.testing.expectEqualStrings("1", harness.a11yNode("otp-slot-0").?.value_text.?);
    try std.testing.expectEqualStrings("2", harness.a11yNode("otp-slot-1").?.value_text.?);
    try std.testing.expectEqual(@as(?bool, true), harness.a11yNode("otp-slot-2").?.selected);
}
