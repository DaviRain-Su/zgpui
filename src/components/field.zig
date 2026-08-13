//! Compound field UI around `form.Field` meta: root, label, control slot,
//! description, and error message regions.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const label_mod = @import("label.zig");
const form_mod = @import("form.zig");
const a11y_mod = @import("../a11y.zig");

const Div = div_mod.Div;

/// UI validation state for a single field (store in app entities or inline).
pub const FieldState = struct {
    invalid: bool = false,
    dirty: bool = false,
    touched: bool = false,
    error_message: ?[]const u8 = null,

    pub fn fromFormMeta(meta: form_mod.FieldState) FieldState {
        return .{
            .invalid = meta.invalid,
            .dirty = meta.dirty,
            .touched = meta.touched,
            .error_message = meta.error_message,
        };
    }
};

pub const RootStyleState = struct {
    invalid: bool = false,
    dirty: bool = false,
    touched: bool = false,
};

pub const RootStyleFn = *const fn (state: RootStyleState) style_mod.Style;
pub const LabelStyleFn = label_mod.StyleFn;
pub const ControlStyleFn = *const fn (state: RootStyleState) style_mod.Style;
pub const DescriptionStyleFn = *const fn (state: RootStyleState) style_mod.Style;
pub const ErrorStyleFn = *const fn (state: RootStyleState) style_mod.Style;

pub const RootProps = struct {
    id: []const u8,
    state: FieldState = .{},
    style_fn: ?RootStyleFn = null,
};

pub const LabelProps = struct {
    id: []const u8,
    /// Associates the label with a control id (htmlFor-like).
    for_id: ?[]const u8 = null,
    frame: *const element.FrameState,
    style_fn: ?LabelStyleFn = null,
};

pub const ControlProps = struct {
    id: []const u8,
    state: FieldState = .{},
    style_fn: ?ControlStyleFn = null,
};

pub const DescriptionProps = struct {
    id: []const u8,
    state: FieldState = .{},
    style_fn: ?DescriptionStyleFn = null,
};

pub const ErrorProps = struct {
    id: []const u8,
    state: FieldState,
    style_fn: ?ErrorStyleFn = null,
};

fn rootStyleState(state: FieldState) RootStyleState {
    return .{
        .invalid = state.invalid,
        .dirty = state.dirty,
        .touched = state.touched,
    };
}

/// Attach validation semantics to a control Div (`invalid` + error help text).
pub fn applyValidationA11y(d: *Div, state: FieldState) *Div {
    var out = d.a11yInvalid(state.invalid);
    if (state.invalid) {
        if (state.error_message) |msg| {
            out = out.a11yDescription(msg);
        }
    }
    return out;
}

/// Vertical field container.
pub fn root(arena: std.mem.Allocator, props: RootProps) *Div {
    const style_state = rootStyleState(props.state);
    var d = div_mod.div(arena)
        .withId(props.id)
        .flexCol()
        .wFull();
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(style_state));
    }
    return d;
}

/// Label associated with a control via `for_id`.
pub fn label(arena: std.mem.Allocator, input: *element.InputState, props: LabelProps) *Div {
    return label_mod.label(arena, input, .{
        .id = props.id,
        .for_id = props.for_id,
        .frame = props.frame,
        .style_fn = props.style_fn,
    });
}

/// Slot wrapper for the actual control (input, select, etc.).
pub fn control(arena: std.mem.Allocator, props: ControlProps) *Div {
    const style_state = rootStyleState(props.state);
    var d = div_mod.div(arena).withId(props.id);
    d = applyValidationA11y(d, props.state);
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(style_state));
    }
    return d;
}

/// Helper/description text below the control.
pub fn description(arena: std.mem.Allocator, props: DescriptionProps) *Div {
    const style_state = rootStyleState(props.state);
    var d = div_mod.div(arena).withId(props.id);
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(style_state));
    }
    return d;
}

/// Error message region — rendered only when `state.invalid`.
pub fn errorMessage(arena: std.mem.Allocator, props: ErrorProps) *Div {
    if (!props.state.invalid) {
        return div_mod.div(arena).sizePx(0, 0);
    }
    const style_state = rootStyleState(props.state);
    const message = props.state.error_message orelse "Invalid";
    var d = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.label)
        .a11yName(message)
        .a11yLive(.assertive);
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(style_state));
    }
    return d;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");
const button_mod = @import("button.zig");

const FieldFixture = struct {
    harness: *testing_mod.Harness = undefined,
    invalid: bool = false,

    fn rootStyle(state: RootStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .percent = 100 };
        s.padding = .{
            .top = .{ .px = 4 },
            .right = .{ .px = 0 },
            .bottom = .{ .px = 4 },
            .left = .{ .px = 0 },
        };
        if (state.invalid) s.background = color.Rgba.fromHex(0xfff5f5);
        _ = state.dirty;
        _ = state.touched;
        return s;
    }

    fn errorStyle(_: RootStyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .percent = 100 };
        s.height = .{ .px = 20 };
        s.background = color.Rgba.fromHex(0xfee2e2);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *FieldFixture = @ptrCast(@alignCast(ctx.?));
        self.harness = harness;

        const state = FieldState{
            .invalid = self.invalid,
            .error_message = if (self.invalid) "Required" else null,
        };

        const field_root = root(arena, .{
            .id = "email-field",
            .state = state,
            .style_fn = rootStyle,
        })
            .childDiv(label(arena, &harness.input, .{
                .id = "email-label",
                .for_id = "email-input",
                .frame = &harness.frame,
            }))
            .childDiv(control(arena, .{
                .id = "email-control",
                .state = state,
            }).childDiv(applyValidationA11y(button_mod.button(arena, &harness.input, .{
                .id = "email-input",
                .style_fn = struct {
                    fn style(_: button_mod.StyleState) style_mod.Style {
                        var s = style_mod.Style{};
                        s.width = .{ .px = 160 };
                        s.height = .{ .px = 32 };
                        return s;
                    }
                }.style,
            }), state)))
            .childDiv(errorMessage(arena, .{
                .id = "email-error",
                .state = state,
                .style_fn = errorStyle,
            }));

        return div_mod.div(arena).sizePx(300, 120).padPx(12).childDiv(field_root).any();
    }
};

test "invalid field shows error hitbox and id" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 120 });
    defer harness.deinit();

    var fixture = FieldFixture{ .invalid = true };
    try harness.setRoot(&fixture, FieldFixture.render);

    try std.testing.expect(harness.hitboxBounds(element.elementId("email-error")) != null);
    const err_node = a11y_mod.findById(&harness.frame, element.elementId("email-error")).?;
    try std.testing.expectEqual(a11y_mod.Role.label, err_node.role);
    try std.testing.expectEqual(a11y_mod.LivePriority.assertive, err_node.live.?);
    try std.testing.expectEqualStrings("Required", a11y_mod.resolveName(err_node).?);
}

test "invalid field marks control invalid with error help" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 120 });
    defer harness.deinit();

    var fixture = FieldFixture{ .invalid = true };
    try harness.setRoot(&fixture, FieldFixture.render);

    const control_node = a11y_mod.findById(&harness.frame, element.elementId("email-input")).?;
    try std.testing.expect(control_node.invalid);
    try std.testing.expectEqualStrings("Required", control_node.description.?);
}

test "valid field omits error hitbox" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 120 });
    defer harness.deinit();

    var fixture = FieldFixture{ .invalid = false };
    try harness.setRoot(&fixture, FieldFixture.render);

    try std.testing.expect(harness.hitboxBounds(element.elementId("email-error")) == null);
}

test "FieldState syncs from form meta" {
    const meta = form_mod.FieldState{
        .invalid = true,
        .dirty = true,
        .touched = true,
        .error_message = "Too small",
    };
    const ui = FieldState.fromFormMeta(meta);
    try std.testing.expect(ui.invalid);
    try std.testing.expect(ui.dirty);
    try std.testing.expect(ui.touched);
    try std.testing.expectEqualStrings("Too small", ui.error_message.?);
}
