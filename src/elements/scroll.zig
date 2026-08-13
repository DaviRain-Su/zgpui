//! ScrollView: a fixed-size viewport that clips and scrolls a single child,
//! modeled on gpui's scroll containers.
//!
//! Scroll offset is stored on the element. For offset that survives frame
//! rebuilds, bind stable storage with `bindState` (or copy offset from app
//! entity state each frame).

const std = @import("std");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");
const style_mod = @import("../style.zig");
const layout = @import("../layout/layout.zig");
const element = @import("../element.zig");
const scene_mod = @import("../scene.zig");
const platform = @import("../platform.zig");
const app_mod = @import("../app.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point;
const Size = geometry.Size;
const Bounds = geometry.Bounds;
const Rgba = color.Rgba;
const Style = style_mod.Style;
const Element = element.Element;

pub const default_line_height: Pixels = 20;

pub fn scrollView(arena: std.mem.Allocator) *ScrollView {
    const sv = arena.create(ScrollView) catch @panic("frame arena OOM");
    sv.* = .{ .arena = arena };
    return sv;
}

/// Persistent scroll state; bind with `bindState` so offset survives arena resets.
pub const ScrollState = struct {
    offset: Point(Pixels) = .{},
};

pub const ScrollAxes = enum {
    vertical,
    horizontal,
    both,

    fn allowsX(self: ScrollAxes) bool {
        return self == .horizontal or self == .both;
    }

    fn allowsY(self: ScrollAxes) bool {
        return self == .vertical or self == .both;
    }
};

pub const ScrollView = struct {
    arena: std.mem.Allocator,
    style: Style = .{},
    content: ?Element = null,
    offset: Point(Pixels) = .{},
    state: ?*ScrollState = null,
    scroll_axes: ScrollAxes = .vertical,
    app: ?*app_mod.App = null,
    line_height: Pixels = default_line_height,
    background: ?Rgba = null,

    node: ?*layout.Node = null,
    content_node: ?*layout.Node = null,
    bounds: Bounds(Pixels) = .{},
    content_size: Size(Pixels) = .{},

    const vtable = Element.VTable{
        .request_layout = requestLayoutErased,
        .prepaint = prepaintErased,
        .paint = paintErased,
    };

    pub fn any(self: *ScrollView) Element {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn sizePx(self: *ScrollView, width: Pixels, height: Pixels) *ScrollView {
        self.style.width = .{ .px = width };
        self.style.height = .{ .px = height };
        return self;
    }

    pub fn wPx(self: *ScrollView, width: Pixels) *ScrollView {
        self.style.width = .{ .px = width };
        return self;
    }

    pub fn hPx(self: *ScrollView, height: Pixels) *ScrollView {
        self.style.height = .{ .px = height };
        return self;
    }

    pub fn bg(self: *ScrollView, background: Rgba) *ScrollView {
        self.background = background;
        return self;
    }

    pub fn scrollAxes(self: *ScrollView, scroll_axes: ScrollAxes) *ScrollView {
        self.scroll_axes = scroll_axes;
        return self;
    }

    pub fn withApp(self: *ScrollView, app: *app_mod.App) *ScrollView {
        self.app = app;
        return self;
    }

    pub fn bindState(self: *ScrollView, scroll_state: *ScrollState) *ScrollView {
        self.state = scroll_state;
        self.offset = scroll_state.offset;
        return self;
    }

    pub fn child(self: *ScrollView, el: Element) *ScrollView {
        self.content = el;
        return self;
    }

    pub fn setOffset(self: *ScrollView, new_offset: Point(Pixels)) void {
        self.offset = new_offset;
        if (self.bounds.size.width > 0 or self.bounds.size.height > 0) {
            self.clampOffset();
        }
        self.syncState();
        self.markDirty();
    }

    pub fn scrollBy(self: *ScrollView, delta_x: Pixels, delta_y: Pixels) void {
        var next = self.offset;
        if (self.scroll_axes.allowsX()) next.x += delta_x;
        if (self.scroll_axes.allowsY()) next.y += delta_y;
        self.setOffset(next);
    }

    fn syncState(self: *ScrollView) void {
        if (self.state) |scroll_state| scroll_state.offset = self.offset;
    }

    fn loadState(self: *ScrollView) void {
        if (self.state) |scroll_state| self.offset = scroll_state.offset;
    }

    fn markDirty(self: *ScrollView) void {
        if (self.app) |app| {
            if (!self.bounds.isEmpty()) {
                app.requestRegionalRedraw(self.bounds);
            } else {
                app.requestFullRedraw();
            }
        }
    }

    fn maxOffset(self: *const ScrollView) Point(Pixels) {
        return .{
            .x = if (self.scroll_axes.allowsX())
                @max(0, self.content_size.width - self.bounds.size.width)
            else
                0,
            .y = if (self.scroll_axes.allowsY())
                @max(0, self.content_size.height - self.bounds.size.height)
            else
                0,
        };
    }

    fn clampOffset(self: *ScrollView) void {
        const max = self.maxOffset();
        self.offset.x = std.math.clamp(self.offset.x, 0, max.x);
        self.offset.y = std.math.clamp(self.offset.y, 0, max.y);
    }

    fn scrollDeltaFromEvent(self: *const ScrollView, event: *const platform.ScrollEvent) Point(Pixels) {
        const scale: Pixels = switch (event.unit) {
            .lines => self.line_height,
            .pixels => 1,
        };
        return event.delta.scale(scale);
    }

    fn handleScroll(ctx: ?*anyopaque, event: *const platform.ScrollEvent) void {
        const self: *ScrollView = @ptrCast(@alignCast(ctx.?));
        const delta = self.scrollDeltaFromEvent(event);
        // Platform scroll down is negative delta; increasing offset reveals lower content.
        var next = self.offset;
        if (self.scroll_axes.allowsX()) next.x -= delta.x;
        if (self.scroll_axes.allowsY()) next.y -= delta.y;
        self.setOffset(next);
    }

    fn requestLayoutErased(ptr: *anyopaque, pass: *element.LayoutPass) anyerror!*layout.Node {
        const self: *ScrollView = @ptrCast(@alignCast(ptr));
        return self.requestLayout(pass);
    }

    pub fn requestLayout(self: *ScrollView, pass: *element.LayoutPass) anyerror!*layout.Node {
        self.loadState();

        const node = try pass.arena.create(layout.Node);
        node.* = pass.engine.newNode();
        self.node = node;
        applyViewportStyle(node, &self.style);
        node.setAlignItems(.flex_start);

        const content_el = self.content orelse return error.MissingScrollContent;
        const content_node = try content_el.requestLayout(pass);
        self.content_node = content_node;

        const wrapper = try pass.arena.create(layout.Node);
        wrapper.* = pass.engine.newNode();
        wrapper.setFlexShrink(0);
        wrapper.setFlexGrow(0);
        wrapper.setAlignSelf(.flex_start);
        wrapper.addChild(content_node);
        node.addChild(wrapper);
        return node;
    }

    fn prepaintErased(ptr: *anyopaque, pass: *element.PrepaintPass, parent_origin: Point(Pixels)) anyerror!void {
        const self: *ScrollView = @ptrCast(@alignCast(ptr));
        return self.prepaint(pass, parent_origin);
    }

    pub fn prepaint(self: *ScrollView, pass: *element.PrepaintPass, parent_origin: Point(Pixels)) anyerror!void {
        const node = self.node orelse return error.LayoutNotRequested;
        const relative = node.layoutBounds();
        self.bounds = .{
            .origin = parent_origin.add(relative.origin),
            .size = relative.size,
        };

        if (self.content_node) |content_node| {
            self.content_size = content_node.layoutBounds().size;
        }
        self.clampOffset();
        self.syncState();

        try pass.frame.addHitbox(.{
            .id = null,
            .bounds = self.bounds,
            .on_scroll = .{ .ctx = self, .func = handleScroll },
        });

        const content_origin = self.bounds.origin.sub(self.offset);
        const content_el = self.content orelse return;
        try content_el.prepaint(pass, content_origin);
    }

    fn paintErased(ptr: *anyopaque, pass: *element.PaintPass) anyerror!void {
        const self: *ScrollView = @ptrCast(@alignCast(ptr));
        return self.paint(pass);
    }

    pub fn paint(self: *ScrollView, pass: *element.PaintPass) anyerror!void {
        if (self.style.display == .none) return;
        if (!pass.shouldPaint(self.bounds)) return;

        if (self.background) |background| {
            try pass.scene.insertQuad(.{
                .bounds = scene_mod.BoundsF.from(self.bounds),
                .clip_bounds = pass.clipF(),
                .background = scene_mod.ColorF.from(background),
                .border_color = scene_mod.ColorF.from(Rgba.transparent),
                .corner_radii = scene_mod.CornersF.from(self.style.corner_radii),
                .border_widths = scene_mod.EdgesF.from(self.style.border_widths),
            });
        }

        const previous_clip = pass.pushClip(self.bounds);
        defer pass.popClip(previous_clip);

        const content_el = self.content orelse return;
        try content_el.paint(pass);
    }
};

fn toDimension(length: style_mod.Length) layout.Dimension {
    return switch (length) {
        .auto => .auto,
        .px => |v| .{ .points = v },
        .percent => |v| .{ .percent = v },
    };
}

fn applyViewportStyle(node: *layout.Node, s: *const Style) void {
    node.setDisplay(switch (s.display) {
        .flex => .flex,
        .none => .none,
    });
    node.setFlexDirection(.column);
    node.setWidth(toDimension(s.width));
    node.setHeight(toDimension(s.height));
    node.setMinWidth(toDimension(s.min_width));
    node.setMinHeight(toDimension(s.min_height));
    node.setMaxWidth(toDimension(s.max_width));
    node.setMaxHeight(toDimension(s.max_height));
    node.setOverflow(.hidden);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const div_mod = @import("div.zig");
const testing_mod = @import("../testing.zig");

const TestFixture = struct {
    scroll_state: ScrollState = .{},
    harness: *testing_mod.Harness = undefined,
    clicks: u32 = 0,

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *testing_mod.Harness) anyerror!element.Element {
        const self: *TestFixture = @ptrCast(@alignCast(ctx.?));
        self.harness = harness;

        const content = div_mod.div(arena)
            .flexCol()
            .childDiv(
                div_mod.div(arena)
                    .withId("target")
                    .sizePx(80, 30)
                    .bg(Rgba.fromHex(0x336699))
                    .onClick(self, clickHandler),
            )
            .childDiv(div_mod.div(arena).sizePx(80, 400).bg(Rgba.fromHex(0xcccccc)));

        const sv = scrollView(arena)
            .sizePx(100, 100)
            .bg(Rgba.black)
            .bindState(&self.scroll_state)
            .withApp(&harness.app)
            .child(content.any());
        return sv.any();
    }

    fn clickHandler(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *TestFixture = @ptrCast(@alignCast(ctx.?));
        self.clicks += 1;
    }
};

test "scrollBy shifts child hitbox origin" {
    var tf = LocalTestFrame.init();
    defer tf.deinit();
    const arena = tf.arena_state.allocator();

    var state: ScrollState = .{};

    const content = div_mod.div(arena)
        .flexCol()
        .childDiv(
            div_mod.div(arena)
                .withId("target")
                .interactive()
                .sizePx(80, 30)
                .bg(Rgba.fromHex(0x336699)),
        )
        .childDiv(div_mod.div(arena).sizePx(80, 400).bg(Rgba.fromHex(0xcccccc)));

    const sv = scrollView(arena)
        .sizePx(100, 100)
        .bindState(&state)
        .child(content.any());
    try tf.run(sv.any(), 200, 200);

    const target_id = element.elementId("target");
    var found_before = false;
    for (tf.frame.hitboxes.items) |hb| {
        if (hb.id != null and hb.id.? == target_id) {
            try std.testing.expectEqual(@as(Pixels, 0), hb.bounds.origin.y);
            found_before = true;
            break;
        }
    }
    try std.testing.expect(found_before);

    // Mutate persistent state, then rebuild (offset applied in prepaint).
    state.offset = .{ .x = 0, .y = 50 };
    // Rebuild content tree in a fresh arena allocation path.
    _ = tf.arena_state.reset(.retain_capacity);
    const arena2 = tf.arena_state.allocator();
    const content2 = div_mod.div(arena2)
        .flexCol()
        .childDiv(
            div_mod.div(arena2)
                .withId("target")
                .interactive()
                .sizePx(80, 30)
                .bg(Rgba.fromHex(0x336699)),
        )
        .childDiv(div_mod.div(arena2).sizePx(80, 400).bg(Rgba.fromHex(0xcccccc)));
    const sv_after = scrollView(arena2)
        .sizePx(100, 100)
        .bindState(&state)
        .child(content2.any());
    try tf.run(sv_after.any(), 200, 200);

    var found_after = false;
    for (tf.frame.hitboxes.items) |hb| {
        if (hb.id != null and hb.id.? == target_id) {
            try std.testing.expectEqual(@as(Pixels, -50), hb.bounds.origin.y);
            found_after = true;
            break;
        }
    }
    try std.testing.expect(found_after);
}

test "wheel scroll updates offset and clamps" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 200 });
    defer harness.deinit();

    var fixture: TestFixture = .{};
    try harness.setRoot(&fixture, TestFixture.render);

    // Scroll down: negative delta increases offset.
    try harness.dispatch(.{ .scroll = .{
        .position = .{ .x = 10, .y = 10 },
        .delta = .{ .x = 0, .y = -2 },
        .unit = .lines,
    } });
    try std.testing.expect(fixture.scroll_state.offset.y > 0);
    try std.testing.expect(harness.frame_count > 1);

    // Content height ~430, viewport 100 -> max offset ~330.
    fixture.scroll_state.offset = .{ .x = 0, .y = 9999 };
    try harness.renderFrame();
    try std.testing.expect(fixture.scroll_state.offset.y <= 340);
    try std.testing.expect(fixture.scroll_state.offset.y >= 320);
}

test "click hits scrolled-into-view target, not scrolled-away area" {
    var harness = testing_mod.Harness.init(std.testing.allocator, .{ .width = 200, .height = 200 });
    defer harness.deinit();

    var fixture: TestFixture = .{};
    try harness.setRoot(&fixture, TestFixture.render);

    // Button starts at y=0; click works.
    try harness.clickOn("target");
    try std.testing.expectEqual(@as(u32, 1), fixture.clicks);

    // Scroll so button moves above viewport; same screen point misses.
    fixture.scroll_state.offset = .{ .x = 0, .y = 50 };
    try harness.renderFrame();
    try harness.click(40, 15);
    try std.testing.expectEqual(@as(u32, 1), fixture.clicks);

    // Scroll partially back; button visible again at adjusted origin.
    fixture.scroll_state.offset = .{ .x = 0, .y = 20 };
    try harness.renderFrame();
    try harness.clickOn("target");
    try std.testing.expectEqual(@as(u32, 2), fixture.clicks);
}

const LocalTestFrame = struct {
    arena_state: std.heap.ArenaAllocator,
    engine: layout.LayoutEngine,
    frame: element.FrameState,
    scene: scene_mod.Scene,
    root_node: ?*layout.Node = null,

    fn init() LocalTestFrame {
        return .{
            .arena_state = std.heap.ArenaAllocator.init(std.testing.allocator),
            .engine = layout.LayoutEngine.init(),
            .frame = element.FrameState.init(std.testing.allocator),
            .scene = scene_mod.Scene.init(std.testing.allocator),
        };
    }

    fn deinit(self: *LocalTestFrame) void {
        if (self.root_node) |node| node.freeRecursive();
        self.scene.deinit();
        self.frame.deinit();
        self.engine.deinit();
        self.arena_state.deinit();
    }

    fn run(self: *LocalTestFrame, root: Element, width: Pixels, height: Pixels) !void {
        self.frame.clear();
        self.scene.clear();
        var layout_pass = element.LayoutPass{
            .arena = self.arena_state.allocator(),
            .engine = &self.engine,
        };
        const root_node = try root.requestLayout(&layout_pass);
        self.root_node = root_node;
        self.engine.computeLayout(root_node, width, height);

        var prepaint_pass = element.PrepaintPass{ .arena = self.arena_state.allocator(), .scratch = self.arena_state.allocator(), .frame = &self.frame,
        };
        try root.prepaint(&prepaint_pass, .{});

        var paint_pass = element.PaintPass{ .scratch = self.arena_state.allocator(), .scene = &self.scene };
        try root.paint(&paint_pass);
    }
};

test "paint clips content to viewport" {
    var tf = LocalTestFrame.init();
    defer tf.deinit();
    const arena = tf.arena_state.allocator();

    const tall = div_mod.div(arena).wPx(50).hPx(500).bg(Rgba.red);
    const sv = scrollView(arena).sizePx(100, 100).bg(Rgba.black).child(tall.any());

    try tf.run(sv.any(), 100, 100);

    const child_quad = tf.scene.quads.items[1];
    try std.testing.expectEqual(@as(f32, 100), child_quad.clip_bounds.size_w);
    try std.testing.expectEqual(@as(f32, 100), child_quad.clip_bounds.size_h);
}
