//! Headless group box: optional title + content container (fieldset-like).

const std = @import("std");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");

const Div = div_mod.Div;

pub const StyleState = struct {
    has_title: bool = false,
};

pub const RootStyleFn = *const fn (state: StyleState) style_mod.Style;
pub const TitleStyleFn = *const fn () style_mod.Style;
pub const ContentStyleFn = *const fn () style_mod.Style;

pub const Props = struct {
    id: []const u8,
    title: ?[]const u8 = null,
    root_style_fn: ?RootStyleFn = null,
    title_style_fn: ?TitleStyleFn = null,
    content_style_fn: ?ContentStyleFn = null,
};

/// Build a column with optional titled header and a content child slot.
/// Callers attach body content via `.childDiv` on the returned content div —
/// this helper returns the root; use `groupBoxParts` when you need the content handle.
pub fn groupBox(arena: std.mem.Allocator, props: Props) *Div {
    const parts = groupBoxParts(arena, props);
    return parts.root;
}

pub const Parts = struct {
    root: *Div,
    content: *Div,
};

pub fn groupBoxParts(arena: std.mem.Allocator, props: Props) Parts {
    const state = StyleState{ .has_title = props.title != null };
    var root = div_mod.div(arena)
        .withId(props.id)
        .flexCol()
        .wFull();
    if (props.root_style_fn) |style_fn| root = root.withStyle(style_fn(state));

    if (props.title) |title| {
        const title_id = std.fmt.allocPrint(arena, "{s}-title", .{props.id}) catch @panic("frame arena OOM");
        var title_div = div_mod.div(arena)
            .withId(title_id)
            .interactive()
            .role(.heading)
            .a11yName(title);
        if (props.title_style_fn) |style_fn| title_div = title_div.withStyle(style_fn());
        root = root.childDiv(title_div);
    }

    const content_id = std.fmt.allocPrint(arena, "{s}-content", .{props.id}) catch @panic("frame arena OOM");
    var content = div_mod.div(arena).withId(content_id).flexCol().wFull();
    if (props.content_style_fn) |style_fn| content = content.withStyle(style_fn());
    root = root.childDiv(content);

    return .{ .root = root, .content = content };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const element = @import("../element.zig");
const color = @import("../color.zig");

test "groupBox exposes title and content ids" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 240, .height = 120 });
    defer harness.deinit();

    const Fixture = struct {
        fn rootStyle(_: StyleState) style_mod.Style {
            var s = style_mod.Style{};
            s.padding = .{
                .top = .{ .px = 8 },
                .right = .{ .px = 8 },
                .bottom = .{ .px = 8 },
                .left = .{ .px = 8 },
            };
            s.background = color.Rgba.fromHex(0xfafafa);
            return s;
        }

        fn titleStyle() style_mod.Style {
            var s = style_mod.Style{};
            s.height = .{ .px = 20 };
            s.width = .{ .percent = 100 };
            return s;
        }

        fn contentStyle() style_mod.Style {
            var s = style_mod.Style{};
            s.min_height = .{ .px = 40 };
            s.width = .{ .percent = 100 };
            s.background = color.Rgba.fromHex(0xffffff);
            return s;
        }

        fn render(_: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
            const parts = groupBoxParts(arena, .{
                .id = "prefs",
                .title = "Preferences",
                .root_style_fn = rootStyle,
                .title_style_fn = titleStyle,
                .content_style_fn = contentStyle,
            });
            _ = parts.content.childDiv(div_mod.div(arena).withId("prefs-body").sizePx(100, 24).interactive());
            return div_mod.div(arena).sizePx(240, 120).childDiv(parts.root).any();
        }
    };

    var fixture: Fixture = .{};
    try harness.setRoot(&fixture, Fixture.render);
    try std.testing.expectEqualStrings("Preferences", harness.a11yName("prefs-title").?);
    try std.testing.expect(harness.hitboxBounds(element.elementId("prefs-body")) != null);
}
