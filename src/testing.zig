//! Headless test harness: runs the full frame pipeline (build → layout →
//! prepaint → paint) without a window or GPU, and dispatches synthetic
//! input. Used by component behavior tests (and usable by downstream
//! applications for their own UI tests).
//!
//! Regional entity dirty (`App.requestRegionalRedraw` / `notifyBounds`) keeps
//! the previous element/Yoga tree and only re-runs prepaint + paint, matching
//! `Window` retained paint-only frames. Explicit `renderFrame` always rebuilds.

const std = @import("std");
const geometry = @import("geometry.zig");
const layout = @import("layout/layout.zig");
const element = @import("element.zig");
const scene_mod = @import("scene.zig");
const platform = @import("platform.zig");
const app_mod = @import("app.zig");
const overlay_mod = @import("overlay.zig");
const hotkey_mod = @import("hotkey.zig");
const a11y_mod = @import("a11y.zig");
const dirty_mod = @import("dirty.zig");

const Pixels = geometry.Pixels;
const Size = geometry.Size;
const Point = geometry.Point;
const Bounds = geometry.Bounds;

/// Builds the frame's root element. `ctx` is the harness user's state;
/// element allocations must come from `arena`. Handler `ctx` pointers must
/// NOT point into the arena (it resets on layout rebuild) — point at app
/// entities or other stable state instead.
pub const RenderFn = *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *Harness) anyerror!element.Element;

pub const Harness = struct {
    gpa: std.mem.Allocator,
    app: app_mod.App,
    engine: layout.LayoutEngine,
    /// Element tree + Yoga nodes; reset only when layout is dirty.
    arena_state: std.heap.ArenaAllocator,
    /// Ephemeral prepaint/paint/overlay allocations; reset every frame.
    scratch_arena: std.heap.ArenaAllocator,
    frame: element.FrameState,
    input: element.InputState,
    scene: scene_mod.Scene,
    overlays: overlay_mod.OverlayStack,
    hotkeys: hotkey_mod.HotkeyRouter = .{},
    root_node: ?*layout.Node = null,
    /// Last built root; valid while `arena_state` is not reset.
    retained_root: ?element.Element = null,
    dirty: dirty_mod.DirtyTracker = .{},
    viewport: Size(Pixels),
    render_ctx: ?*anyopaque = null,
    render_fn: ?RenderFn = null,
    frame_count: u64 = 0,
    /// Whether the most recent `dispatch` triggered a re-render.
    last_dispatch_redraw: bool = false,
    /// True when the last pipeline frame skipped build+Yoga (paint-only).
    last_frame_retained: bool = false,
    /// Match `Window.partial_present`: regional dirty enables paint_clip cull.
    partial_present: bool = true,
    /// Last frame's logical paint clip (`null` = paint everything).
    last_paint_clip: ?Bounds(Pixels) = null,

    pub fn init(gpa: std.mem.Allocator, viewport: Size(Pixels)) Harness {
        return .{
            .gpa = gpa,
            .app = app_mod.App.init(gpa),
            .engine = layout.LayoutEngine.init(),
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .scratch_arena = std.heap.ArenaAllocator.init(gpa),
            .frame = element.FrameState.init(gpa),
            .input = .{},
            .scene = scene_mod.Scene.init(gpa),
            .overlays = overlay_mod.OverlayStack.init(gpa),
            .viewport = viewport,
        };
    }

    pub fn deinit(self: *Harness) void {
        if (self.root_node) |node| node.freeRecursive();
        self.overlays.deinit();
        self.scene.deinit();
        self.frame.deinit();
        self.engine.deinit();
        self.scratch_arena.deinit();
        self.arena_state.deinit();
        self.app.deinit();
    }

    pub fn setRoot(self: *Harness, ctx: ?*anyopaque, render_fn: RenderFn) !void {
        self.render_ctx = ctx;
        self.render_fn = render_fn;
        try self.renderFrame();
    }

    /// Merge pending `App` dirty into the harness tracker (Window-compatible).
    fn absorbAppDirty(self: *Harness) void {
        const region = self.app.takeDirtyRegion();
        switch (region) {
            .none, .full => self.dirty.markFull(),
            .regional => |bounds| {
                self.dirty.markBounds(bounds);
                if (!self.dirty.needsRedraw()) self.dirty.markFull();
            },
        }
    }

    /// Flush entity effects and run an incremental pipeline frame when dirty.
    fn flushRedraw(self: *Harness) !bool {
        self.app.flushEffects();
        if (!self.app.needs_redraw) return false;
        self.absorbAppDirty();
        try self.renderPipeline();
        _ = self.input.updateHover(&self.frame);
        return true;
    }

    /// Run one full frame: always rebuild elements + Yoga, then prepaint/paint.
    pub fn renderFrame(self: *Harness) !void {
        self.dirty.markFull();
        try self.renderPipeline();
    }

    /// Build/layout when needed; otherwise retain the tree and only prepaint/paint.
    fn renderPipeline(self: *Harness) !void {
        const render_fn = self.render_fn orelse return error.NoRootSet;

        const rebuild = self.dirty.needsLayout() or self.retained_root == null;
        // Overlay Yoga nodes may be allocated from scratch — free before reset.
        self.overlays.discardBuiltLayers();
        _ = self.scratch_arena.reset(.retain_capacity);
        const scratch = self.scratch_arena.allocator();

        const root = if (rebuild) root_blk: {
            if (self.root_node) |node| {
                node.freeRecursive();
                self.root_node = null;
            }
            self.retained_root = null;
            _ = self.arena_state.reset(.retain_capacity);
            self.frame.clear();
            self.scene.clear();
            self.overlays.beginFrame();

            const arena = self.arena_state.allocator();
            const built_root = try render_fn(self.render_ctx, arena, self);

            var layout_pass = element.LayoutPass{ .arena = arena, .engine = &self.engine };
            const root_node = try built_root.requestLayout(&layout_pass);
            self.root_node = root_node;
            self.engine.computeLayout(root_node, self.viewport.width, self.viewport.height);
            self.retained_root = built_root;
            break :root_blk built_root;
        } else retained_blk: {
            self.frame.clear();
            self.scene.clear();
            self.overlays.beginFrame();
            break :retained_blk self.retained_root.?;
        };

        var prepaint_pass = element.PrepaintPass{
            .arena = self.arena_state.allocator(),
            .scratch = scratch,
            .frame = &self.frame,
        };
        try root.prepaint(&prepaint_pass, .{});

        const paint_clip = dirty_mod.planPaintClip(self.partial_present, &self.dirty, 16);
        self.scene.paint_clip = paint_clip;
        self.last_paint_clip = paint_clip;
        var paint_pass = element.PaintPass{
            .scratch = scratch,
            .scene = &self.scene,
            .dirty_clip = paint_clip,
        };
        try root.paint(&paint_pass);

        try self.overlays.build(scratch, &self.engine, self.viewport);
        try self.overlays.paint(&self.scene, scratch);

        self.last_frame_retained = !rebuild;
        self.dirty.clear();
        self.frame_count += 1;
    }

    /// Dispatch one input event, flush entity effects, and re-render if any
    /// entity notified.
    pub fn dispatch(self: *Harness, event: platform.InputEvent) !void {
        self.last_dispatch_redraw = false;
        const overlay_handled = self.overlays.dispatch(&self.input, event);
        var consumed = overlay_handled;
        if (!consumed and event == .key_down) {
            consumed = self.hotkeys.dispatch(event.key_down);
        }
        if (!consumed) {
            _ = self.input.dispatch(&self.frame, event);
        }
        self.last_dispatch_redraw = try self.flushRedraw();
    }

    // ------------------------------------------------------------------
    // Convenience input synthesis
    // ------------------------------------------------------------------

    pub fn moveMouse(self: *Harness, x: Pixels, y: Pixels) !void {
        try self.dispatch(.{ .mouse_moved = .{ .position = .{ .x = x, .y = y } } });
    }

    pub fn click(self: *Harness, x: Pixels, y: Pixels) !void {
        try self.dispatch(.{ .mouse_down = .{ .button = .left, .position = .{ .x = x, .y = y } } });
        try self.dispatch(.{ .mouse_up = .{ .button = .left, .position = .{ .x = x, .y = y } } });
    }

    pub fn rightClick(self: *Harness, x: Pixels, y: Pixels) !void {
        try self.dispatch(.{ .mouse_down = .{ .button = .right, .position = .{ .x = x, .y = y } } });
        try self.dispatch(.{ .mouse_up = .{ .button = .right, .position = .{ .x = x, .y = y } } });
    }

    pub fn keyDown(self: *Harness, key: platform.Key) !void {
        try self.dispatch(.{ .key_down = .{ .key = key } });
    }

    pub fn keyDownWith(self: *Harness, key: platform.Key, modifiers: platform.Modifiers) !void {
        try self.dispatch(.{ .key_down = .{ .key = key, .modifiers = modifiers } });
    }

    pub fn textInput(self: *Harness, text: []const u8) !void {
        try self.dispatch(.{ .text_input = .{ .text = text } });
    }

    pub fn compositionStart(self: *Harness) !void {
        try self.dispatch(.composition_start);
    }

    pub fn compositionUpdate(self: *Harness, text: []const u8) !void {
        try self.compositionUpdateWithCursor(text, -1);
    }

    pub fn compositionUpdateWithCursor(self: *Harness, text: []const u8, cursor: i32) !void {
        try self.dispatch(.{ .composition_update = .{ .text = text, .cursor = cursor } });
    }

    pub fn compositionEnd(self: *Harness) !void {
        try self.dispatch(.composition_end);
    }

    /// Set the app in-memory clipboard (for copy/paste tests).
    pub fn setClipboard(self: *Harness, text: []const u8) !void {
        try self.app.clipboard.setText(text);
    }

    pub fn clipboardText(self: *const Harness) []const u8 {
        return self.app.clipboard.getText();
    }

    /// Press Tab until the given focus id is focused (or fail after one
    /// full cycle).
    pub fn focusById(self: *Harness, focus_id: element.FocusId) !void {
        const max_presses = self.frame.focusables.items.len + 1;
        var presses: usize = 0;
        while (presses < max_presses) : (presses += 1) {
            if (self.input.isFocused(focus_id)) return;
            try self.keyDown(.tab);
        }
        return error.FocusTargetNotFound;
    }

    // ------------------------------------------------------------------
    // Assertion helpers
    // ------------------------------------------------------------------

    /// Bounds of the hitbox registered with the given element id
    /// (main frame first, then overlay layers topmost-first).
    pub fn hitboxBounds(self: *const Harness, id: element.ElementId) ?geometry.Bounds(Pixels) {
        for (self.frame.hitboxes.items) |hitbox| {
            if (hitbox.id != null and hitbox.id.? == id) return hitbox.bounds;
        }
        var i = self.overlays.layers.items.len;
        while (i > 0) {
            i -= 1;
            for (self.overlays.layers.items[i].frame.hitboxes.items) |hitbox| {
                if (hitbox.id != null and hitbox.id.? == id) return hitbox.bounds;
            }
        }
        return null;
    }

    pub fn centerOf(self: *const Harness, id: element.ElementId) ?Point(Pixels) {
        const bounds = self.hitboxBounds(id) orelse return null;
        return .{
            .x = bounds.origin.x + bounds.size.width / 2,
            .y = bounds.origin.y + bounds.size.height / 2,
        };
    }

    pub fn clickOn(self: *Harness, id_name: []const u8) !void {
        const center = self.centerOf(element.elementId(id_name)) orelse return error.ElementNotFound;
        try self.click(center.x, center.y);
    }

    /// Simulate VoiceOver / AXPress for a registered hitbox id.
    pub fn a11yPressOn(self: *Harness, id_name: []const u8) !void {
        const id = element.elementId(id_name);
        const pressed = self.overlays.performAccessibilityPress(&self.input, &self.frame, id);
        if (!pressed) return error.ElementNotFound;
        _ = try self.flushRedraw();
    }

    /// Simulate AXIncrement / AXDecrement for a focusable control (e.g. slider).
    pub fn a11yAdjustOn(self: *Harness, id_name: []const u8, increment: bool) !void {
        const id = element.elementId(id_name);
        const adjusted = self.overlays.performAccessibilityAdjust(&self.input, &self.frame, id, increment);
        if (!adjusted) return error.ElementNotFound;
        _ = try self.flushRedraw();
    }

    pub fn a11yIncrementOn(self: *Harness, id_name: []const u8) !void {
        try self.a11yAdjustOn(id_name, true);
    }

    pub fn a11yDecrementOn(self: *Harness, id_name: []const u8) !void {
        try self.a11yAdjustOn(id_name, false);
    }

    /// Simulate AX `setAccessibilityValue:` for an editable text control.
    pub fn a11ySetValueOn(self: *Harness, id_name: []const u8, text: []const u8) !void {
        const id = element.elementId(id_name);
        const set = self.overlays.performAccessibilitySetValue(&self.input, &self.frame, id, text);
        if (!set) return error.ElementNotFound;
        _ = try self.flushRedraw();
    }

    /// Simulate AX `setAccessibilitySelectedText:`.
    pub fn a11yReplaceSelectedTextOn(self: *Harness, id_name: []const u8, text: []const u8) !void {
        const id = element.elementId(id_name);
        const ok = self.overlays.performAccessibilityReplaceSelectedText(&self.input, &self.frame, id, text);
        if (!ok) return error.ElementNotFound;
        _ = try self.flushRedraw();
    }

    /// Simulate AX `setAccessibilitySelectedTextRange:` with UTF-8 byte offsets.
    pub fn a11ySetSelectedRangeOn(self: *Harness, id_name: []const u8, start: usize, end: usize) !void {
        const id = element.elementId(id_name);
        const ok = self.overlays.performAccessibilitySetSelectedRange(
            &self.input,
            &self.frame,
            id,
            start,
            end,
        );
        if (!ok) return error.ElementNotFound;
        _ = try self.flushRedraw();
    }

    pub fn hoverOver(self: *Harness, id_name: []const u8) !void {
        const center = self.centerOf(element.elementId(id_name)) orelse return error.ElementNotFound;
        try self.moveMouse(center.x, center.y);
    }

    // ------------------------------------------------------------------
    // Accessibility helpers
    // ------------------------------------------------------------------

    pub fn a11yNode(self: *const Harness, id_name: []const u8) ?*const a11y_mod.Node {
        const id = element.elementId(id_name);
        if (a11y_mod.findById(&self.frame, id)) |node| return node;
        var i = self.overlays.layers.items.len;
        while (i > 0) {
            i -= 1;
            if (a11y_mod.findById(&self.overlays.layers.items[i].frame, id)) |node| return node;
        }
        return null;
    }

    pub fn a11yRole(self: *const Harness, id_name: []const u8) ?a11y_mod.Role {
        const node = self.a11yNode(id_name) orelse return null;
        return node.role;
    }

    pub fn a11yName(self: *const Harness, id_name: []const u8) ?[]const u8 {
        const node = self.a11yNode(id_name) orelse return null;
        if (a11y_mod.findById(&self.frame, node.id) != null) {
            return a11y_mod.resolveNameInFrame(&self.frame, node);
        }
        var i = self.overlays.layers.items.len;
        while (i > 0) {
            i -= 1;
            const layer = &self.overlays.layers.items[i];
            if (a11y_mod.findById(&layer.frame, node.id) != null) {
                return a11y_mod.resolveNameInFrame(&layer.frame, node);
            }
        }
        return a11y_mod.resolveName(node);
    }

    /// Tab-order element ids that also have a11y nodes in the main frame.
    pub fn a11yFocusOrder(self: *const Harness, allocator: std.mem.Allocator) ![]element.ElementId {
        var list: std.ArrayList(element.ElementId) = .empty;
        errdefer list.deinit(allocator);
        try a11y_mod.collectFocusOrder(&self.frame, &list, allocator);
        return try list.toOwnedSlice(allocator);
    }

    pub fn a11yChecked(self: *const Harness, id_name: []const u8) ?bool {
        const node = self.a11yNode(id_name) orelse return null;
        return node.checked;
    }

    pub fn a11ySelected(self: *const Harness, id_name: []const u8) ?bool {
        const node = self.a11yNode(id_name) orelse return null;
        return node.selected;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const color = @import("color.zig");
const div_mod = @import("elements/div.zig");

const CounterApp = struct {
    counter: app_mod.Entity(Counter),
    harness: *Harness = undefined,

    const Counter = struct { count: i32 = 0 };

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, harness: *Harness) anyerror!element.Element {
        const self: *CounterApp = @ptrCast(@alignCast(ctx.?));
        const count = harness.app.read(Counter, self.counter).count;

        const label_height: Pixels = if (count > 0) 40 else 20;
        const root = div_mod.div(arena)
            .flexCol()
            .sizePx(200, 200)
            .childDiv(div_mod.div(arena)
            .withId("increment")
            .sizePx(100, label_height)
            .bg(color.Rgba.red)
            .onClick(self, incrementHandler));
        return root.any();
    }

    fn incrementHandler(ctx: ?*anyopaque, _: *const platform.MouseButtonEvent) void {
        const self: *CounterApp = @ptrCast(@alignCast(ctx.?));
        self.harness.app.read(Counter, self.counter).count += 1;
        self.harness.app.notify(self.counter.id);
    }
};

test "harness renders, dispatches clicks, and re-renders on notify" {
    var harness = Harness.init(std.testing.allocator, .{ .width = 200, .height = 200 });
    defer harness.deinit();

    var counter_app = CounterApp{
        .counter = try harness.app.new(CounterApp.Counter, .{}),
    };
    counter_app.harness = &harness;

    try harness.setRoot(&counter_app, CounterApp.render);
    try std.testing.expectEqual(@as(u64, 1), harness.frame_count);
    try std.testing.expect(!harness.last_frame_retained);

    // Initial height is 20.
    const bounds_before = harness.hitboxBounds(element.elementId("increment")).?;
    try std.testing.expectEqual(@as(Pixels, 20), bounds_before.size.height);

    try harness.clickOn("increment");
    try std.testing.expectEqual(@as(i32, 1), harness.app.read(CounterApp.Counter, counter_app.counter).count);
    try std.testing.expect(harness.last_dispatch_redraw);
    try std.testing.expect(!harness.last_frame_retained);

    // State change triggered a re-render with the new layout.
    try std.testing.expect(harness.frame_count > 1);
    const bounds_after = harness.hitboxBounds(element.elementId("increment")).?;
    try std.testing.expectEqual(@as(Pixels, 40), bounds_after.size.height);
}

const BuildCountApp = struct {
    builds: u32 = 0,

    fn render(ctx: ?*anyopaque, arena: std.mem.Allocator, _: *Harness) anyerror!element.Element {
        const self: *BuildCountApp = @ptrCast(@alignCast(ctx.?));
        self.builds += 1;
        const root = div_mod.div(arena)
            .withId("panel")
            .interactive()
            .sizePx(100, 80)
            .bg(color.Rgba.blue);
        return root.any();
    }
};

test "harness retains tree on regional paint-only dirty" {
    var harness = Harness.init(std.testing.allocator, .{ .width = 200, .height = 200 });
    defer harness.deinit();

    var app_state = BuildCountApp{};
    try harness.setRoot(&app_state, BuildCountApp.render);
    try std.testing.expectEqual(@as(u32, 1), app_state.builds);
    try std.testing.expect(!harness.last_frame_retained);
    try std.testing.expect(harness.hitboxBounds(element.elementId("panel")) != null);

    harness.app.requestRegionalRedraw(Bounds(Pixels).init(
        .{ .x = 10, .y = 10 },
        .{ .width = 40, .height = 20 },
    ));
    try std.testing.expect(try harness.flushRedraw());
    try std.testing.expectEqual(@as(u32, 1), app_state.builds);
    try std.testing.expect(harness.last_frame_retained);
    try std.testing.expectEqual(@as(u64, 2), harness.frame_count);
    try std.testing.expect(harness.hitboxBounds(element.elementId("panel")) != null);

    try harness.renderFrame();
    try std.testing.expectEqual(@as(u32, 2), app_state.builds);
    try std.testing.expect(!harness.last_frame_retained);
}

const TwoPanelApp = struct {
    fn render(_: ?*anyopaque, arena: std.mem.Allocator, _: *Harness) anyerror!element.Element {
        const root = div_mod.div(arena)
            .flexRow()
            .sizePx(200, 80)
            .childDiv(div_mod.div(arena)
                .withId("left")
                .interactive()
                .sizePx(40, 40)
                .bg(color.Rgba.red))
            .childDiv(div_mod.div(arena)
                .withId("right")
                .interactive()
                .sizePx(40, 40)
                .bg(color.Rgba.blue));
        return root.any();
    }
};

test "harness paint_clip culls outside regional dirty" {
    var harness = Harness.init(std.testing.allocator, .{ .width = 200, .height = 200 });
    defer harness.deinit();

    var app_state = TwoPanelApp{};
    try harness.setRoot(&app_state, TwoPanelApp.render);
    try std.testing.expect(harness.last_paint_clip == null);
    const full_quads = harness.scene.quads.items.len;
    try std.testing.expect(full_quads >= 2);

    // Dirty only the left panel; right (x≈40+) falls outside dilated clip.
    harness.app.requestRegionalRedraw(Bounds(Pixels).init(
        .{ .x = 0, .y = 0 },
        .{ .width = 20, .height = 20 },
    ));
    try std.testing.expect(try harness.flushRedraw());
    try std.testing.expect(harness.last_frame_retained);
    try std.testing.expect(harness.last_paint_clip != null);
    try std.testing.expect(harness.scene.quads.items.len < full_quads);
    try std.testing.expect(harness.hitboxBounds(element.elementId("left")) != null);
}
