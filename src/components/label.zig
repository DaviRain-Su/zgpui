//! Headless label: associates with a control id for accessibility semantics.
//! Optional `for_id` (htmlFor-like) — click focuses the target when it is
//! registered in the current frame's focusables.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");

const Div = div_mod.Div;

pub const StyleState = struct {};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;

pub const Props = struct {
    /// Stable identity for this label element.
    id: []const u8,
    /// When set, click focuses this control id (if focusable this frame).
    for_id: ?[]const u8 = null,
    /// Current frame (stable pointer; used to verify focus target at click time).
    frame: *const element.FrameState,
    style_fn: ?StyleFn = null,
};

const Activation = struct {
    input: *element.InputState,
    frame: *const element.FrameState,
    target: ?element.FocusId,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *Activation = @ptrCast(@alignCast(ctx.?));
        const target = self.target orelse return;
        if (self.frame.hasFocusable(target)) {
            self.input.focusFromPointer(target);
        }
    }
};

/// Build an interactive label div. Callers add text/icon children.
pub fn label(arena: std.mem.Allocator, input: *element.InputState, props: Props) *Div {
    const state = StyleState{};

    var d = div_mod.div(arena).withId(props.id).interactive();
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    }

    if (props.for_id) |for_id| {
        const activation = arena.create(Activation) catch @panic("frame arena OOM");
        activation.* = .{
            .input = input,
            .frame = props.frame,
            .target = element.elementId(for_id),
        };
        d = d.onClick(activation, Activation.onClick);
    }

    return d;
}

// ---------------------------------------------------------------------------
// Behavior tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");
const button_mod = @import("button.zig");

const LabelFixture = struct {
    harness: *testing_mod.Harness = undefined,
    with_target: bool = true,

    fn labelStyle(_: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .px = 120 };
        s.height = .{ .px = 24 };
        s.background = color.Rgba.fromHex(0xcccccc);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *LabelFixture = @ptrCast(@alignCast(ctx.?));
        self.harness = harness;

        var root = div_mod.div(arena)
            .sizePx(300, 120)
            .flexCol()
            .gapPx(8);

        if (self.with_target) {
            root = root.childDiv(button_mod.button(arena, &harness.input, .{
                .id = "the-input",
                .style_fn = struct {
                    fn style(_: button_mod.StyleState) style_mod.Style {
                        var s = style_mod.Style{};
                        s.width = .{ .px = 100 };
                        s.height = .{ .px = 32 };
                        return s;
                    }
                }.style,
            }));
        }

        root = root.childDiv(label(arena, &harness.input, .{
            .id = "the-label",
            .for_id = if (self.with_target) "the-input" else "missing-input",
            .frame = &harness.frame,
            .style_fn = labelStyle,
        }));

        return root.any();
    }
};

test "label click focuses associated control" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 120 });
    defer harness.deinit();

    var fixture = LabelFixture{};
    try harness.setRoot(&fixture, LabelFixture.render);

    try std.testing.expect(!harness.input.isFocused(element.elementId("the-input")));

    try harness.clickOn("the-label");
    try std.testing.expect(harness.input.isFocused(element.elementId("the-input")));
}

test "label click ignores missing focus target" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 300, .height = 120 });
    defer harness.deinit();

    var fixture = LabelFixture{ .with_target = false };
    try harness.setRoot(&fixture, LabelFixture.render);

    try harness.clickOn("the-label");
    try std.testing.expect(harness.input.focused == null);
}
