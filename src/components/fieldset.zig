//! Fieldset compound parts: root container and legend. Disabled state is
//! exposed via `StyleState` only — callers apply muted styles to children.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const a11y_mod = @import("../a11y.zig");

const Div = div_mod.Div;

pub const StyleState = struct {
    disabled: bool = false,
};

pub const RootStyleFn = *const fn (state: StyleState) style_mod.Style;
pub const LegendStyleFn = *const fn (state: StyleState) style_mod.Style;

pub const RootProps = struct {
    id: []const u8,
    disabled: bool = false,
    /// Accessible name for the group (often mirrors the legend text).
    a11y_label: ?[]const u8 = null,
    /// When set, the group is named by the legend element id.
    legend_id: ?[]const u8 = null,
    style_fn: ?RootStyleFn = null,
};

pub const LegendProps = struct {
    id: []const u8,
    disabled: bool = false,
    a11y_label: ?[]const u8 = null,
    style_fn: ?LegendStyleFn = null,
};

/// Grouping container for related fields.
pub fn root(arena: std.mem.Allocator, props: RootProps) *Div {
    const state = StyleState{ .disabled = props.disabled };
    var d = div_mod.div(arena)
        .withId(props.id)
        .flexCol()
        .wFull()
        .role(.group);
    if (props.a11y_label) |label| {
        d = d.a11yName(label);
    } else if (props.legend_id) |legend_id| {
        d = d.a11yLabelledBy(element.elementId(legend_id));
    }
    if (props.disabled) d = d.a11yDisabled(true);
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    }
    return d;
}

/// Legend heading for the fieldset.
pub fn legend(arena: std.mem.Allocator, props: LegendProps) *Div {
    const state = StyleState{ .disabled = props.disabled };
    var d = div_mod.div(arena)
        .withId(props.id)
        .role(.heading)
        .a11yHeadingLevel(2);
    if (props.a11y_label) |label| d = d.a11yName(label);
    if (props.disabled) d = d.a11yDisabled(true);
    if (props.style_fn) |style_fn| {
        d = d.withStyle(style_fn(state));
    }
    return d;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const FieldsetFixture = struct {
    disabled: bool = false,

    fn rootStyle(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .percent = 100 };
        s.padding = .{
            .top = .{ .px = 8 },
            .right = .{ .px = 8 },
            .bottom = .{ .px = 8 },
            .left = .{ .px = 8 },
        };
        if (state.disabled) s.background = color.Rgba.fromHex(0xf3f4f6);
        return s;
    }

    fn legendStyle(state: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .percent = 100 };
        s.height = .{ .px = 24 };
        s.background = if (state.disabled)
            color.Rgba.fromHex(0xd1d5db)
        else
            color.Rgba.fromHex(0xe5e7eb);
        return s;
    }

    fn childStyle(_: StyleState) style_mod.Style {
        var s = style_mod.Style{};
        s.width = .{ .percent = 100 };
        s.height = .{ .px = 28 };
        s.background = color.Rgba.fromHex(0xffffff);
        return s;
    }

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
        const self: *FieldsetFixture = @ptrCast(@alignCast(ctx.?));

        const fieldset_root = root(arena, .{
            .id = "account-fieldset",
            .disabled = self.disabled,
            .legend_id = "account-legend",
            .style_fn = rootStyle,
        })
            .childDiv(legend(arena, .{
                .id = "account-legend",
                .disabled = self.disabled,
                .a11y_label = "Account",
                .style_fn = legendStyle,
            }).interactive())
            .childDiv(div_mod.div(arena)
                .withId("account-name")
                .interactive()
                .withStyle(childStyle(.{})))
            .childDiv(div_mod.div(arena)
                .withId("account-email")
                .interactive()
                .withStyle(childStyle(.{})));

        return div_mod.div(arena).sizePx(320, 160).padPx(12).childDiv(fieldset_root).any();
    }
};

test "fieldset exposes group and legend a11y" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 320, .height = 160 });
    defer harness.deinit();

    var fixture = FieldsetFixture{};
    try harness.setRoot(&fixture, FieldsetFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.group, harness.a11yRole("account-fieldset").?);
    try std.testing.expectEqualStrings("Account", harness.a11yName("account-fieldset").?);
    try std.testing.expectEqual(a11y_mod.Role.heading, harness.a11yRole("account-legend").?);
    try std.testing.expectEqual(@as(u8, 2), harness.a11yNode("account-legend").?.heading_level.?);
    try std.testing.expectEqualStrings("Account", harness.a11yName("account-legend").?);
}

test "fieldset legend and children structure" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 320, .height = 160 });
    defer harness.deinit();

    var fixture = FieldsetFixture{};
    try harness.setRoot(&fixture, FieldsetFixture.render);

    try std.testing.expect(harness.hitboxBounds(element.elementId("account-legend")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("account-name")) != null);
    try std.testing.expect(harness.hitboxBounds(element.elementId("account-email")) != null);
}

test "fieldset disabled style state" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 320, .height = 160 });
    defer harness.deinit();

    var fixture = FieldsetFixture{ .disabled = true };
    try harness.setRoot(&fixture, FieldsetFixture.render);

    const legend_bounds = harness.hitboxBounds(element.elementId("account-legend")).?;
    const name_bounds = harness.hitboxBounds(element.elementId("account-name")).?;
    try std.testing.expect(name_bounds.origin.y >= legend_bounds.origin.y);
    try std.testing.expect(harness.hitboxBounds(element.elementId("account-email")) != null);
}
