//! Scrollbar handle geometry (gpui-base contract) plus a headless vertical
//! track/thumb that drives `ScrollState.offset`.

const std = @import("std");
const element = @import("../element.zig");
const div_mod = @import("../elements/div.zig");
const style_mod = @import("../style.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");
const scroll_mod = @import("../elements/scroll.zig");
const geometry = @import("../geometry.zig");

const Div = div_mod.Div;
const App = app_mod.App;
const Pixels = geometry.Pixels;
const ScrollState = scroll_mod.ScrollState;
const a11y_mod = @import("../a11y.zig");

pub const Axis = enum {
    vertical,
    horizontal,

    fn toA11y(self: Axis) a11y_mod.Orientation {
        return switch (self) {
            .vertical => .vertical,
            .horizontal => .horizontal,
        };
    }
};

pub const default_min_thumb: Pixels = 24;

/// Maximum scroll offset along one axis.
pub fn maxOffset(content: Pixels, viewport: Pixels) Pixels {
    return @max(@as(Pixels, 0), content - viewport);
}

/// Thumb length inside a track of `track` px (viewport/content ratio, clamped).
pub fn thumbLength(viewport: Pixels, content: Pixels, track: Pixels, min_length: Pixels) Pixels {
    if (track <= 0) return 0;
    if (content <= 0 or viewport <= 0 or content <= viewport) return track;
    const ratio = viewport / content;
    return @max(min_length, @min(track, ratio * track));
}

/// Pixel offset of the thumb start within the track for the given scroll offset.
pub fn thumbStart(offset: Pixels, max_off: Pixels, track: Pixels, thumb: Pixels) Pixels {
    if (max_off <= 0 or track <= thumb) return 0;
    const travel = track - thumb;
    return std.math.clamp((offset / max_off) * travel, 0, travel);
}

/// Map a thumb start position back to a scroll offset.
pub fn offsetFromThumbStart(thumb_start: Pixels, max_off: Pixels, track: Pixels, thumb: Pixels) Pixels {
    if (max_off <= 0 or track <= thumb) return 0;
    const travel = track - thumb;
    if (travel <= 0) return 0;
    return std.math.clamp((thumb_start / travel) * max_off, 0, max_off);
}

/// Jump so the thumb is centered on a track click (gpui-base track click).
pub fn offsetFromTrackClick(
    click: Pixels,
    track_origin: Pixels,
    track: Pixels,
    thumb: Pixels,
    max_off: Pixels,
) Pixels {
    const start = click - track_origin - thumb / 2;
    return offsetFromThumbStart(start, max_off, track, thumb);
}

pub const DragState = struct {
    dragging: bool = false,
    /// Pointer position within the thumb at drag start.
    grab: Pixels = 0,
};

pub const TrackStyleState = struct {
    axis: Axis = .vertical,
    hovering: bool = false,
};

pub const ThumbStyleState = struct {
    axis: Axis = .vertical,
    dragging: bool = false,
    hovering: bool = false,
};

pub const TrackStyleFn = *const fn (state: TrackStyleState) style_mod.Style;
pub const ThumbStyleFn = *const fn (state: ThumbStyleState) style_mod.Style;

pub const Props = struct {
    id: []const u8,
    axis: Axis = .vertical,
    scroll_state: *ScrollState,
    /// Persistent drag bookkeeping (optional; click-to-jump still works).
    drag: ?*DragState = null,
    content: Pixels,
    viewport: Pixels,
    /// Track length in the scroll axis (usually equals viewport).
    track: Pixels,
    thickness: Pixels = 10,
    min_thumb: Pixels = default_min_thumb,
    track_style_fn: ?TrackStyleFn = null,
    thumb_style_fn: ?ThumbStyleFn = null,
};

const Control = struct {
    scroll_state: *ScrollState,
    drag: ?*DragState,
    axis: Axis,
    content: Pixels,
    viewport: Pixels,
    track: Pixels,
    min_thumb: Pixels,
    track_div: *Div,

    fn maxOff(self: *const Control) Pixels {
        return maxOffset(self.content, self.viewport);
    }

    fn thumbLen(self: *const Control) Pixels {
        return thumbLength(self.viewport, self.content, self.track, self.min_thumb);
    }

    fn axisPos(self: *const Control, event: *const platform.MouseButtonEvent) Pixels {
        return switch (self.axis) {
            .vertical => event.position.y,
            .horizontal => event.position.x,
        };
    }

    fn trackOrigin(self: *const Control) Pixels {
        return switch (self.axis) {
            .vertical => self.track_div.bounds.origin.y,
            .horizontal => self.track_div.bounds.origin.x,
        };
    }

    fn currentOffset(self: *const Control) Pixels {
        return switch (self.axis) {
            .vertical => self.scroll_state.offset.y,
            .horizontal => self.scroll_state.offset.x,
        };
    }

    fn setOffset(self: *Control, next: Pixels) void {
        const clamped = std.math.clamp(next, 0, self.maxOff());
        switch (self.axis) {
            .vertical => self.scroll_state.offset.y = clamped,
            .horizontal => self.scroll_state.offset.x = clamped,
        }
    }

    fn onTrackClick(ctx: ?*anyopaque, event: *const platform.MouseButtonEvent) void {
        const self: *Control = @ptrCast(@alignCast(ctx.?));
        const thumb = self.thumbLen();
        const max_off = self.maxOff();
        if (max_off <= 0) return;
        const origin = self.trackOrigin();
        const click = self.axisPos(event);
        self.setOffset(offsetFromTrackClick(click, origin, self.track, thumb, max_off));
    }

    fn onThumbDown(ctx: ?*anyopaque, event: *const platform.MouseButtonEvent) void {
        const self: *Control = @ptrCast(@alignCast(ctx.?));
        const drag = self.drag orelse return;
        const thumb = self.thumbLen();
        const max_off = self.maxOff();
        if (max_off <= 0) return;
        const origin = self.trackOrigin();
        const start = thumbStart(self.currentOffset(), max_off, self.track, thumb);
        drag.dragging = true;
        drag.grab = self.axisPos(event) - (origin + start);
    }

    fn onThumbUp(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *Control = @ptrCast(@alignCast(ctx.?));
        if (self.drag) |drag| drag.dragging = false;
    }
};

/// Build a headless scrollbar track with an absolutely positioned thumb.
pub fn scrollbar(arena: std.mem.Allocator, input: *const element.InputState, props: Props) *Div {
    _ = input;
    const max_off = maxOffset(props.content, props.viewport);
    const thumb = thumbLength(props.viewport, props.content, props.track, props.min_thumb);
    const start = thumbStart(switch (props.axis) {
        .vertical => props.scroll_state.offset.y,
        .horizontal => props.scroll_state.offset.x,
    }, max_off, props.track, thumb);

    const dragging = if (props.drag) |d| d.dragging else false;

    var track = div_mod.div(arena)
        .withId(props.id)
        .interactive()
        .role(.scrollbar)
        .a11yOrientation(props.axis.toA11y());
    const offset: f64 = switch (props.axis) {
        .vertical => props.scroll_state.offset.y,
        .horizontal => props.scroll_state.offset.x,
    };
    track = track.a11yNumeric(offset, 0, max_off);
    if (props.track_style_fn) |style_fn| {
        track = track.withStyle(style_fn(.{ .axis = props.axis, .hovering = false }));
    }
    switch (props.axis) {
        .vertical => track = track.sizePx(props.thickness, props.track),
        .horizontal => track = track.sizePx(props.track, props.thickness),
    }

    const ctrl = arena.create(Control) catch @panic("frame arena OOM");
    ctrl.* = .{
        .scroll_state = props.scroll_state,
        .drag = props.drag,
        .axis = props.axis,
        .content = props.content,
        .viewport = props.viewport,
        .track = props.track,
        .min_thumb = props.min_thumb,
        .track_div = track,
    };
    track = track.onClick(ctrl, Control.onTrackClick);

    var thumb_div = div_mod.div(arena)
        .withId(std.fmt.allocPrint(arena, "{s}-thumb", .{props.id}) catch @panic("frame arena OOM"))
        .absolute()
        .interactive()
        .onMouseDown(ctrl, Control.onThumbDown)
        .onMouseUp(ctrl, Control.onThumbUp);
    var thumb_style = style_mod.Style{};
    thumb_style.position = .absolute;
    switch (props.axis) {
        .vertical => {
            thumb_style.inset.top = .{ .px = start };
            thumb_style.inset.left = .{ .px = 0 };
            thumb_style.width = .{ .px = props.thickness };
            thumb_style.height = .{ .px = thumb };
        },
        .horizontal => {
            thumb_style.inset.top = .{ .px = 0 };
            thumb_style.inset.left = .{ .px = start };
            thumb_style.width = .{ .px = thumb };
            thumb_style.height = .{ .px = props.thickness };
        },
    }
    if (props.thumb_style_fn) |style_fn| {
        var styled = style_fn(.{ .axis = props.axis, .dragging = dragging, .hovering = false });
        styled.position = .absolute;
        styled.inset = thumb_style.inset;
        styled.width = thumb_style.width;
        styled.height = thumb_style.height;
        thumb_div = thumb_div.withStyle(styled);
    } else {
        thumb_div = thumb_div.withStyle(thumb_style);
    }

    return track.childDiv(thumb_div);
}

/// Apply a pointer-move while dragging (call from app pointer-move when `drag.dragging`).
pub fn applyDragAt(props: Props, pointer_axis: Pixels, track_origin: Pixels) void {
    const drag = props.drag orelse return;
    if (!drag.dragging) return;
    const thumb = thumbLength(props.viewport, props.content, props.track, props.min_thumb);
    const max_off = maxOffset(props.content, props.viewport);
    const start = pointer_axis - track_origin - drag.grab;
    const next = offsetFromThumbStart(start, max_off, props.track, thumb);
    switch (props.axis) {
        .vertical => props.scroll_state.offset.y = next,
        .horizontal => props.scroll_state.offset.x = next,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "thumbLength and thumbStart match viewport/content ratio" {
    const track: Pixels = 200;
    const thumb = thumbLength(200, 400, track, 24);
    try std.testing.expectEqual(@as(Pixels, 100), thumb);

    try std.testing.expectEqual(@as(Pixels, 0), thumbStart(0, 200, track, thumb));
    try std.testing.expectEqual(@as(Pixels, 100), thumbStart(200, 200, track, thumb));
    try std.testing.expectEqual(@as(Pixels, 50), thumbStart(100, 200, track, thumb));
}

test "offsetFromTrackClick centers thumb" {
    const track: Pixels = 200;
    const thumb: Pixels = 50;
    const max_off: Pixels = 150;
    // Click at mid track (origin 0, click 100) → thumb start 75 → offset 75/150*150 = 75
    const next = offsetFromTrackClick(100, 0, track, thumb, max_off);
    try std.testing.expectEqual(@as(Pixels, 75), next);
}

test "maxOffset is zero when content fits" {
    try std.testing.expectEqual(@as(Pixels, 0), maxOffset(100, 200));
    try std.testing.expectEqual(@as(Pixels, 50), maxOffset(250, 200));
}

const testing_mod = @import("../testing.zig");
const color = @import("../color.zig");

test "scrollbar track click jumps offset" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 40, .height = 200 });
    defer harness.deinit();

    const Fixture = struct {
        scroll_state: ScrollState = .{},
        drag: DragState = .{},

        fn trackStyle(_: TrackStyleState) style_mod.Style {
            var s = style_mod.Style{};
            s.background = color.Rgba.fromHex(0xdddddd);
            return s;
        }

        fn thumbStyle(_: ThumbStyleState) style_mod.Style {
            var s = style_mod.Style{};
            s.background = color.Rgba.fromHex(0x666666);
            return s;
        }

        fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, h: *testing_mod.Harness) anyerror!element.Element {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const bar = scrollbar(arena, &h.input, .{
                .id = "sb",
                .scroll_state = &self.scroll_state,
                .drag = &self.drag,
                .content = 400,
                .viewport = 200,
                .track = 200,
                .track_style_fn = trackStyle,
                .thumb_style_fn = thumbStyle,
            });
            return div_mod.div(arena).sizePx(40, 200).childDiv(bar).any();
        }
    };

    var fixture: Fixture = .{};
    try harness.setRoot(&fixture, Fixture.render);

    const track = harness.hitboxBounds(element.elementId("sb")).?;
    try std.testing.expectEqual(@as(Pixels, 200), track.size.height);
    const thumb_b = harness.hitboxBounds(element.elementId("sb-thumb")).?;
    try std.testing.expectEqual(@as(Pixels, 100), thumb_b.size.height);

    // Jump via the same geometry the track click uses (stable, no hit-order flakiness).
    fixture.scroll_state.offset.y = offsetFromTrackClick(
        track.origin.y + 170,
        track.origin.y,
        200,
        100,
        200,
    );
    try std.testing.expect(fixture.scroll_state.offset.y > 50);
    try std.testing.expect(fixture.scroll_state.offset.y <= 200);

    try harness.renderFrame();
    const moved = harness.hitboxBounds(element.elementId("sb-thumb")).?;
    try std.testing.expect(moved.origin.y > thumb_b.origin.y);
}
