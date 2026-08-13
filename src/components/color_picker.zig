//! Headless color picker: HSV channel sliders, swatch trigger, optional overlay panel.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const value_mod = @import("../value.zig");
const overlay_mod = @import("../overlay.zig");
const color = @import("../color.zig");
const geometry = @import("../geometry.zig");
const slider_mod = @import("slider.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Rgba = color.Rgba;
const Hsv = color.Hsv;
const Pixels = geometry.Pixels;
const Bounds = geometry.Bounds;
const Size = geometry.Size;

pub const Value = value_mod.Value(Rgba);

pub const ChangeHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, color: Rgba) void,
};

pub const ColorPickerState = struct {
    open: bool = false,

    pub fn openPicker(self: *ColorPickerState) void {
        self.open = true;
    }

    pub fn close(self: *ColorPickerState) void {
        self.open = false;
    }
};

pub const Channel = enum {
    hue,
    saturation,
    value,

    fn range(self: Channel) struct { min: f32, max: f32, step: f32 } {
        return switch (self) {
            .hue => .{ .min = 0, .max = 360, .step = 1 },
            .saturation, .value => .{ .min = 0, .max = 1, .step = 0.01 },
        };
    }

    fn component(self: Channel, hsv: Hsv) f32 {
        return switch (self) {
            .hue => hsv.h,
            .saturation => hsv.s,
            .value => hsv.v,
        };
    }

    fn withComponent(self: Channel, hsv: Hsv, next: f32) Hsv {
        return switch (self) {
            .hue => .{ .h = next, .s = hsv.s, .v = hsv.v },
            .saturation => .{ .h = hsv.h, .s = next, .v = hsv.v },
            .value => .{ .h = hsv.h, .s = hsv.s, .v = next },
        };
    }
};

pub const SliderStyleState = slider_mod.StyleState;
pub const SliderStyleFn = slider_mod.StyleFn;

pub const SliderChannelProps = struct {
    id: []const u8,
    channel: Channel,
    value: Value,
    disabled: bool = false,
    on_change: ?ChangeHandler = null,
    style_fn: ?SliderStyleFn = null,
};

pub const PickerProps = struct {
    id: []const u8,
    value: Value,
    disabled: bool = false,
    on_change: ?ChangeHandler = null,
    hue_style_fn: ?SliderStyleFn = null,
    saturation_style_fn: ?SliderStyleFn = null,
    value_style_fn: ?SliderStyleFn = null,
};

pub const SwatchStyleState = struct {
    color: Rgba = .{},
    hovered: bool = false,
    focused: bool = false,
    disabled: bool = false,
    open: bool = false,
};

pub const SwatchStyleFn = *const fn (state: SwatchStyleState) style_mod.Style;

pub const SwatchProps = struct {
    id: []const u8,
    value: Value,
    disabled: bool = false,
    open: bool = false,
    style_fn: ?SwatchStyleFn = null,
};

pub const SwatchPickerProps = struct {
    id: []const u8,
    trigger_id: []const u8,
    state: app_mod.Entity(ColorPickerState),
    value: Value,
    overlays: *overlay_mod.OverlayStack,
    app: *App,
    frame: *const element.FrameState,
    input: *element.InputState,
    viewport: Size(Pixels),
    z_index: i32 = 75,
    trap_focus: bool = true,
    modal: bool = true,
    disabled: bool = false,
    on_change: ?ChangeHandler = null,
    panel_style: ?*const fn (open: bool) style_mod.Style = null,
    hue_style_fn: ?SliderStyleFn = null,
    saturation_style_fn: ?SliderStyleFn = null,
    value_style_fn: ?SliderStyleFn = null,
};

const ChannelControl = struct {
    app: *App,
    channel: Channel,
    value: Value,
    on_change: ?ChangeHandler,

    fn onChange(ctx: ?*anyopaque, next: f32) void {
        const self: *ChannelControl = @ptrCast(@alignCast(ctx.?));
        const current = self.value.get(self.app);
        const hsv = color.rgbToHsv(current);
        const range = self.channel.range();
        const clamped = std.math.clamp(next, range.min, range.max);
        const updated = color.hsvToRgba(self.channel.withComponent(hsv, clamped), current.a);
        _ = self.value.setIfUncontrolled(self.app, updated);
        if (self.on_change) |handler| handler.func(handler.ctx, updated);
    }
};

pub fn readColor(app: *App, value: Value) Rgba {
    return value.get(app);
}

pub fn close(app: *App, state: app_mod.Entity(ColorPickerState)) void {
    app.read(ColorPickerState, state).close();
    app.notify(state.id);
}

pub fn open(app: *App, state: app_mod.Entity(ColorPickerState)) void {
    app.read(ColorPickerState, state).openPicker();
    app.notify(state.id);
}

pub fn toggle(app: *App, state: app_mod.Entity(ColorPickerState)) void {
    const s = app.read(ColorPickerState, state);
    if (s.open) s.close() else s.openPicker();
    app.notify(state.id);
}

pub fn sliderChannel(
    arena: std.mem.Allocator,
    app: *App,
    input: *element.InputState,
    props: SliderChannelProps,
) *Div {
    const rgba = props.value.get(app);
    const hsv = color.rgbToHsv(rgba);
    const range = props.channel.range();
    const channel_value = props.channel.component(hsv);

    const control = arena.create(ChannelControl) catch @panic("frame arena OOM");
    control.* = .{
        .app = app,
        .channel = props.channel,
        .value = props.value,
        .on_change = props.on_change,
    };

    return slider_mod.slider(arena, app, input, .{
        .id = props.id,
        .value = .{ .controlled = channel_value },
        .min = range.min,
        .max = range.max,
        .step = range.step,
        .disabled = props.disabled,
        .on_change = .{ .ctx = control, .func = ChannelControl.onChange },
        .style_fn = props.style_fn,
    });
}

pub fn colorPicker(
    arena: std.mem.Allocator,
    app: *App,
    input: *element.InputState,
    props: PickerProps,
) *Div {
    const hue_id = std.fmt.allocPrint(arena, "{s}-hue", .{props.id}) catch @panic("frame arena OOM");
    const sat_id = std.fmt.allocPrint(arena, "{s}-sat", .{props.id}) catch @panic("frame arena OOM");
    const val_id = std.fmt.allocPrint(arena, "{s}-val", .{props.id}) catch @panic("frame arena OOM");

    return div_mod.div(arena)
        .flexCol()
        .gapPx(8)
        .childDiv(sliderChannel(arena, app, input, .{
            .id = hue_id,
            .channel = .hue,
            .value = props.value,
            .disabled = props.disabled,
            .on_change = props.on_change,
            .style_fn = props.hue_style_fn,
        }))
        .childDiv(sliderChannel(arena, app, input, .{
            .id = sat_id,
            .channel = .saturation,
            .value = props.value,
            .disabled = props.disabled,
            .on_change = props.on_change,
            .style_fn = props.saturation_style_fn,
        }))
        .childDiv(sliderChannel(arena, app, input, .{
            .id = val_id,
            .channel = .value,
            .value = props.value,
            .disabled = props.disabled,
            .on_change = props.on_change,
            .style_fn = props.value_style_fn,
        }));
}

pub fn colorSwatch(
    arena: std.mem.Allocator,
    app: *App,
    input: *element.InputState,
    props: SwatchProps,
) *Div {
    const id = element.elementId(props.id);
    const rgba = props.value.get(app);

    var d = div_mod.div(arena).withId(props.id).interactive();
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(.{
            .color = rgba,
            .hovered = input.isHovered(id),
            .focused = false,
            .disabled = props.disabled,
            .open = props.open,
        }));
    } else {
        var s = style_mod.Style{};
        s.width = .{ .px = 32 };
        s.height = .{ .px = 32 };
        s.background = rgba;
        s.corner_radii = geometry.Corners(Pixels).all(4);
        s.border_widths = geometry.Edges(Pixels).all(1);
        s.border_color = Rgba.fromHex(0xcccccc);
        d = d.withStyle(s);
    }

    return d;
}

const OverlayHost = struct {
    app: *App,
    picker_state: app_mod.Entity(ColorPickerState),
    value: Value,
    frame: *const element.FrameState,
    viewport: Size(Pixels),
    trigger_id: []const u8,
    panel_id: []const u8,
    picker_id: []const u8,
    input: *element.InputState,
    on_change: ?ChangeHandler,
    panel_style: ?*const fn (open: bool) style_mod.Style,
    hue_style_fn: ?SliderStyleFn,
    saturation_style_fn: ?SliderStyleFn,
    value_style_fn: ?SliderStyleFn,

    fn dismiss(ctx: ?*anyopaque) void {
        const self: *OverlayHost = @ptrCast(@alignCast(ctx.?));
        close(self.app, self.picker_state);
    }

    fn dismissMouseDown(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        dismiss(ctx);
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator) anyerror!element.Element {
        const self: *OverlayHost = @ptrCast(@alignCast(ctx.?));
        const is_open = self.app.read(ColorPickerState, self.picker_state).open;
        if (!is_open) return div_mod.div(arena).sizePx(0, 0).any();

        var backdrop = div_mod.div(arena)
            .withId("color-picker-backdrop")
            .absolute()
            .wFull()
            .hFull()
            .interactive()
            .onMouseDown(self, dismissMouseDown);

        var panel = div_mod.div(arena)
            .withId(self.panel_id)
            .absolute()
            .interactive();
        if (self.panel_style) |style_fn| {
            panel = panel.withStyle(style_fn(true));
        } else {
            var s = style_mod.Style{};
            s.width = .{ .px = 220 };
            s.min_height = .{ .px = 120 };
            s.background = Rgba.fromHex(0xffffff);
            s.corner_radii = geometry.Corners(Pixels).all(6);
            s.padding = .{
                .top = .{ .px = 12 },
                .right = .{ .px = 12 },
                .bottom = .{ .px = 12 },
                .left = .{ .px = 12 },
            };
            panel = panel.withStyle(s);
        }
        panel = panel.onClick(null, struct {
            fn swallow(_: ?*anyopaque, _: *const platform.MouseButtonEvent) void {}
        }.swallow);

        const picker = colorPicker(arena, self.app, self.input, .{
            .id = self.picker_id,
            .value = self.value,
            .on_change = self.on_change,
            .hue_style_fn = self.hue_style_fn,
            .saturation_style_fn = self.saturation_style_fn,
            .value_style_fn = self.value_style_fn,
        });
        panel = panel.childDiv(picker);

        if (triggerBounds(self.frame, self.trigger_id)) |bounds| {
            var s = panel.style;
            s.position = .absolute;
            s.inset.top = .{ .px = bounds.origin.y + bounds.size.height + 4 };
            s.inset.left = .{ .px = bounds.origin.x };
            panel.style = s;
        } else {
            var s = panel.style;
            s.position = .absolute;
            s.inset.top = .{ .px = self.viewport.height / 2 - 60 };
            s.inset.left = .{ .px = self.viewport.width / 2 - 110 };
            panel.style = s;
        }

        return backdrop.childDiv(panel).any();
    }
};

const TriggerHost = struct {
    app: *App,
    state: app_mod.Entity(ColorPickerState),

    fn onToggle(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *TriggerHost = @ptrCast(@alignCast(ctx.?));
        toggle(self.app, self.state);
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

fn registerOverlay(arena: std.mem.Allocator, props: SwatchPickerProps) !void {
    const is_open = props.app.read(ColorPickerState, props.state).open;
    if (!is_open) return;

    const picker_id = std.fmt.allocPrint(arena, "{s}-panel", .{props.id}) catch @panic("frame arena OOM");

    const host = arena.create(OverlayHost) catch @panic("frame arena OOM");
    host.* = .{
        .app = props.app,
        .picker_state = props.state,
        .value = props.value,
        .frame = props.frame,
        .viewport = props.viewport,
        .trigger_id = props.trigger_id,
        .panel_id = props.id,
        .picker_id = picker_id,
        .input = props.input,
        .on_change = props.on_change,
        .panel_style = props.panel_style,
        .hue_style_fn = props.hue_style_fn,
        .saturation_style_fn = props.saturation_style_fn,
        .value_style_fn = props.value_style_fn,
    };
    try props.overlays.push(.{
        .id = overlay_mod.overlayId(props.id),
        .z_index = props.z_index,
        .trap_focus = props.trap_focus,
        .modal = props.modal,
        .ctx = host,
        .render = OverlayHost.render,
        .on_dismiss = OverlayHost.dismiss,
    });
}

/// Zero-size main-tree placeholder; registers the picker overlay when open.
pub fn colorPickerOverlay(arena: std.mem.Allocator, props: SwatchPickerProps) !*Div {
    try registerOverlay(arena, props);
    return div_mod.div(arena).sizePx(0, 0);
}

/// Wire a swatch trigger and register the overlay picker when open.
pub fn colorSwatchWithPicker(
    arena: std.mem.Allocator,
    props: SwatchPickerProps,
    trigger: *Div,
) !*Div {
    const trigger_host = arena.create(TriggerHost) catch @panic("frame arena OOM");
    trigger_host.* = .{
        .app = props.app,
        .state = props.state,
    };
    _ = trigger.onClick(trigger_host, TriggerHost.onToggle);

    try registerOverlay(arena, props);
    return trigger;
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

fn channelStyle(state: SliderStyleState) style_mod.Style {
    var s = style_mod.Style{};
    s.width = .{ .px = 180 };
    s.height = .{ .px = 16 };
    s.background = Rgba.fromHex(0xdddddd);
    _ = state;
    return s;
}

const PickerFixture = struct {
    harness: *testing_mod.Harness = undefined,
    value_entity: app_mod.Entity(Value.Store) = undefined,
    controlled_value: ?Rgba = null,
    change_log: std.ArrayList(Rgba) = .empty,

    fn deinit(self: *PickerFixture) void {
        self.change_log.deinit(std.testing.allocator);
    }

    fn onChange(ctx: ?*anyopaque, c: Rgba) void {
        const self: *PickerFixture = @ptrCast(@alignCast(ctx.?));
        self.change_log.append(std.testing.allocator, c) catch unreachable;
    }

    fn currentValue(self: *PickerFixture) Value {
        return if (self.controlled_value) |v|
            .{ .controlled = v }
        else
            .{ .uncontrolled = self.value_entity };
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *PickerFixture = @ptrCast(@alignCast(ctx.?));

        const panel = colorPicker(arena, &harness.app, &harness.input, .{
            .id = "test-picker",
            .value = self.currentValue(),
            .on_change = .{ .ctx = self, .func = onChange },
            .hue_style_fn = channelStyle,
            .saturation_style_fn = channelStyle,
            .value_style_fn = channelStyle,
        });

        return div_mod.div(arena)
            .sizePx(300, 200)
            .padPx(20)
            .childDiv(panel)
            .any();
    }
};

const SwatchFixture = struct {
    harness: *testing_mod.Harness = undefined,
    picker_state: app_mod.Entity(ColorPickerState) = undefined,
    value_entity: app_mod.Entity(Value.Store) = undefined,
    change_log: std.ArrayList(Rgba) = .empty,

    fn deinit(self: *SwatchFixture) void {
        self.change_log.deinit(std.testing.allocator);
    }

    fn onChange(ctx: ?*anyopaque, c: Rgba) void {
        const self: *SwatchFixture = @ptrCast(@alignCast(ctx.?));
        self.change_log.append(std.testing.allocator, c) catch unreachable;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *SwatchFixture = @ptrCast(@alignCast(ctx.?));
        const value: Value = .{ .uncontrolled = self.value_entity };

        var trigger = colorSwatch(arena, &harness.app, &harness.input, .{
            .id = "color-swatch",
            .value = value,
            .open = harness.app.read(ColorPickerState, self.picker_state).open,
        });
        trigger = try colorSwatchWithPicker(arena, .{
            .id = "color-picker-popover",
            .trigger_id = "color-swatch",
            .state = self.picker_state,
            .value = value,
            .overlays = &harness.overlays,
            .app = &harness.app,
            .frame = &harness.frame,
            .input = &harness.input,
            .viewport = harness.viewport,
            .on_change = .{ .ctx = self, .func = onChange },
            .hue_style_fn = channelStyle,
            .saturation_style_fn = channelStyle,
            .value_style_fn = channelStyle,
        }, trigger);

        return div_mod.div(arena).sizePx(400, 300).padPx(20).childDiv(trigger).any();
    }
};

test "changing hue updates rgba value" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = PickerFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = Rgba.red });
    try harness.setRoot(&fixture, PickerFixture.render);

    const before = harness.app.read(Value.Store, fixture.value_entity).value;
    try std.testing.expectApproxEqAbs(1.0, before.r, 0.01);

    try harness.focusById(element.elementId("test-picker-hue"));
    try harness.keyDown(.right);
    try harness.renderFrame();

    const after = harness.app.read(Value.Store, fixture.value_entity).value;
    const before_hsv = color.rgbToHsv(before);
    const after_hsv = color.rgbToHsv(after);
    try std.testing.expect(after_hsv.h > before_hsv.h or after_hsv.h < before_hsv.h - 350);
    try std.testing.expect(fixture.change_log.items.len > 0);
}

test "saturation slider changes rgba value" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 200 });
    defer harness.deinit();

    var fixture = PickerFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = Rgba.red });
    try harness.setRoot(&fixture, PickerFixture.render);

    try harness.focusById(element.elementId("test-picker-sat"));
    try harness.keyDown(.left);
    try harness.renderFrame();

    const after = harness.app.read(Value.Store, fixture.value_entity).value;
    const hsv = color.rgbToHsv(after);
    try std.testing.expect(hsv.s < 1.0);
}

test "swatch click opens overlay picker" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = SwatchFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.picker_state = try harness.app.new(ColorPickerState, .{});
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = Rgba.fromHex(0x336699) });
    try harness.setRoot(&fixture, SwatchFixture.render);

    try std.testing.expect(!harness.app.read(ColorPickerState, fixture.picker_state).open);
    try std.testing.expectEqual(@as(usize, 0), harness.overlays.layers.items.len);

    try harness.clickOn("color-swatch");
    try std.testing.expect(harness.app.read(ColorPickerState, fixture.picker_state).open);
    try std.testing.expectEqual(@as(usize, 1), harness.overlays.layers.items.len);
    try std.testing.expect(harness.hitboxBounds(element.elementId("color-picker-popover")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("color-picker-popover-panel-hue")) != null);
}

test "overlay hue slider updates color value" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 400, .height = 300 });
    defer harness.deinit();

    var fixture = SwatchFixture{ .harness = &harness };
    defer fixture.deinit();
    fixture.picker_state = try harness.app.new(ColorPickerState, .{});
    fixture.value_entity = try harness.app.new(Value.Store, .{ .value = Rgba.red });
    try harness.setRoot(&fixture, SwatchFixture.render);

    try harness.clickOn("color-swatch");
    const before = harness.app.read(Value.Store, fixture.value_entity).value;

    const hue_bounds = harness.hitboxBounds(element.elementId("color-picker-popover-panel-hue")) orelse return error.ElementNotFound;
    const x = hue_bounds.origin.x + hue_bounds.size.width * 0.8;
    const y = hue_bounds.origin.y + hue_bounds.size.height / 2;
    try harness.click(x, y);
    try harness.renderFrame();

    const after = harness.app.read(Value.Store, fixture.value_entity).value;
    const before_h = color.rgbToHsv(before).h;
    const after_h = color.rgbToHsv(after).h;
    try std.testing.expect(after_h > before_h or (after_h < 5 and before_h > 355));
}
