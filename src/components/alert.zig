//! Headless alert banner: variant styling, optional dismiss control, assertive
//! live region for announcements.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const color = @import("../color.zig");

const Div = div_mod.Div;

pub const Variant = enum {
    default,
    info,
    success,
    warning,
    error_,
};

pub const StyleState = struct {
    variant: Variant = .default,
};

pub const StyleFn = *const fn (state: StyleState) style_mod.Style;
pub const CloseStyleFn = *const fn () style_mod.Style;
pub const CloseHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque) void,
};

pub const Props = struct {
    id: []const u8,
    variant: Variant = .default,
    /// When false, render a zero-size placeholder (caller-driven visibility).
    visible: bool = true,
    a11y_label: ?[]const u8 = null,
    style_fn: ?StyleFn = null,
    on_close: ?CloseHandler = null,
    close_style_fn: ?CloseStyleFn = null,
};

pub fn defaultStyleFor(variant: Variant) style_mod.Style {
    var s = style_mod.Style{};
    s.padding = .{
        .top = .{ .px = 10 },
        .right = .{ .px = 16 },
        .bottom = .{ .px = 10 },
        .left = .{ .px = 16 },
    };
    s.background = switch (variant) {
        .default => color.Rgba.fromHex(0xf3f4f6),
        .info => color.Rgba.fromHex(0xecfeff),
        .success => color.Rgba.fromHex(0xf0fdf4),
        .warning => color.Rgba.fromHex(0xfffbeb),
        .error_ => color.Rgba.fromHex(0xfef2f2),
    };
    return s;
}

const CloseClick = struct {
    on_close: CloseHandler,

    fn onClick(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *CloseClick = @ptrCast(@alignCast(ctx.?));
        self.on_close.func(self.on_close.ctx);
    }
};

pub fn alert(arena: std.mem.Allocator, props: Props) *Div {
    if (!props.visible) {
        return div_mod.div(arena).withId(props.id).sizePx(0, 0);
    }

    const state = StyleState{ .variant = props.variant };
    var root = div_mod.div(arena)
        .withId(props.id)
        .flexRow()
        .wFull()
        .role(.group)
        .a11yLive(.assertive);
    if (props.a11y_label) |label| root = root.a11yName(label);

    if (props.style_fn) |style_fn| {
        root = root.withStyle(style_fn(state));
    } else {
        root = root.withStyle(defaultStyleFor(props.variant));
    }

    if (props.on_close) |handler| {
        const close_id = std.fmt.allocPrint(arena, "{s}-close", .{props.id}) catch @panic("frame arena OOM");
        var close_btn = div_mod.div(arena)
            .withId(close_id)
            .interactive()
            .role(.button)
            .a11yName("Close");
        if (props.close_style_fn) |style_fn| {
            close_btn = close_btn.withStyle(style_fn());
        } else {
            var s = style_mod.Style{};
            s.width = .{ .px = 24 };
            s.height = .{ .px = 24 };
            close_btn = close_btn.withStyle(s);
        }
        const click = arena.create(CloseClick) catch @panic("frame arena OOM");
        click.* = .{ .on_close = handler };
        close_btn = close_btn.onClick(click, CloseClick.onClick);
        root = root.childDiv(close_btn);
    }

    return root;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing_mod = @import("../testing.zig");

test "alert dismiss invokes on_close" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 320, .height = 80 });
    defer harness.deinit();

    const Fixture = struct {
        visible: bool = true,
        closed: bool = false,

        fn onClose(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.closed = true;
            self.visible = false;
        }

        fn style(_: StyleState) style_mod.Style {
            return defaultStyleFor(.warning);
        }

        fn closeStyle() style_mod.Style {
            var s = style_mod.Style{};
            s.width = .{ .px = 28 };
            s.height = .{ .px = 28 };
            s.background = color.Rgba.fromHex(0x999999);
            return s;
        }

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, _: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return div_mod.div(arena).sizePx(320, 80).childDiv(alert(arena, .{
                .id = "warn",
                .variant = .warning,
                .visible = self.visible,
                .a11y_label = "Disk almost full",
                .style_fn = style,
                .on_close = .{ .ctx = self, .func = onClose },
                .close_style_fn = closeStyle,
            })).any();
        }
    };

    var fixture: Fixture = .{};
    try harness.setRoot(&fixture, Fixture.render);
    try std.testing.expectEqualStrings("Disk almost full", harness.a11yName("warn").?);

    try harness.clickOn("warn-close");
    try harness.renderFrame();
    try std.testing.expect(fixture.closed);
    try std.testing.expect(!fixture.visible);
}
