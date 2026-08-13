//! Headless avatar: sized container with an inner fallback slot (initials,
//! icon, etc.). No image loading — callers style via `style_fn`. Registers
//! `role(.img)` for VoiceOver (AppKit `AXImage`).

const std = @import("std");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const element = @import("../element.zig");
const geometry = @import("../geometry.zig");
const a11y_mod = @import("../a11y.zig");

const Div = div_mod.Div;
const Pixels = geometry.Pixels;

pub const Size = enum {
    sm,
    md,
    lg,
};

pub const StyleState = struct {
    size: Size = .md,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;
pub const FallbackStyleFn = *const fn (state: StyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    size: Size = .md,
    /// Accessible name for the avatar image (initials / person name).
    a11y_label: ?[]const u8 = null,
    style_fn: ?StyleFn = null,
    fallback_style_fn: ?FallbackStyleFn = null,
};

pub const Result = struct {
    root: *Div,
    /// Inner slot for initials or other fallback content (`{id}-fallback`).
    fallback: *Div,
};

/// Build avatar root + fallback slot. Add content to `fallback`.
pub fn avatar(arena: std.mem.Allocator, props: Props) Result {
    const state = StyleState{ .size = props.size };

    var root = div_mod.div(arena)
        .withId(props.id)
        .role(.img);
    if (props.a11y_label) |label| {
        root = root.a11yName(label);
    }
    if (props.style_fn) |style_fn| {
        root = root.withStyle(style_fn(state));
    } else {
        root = root.withStyle(defaultRootStyle(state));
    }

    const fallback_id = std.fmt.allocPrint(arena, "{s}-fallback", .{props.id}) catch @panic("frame arena OOM");
    var fallback = div_mod.div(arena)
        .withId(fallback_id)
        .itemsCenter()
        .justifyCenter();

    if (props.fallback_style_fn) |fallback_style_fn| {
        fallback = fallback.withStyle(fallback_style_fn(state));
    } else {
        fallback = fallback.withStyle(defaultFallbackStyle(state));
    }

    _ = root.childDiv(fallback);

    return .{ .root = root, .fallback = fallback };
}

fn defaultRootStyle(state: StyleState) style_mod.Style {
    const px: f32 = switch (state.size) {
        .sm => 32,
        .md => 40,
        .lg => 56,
    };
    var s = style_mod.Style{};
    s.width = .{ .px = px };
    s.height = .{ .px = px };
    s.corner_radii = geometry.Corners(Pixels).all(px / 2);
    return s;
}

fn defaultFallbackStyle(_: StyleState) style_mod.Style {
    var s = style_mod.Style{};
    s.width = .{ .percent = 100 };
    s.height = .{ .percent = 100 };
    return s;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

const AvatarFixture = struct {
    size: Size = .md,
    a11y_label: ?[]const u8 = null,

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
        const self: *AvatarFixture = @ptrCast(@alignCast(ctx.?));
        const av = avatar(arena, .{
            .id = "the-avatar",
            .size = self.size,
            .a11y_label = self.a11y_label,
            .style_fn = struct {
                fn style(state: StyleState) style_mod.Style {
                    var s = defaultRootStyle(state);
                    s.background = color.Rgba.fromHex(0x334155);
                    return s;
                }
            }.style,
        });
        _ = av.fallback.bg(color.Rgba.fromHex(0x64748b));
        const root = div_mod.div(arena)
            .sizePx(100, 100)
            .itemsCenter()
            .justifyCenter()
            .childDiv(av.root);
        return root.any();
    }
};

test "avatar sizes map to expected bounds" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer harness.deinit();

    inline for (.{ Size.sm, Size.md, Size.lg }) |size| {
        var fixture = AvatarFixture{ .size = size };
        try harness.setRoot(&fixture, AvatarFixture.render);

        const expected: f32 = switch (size) {
            .sm => 32,
            .md => 40,
            .lg => 56,
        };
        // Root avatar + fallback fill.
        try std.testing.expect(harness.scene.quads.items.len >= 1);
        const quad = harness.scene.quads.items[0];
        try std.testing.expectApproxEqAbs(expected, quad.bounds.size_w, 0.5);
        try std.testing.expectApproxEqAbs(expected, quad.bounds.size_h, 0.5);
    }
}

test "avatar exposes root and fallback ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const av = avatar(a, .{ .id = "user" });
    try std.testing.expect(av.root.id != null);
    try std.testing.expect(av.fallback.id != null);
    try std.testing.expectEqual(element.elementId("user"), av.root.id.?);
    try std.testing.expectEqual(element.elementId("user-fallback"), av.fallback.id.?);
}

test "avatar exposes img role and accessible name" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 100, .height = 100 });
    defer harness.deinit();

    var fixture = AvatarFixture{ .a11y_label = "Ada Lovelace" };
    try harness.setRoot(&fixture, AvatarFixture.render);

    try std.testing.expectEqual(a11y_mod.Role.img, harness.a11yRole("the-avatar").?);
    try std.testing.expectEqualStrings("Ada Lovelace", a11y_mod.resolveName(harness.a11yNode("the-avatar").?).?);
    try std.testing.expectEqualStrings("the-avatar", harness.a11yNode("the-avatar").?.identifier.?);
}
